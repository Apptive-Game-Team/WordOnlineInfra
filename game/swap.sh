#!/usr/bin/env bash
#
# Blue/green swap for the game server.
#
# Starts the new image on the idle slot, waits for it to register and report
# healthy, then drains the live slot. The game server exits by itself once its
# session count reaches zero, so the old container is never killed with players
# inside it.
#
# Exit codes: 0 = swapped or already up to date, 1 = failed (old slot untouched).

set -euo pipefail

IMAGE="${IMAGE:?IMAGE is required}"
NETWORK="${NETWORK:?NETWORK is required}"
GAME_ENV_FILE="${GAME_ENV_FILE:-/config/game.env}"
CICD_TOKEN="${CICD_TOKEN:?CICD_TOKEN is required}"

# Ports inside the container. Both slots use the same values; only the
# published host ports differ.
CONTAINER_PORT="${CONTAINER_PORT:-8080}"
CONTAINER_MANAGEMENT_PORT="${CONTAINER_MANAGEMENT_PORT:-8081}"

# Slot definitions: name, published app port, published management port.
SLOT_A_NAME="${SLOT_A_NAME:-game-blue}"
SLOT_A_PORT="${SLOT_A_PORT:-8080}"
SLOT_A_MANAGEMENT_PORT="${SLOT_A_MANAGEMENT_PORT:-8081}"
SLOT_B_NAME="${SLOT_B_NAME:-game-green}"
SLOT_B_PORT="${SLOT_B_PORT:-8090}"
SLOT_B_MANAGEMENT_PORT="${SLOT_B_MANAGEMENT_PORT:-8091}"

# The management port is bound to loopback so only a local Prometheus can
# scrape it. The deployer itself reaches actuator over the docker network.
MANAGEMENT_BIND="${MANAGEMENT_BIND:-127.0.0.1}"

HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-300}"   # seconds to wait for the new slot
DRAIN_TIMEOUT="${DRAIN_TIMEOUT:-3600}"    # seconds to wait for matches to end
STOP_GRACE="${STOP_GRACE:-30}"            # SIGTERM grace when drain overruns
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"

GAME_LABEL="wordonline.role=game"

log() {
    printf '%s [swap] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

notify() {
    log "$*"
    [ -n "$DISCORD_WEBHOOK_URL" ] || return 0
    curl -sf -X POST -H 'Content-Type: application/json' \
        --data "$(printf '{"content":"[game deploy] %s"}' "$*")" \
        "$DISCORD_WEBHOOK_URL" >/dev/null || true
}

# Currently running game slot, if any.
current_slot() {
    docker ps --filter "label=${GAME_LABEL}" --filter status=running \
        --format '{{.Names}}' | head -n 1
}

# Image ID the given container was started from.
running_image_id() {
    docker inspect -f '{{.Image}}' "$1" 2>/dev/null || true
}

start_slot() {
    local name="$1" port="$2" management_port="$3"

    # A dead container from an earlier failed attempt would block the name.
    docker rm -f "$name" >/dev/null 2>&1 || true

    docker run -d \
        --name "$name" \
        --label "$GAME_LABEL" \
        --label 'com.centurylinklabs.watchtower.enable=false' \
        --network "$NETWORK" \
        --env-file "$GAME_ENV_FILE" \
        --env "PORT=${CONTAINER_PORT}" \
        --env "MANAGEMENT_PORT=${CONTAINER_MANAGEMENT_PORT}" \
        --env "EXTERNAL_PORT=${port}" \
        --publish "${port}:${CONTAINER_PORT}" \
        --publish "${MANAGEMENT_BIND}:${management_port}:${CONTAINER_MANAGEMENT_PORT}" \
        --restart on-failure:3 \
        "$IMAGE" >/dev/null
}

wait_healthy() {
    local name="$1" deadline=$((SECONDS + HEALTH_TIMEOUT))

    until curl -sf --max-time 5 \
        "http://${name}:${CONTAINER_MANAGEMENT_PORT}/actuator/health" \
        | grep -q '"status":"UP"'; do

        if ! docker ps --filter "name=^${name}$" --filter status=running -q | grep -q .; then
            log "$name is no longer running"
            return 1
        fi
        if [ "$SECONDS" -gt "$deadline" ]; then
            log "$name did not report UP within ${HEALTH_TIMEOUT}s"
            return 1
        fi
        sleep 3
    done
}

drain() {
    local name="$1" attempt

    for attempt in 1 2 3; do
        if curl -sf --max-time 10 -X POST \
            -H "Authorization: Bearer ${CICD_TOKEN}" \
            "http://${name}:${CONTAINER_PORT}/api/server/servers/mine/state/draining" \
            >/dev/null; then
            return 0
        fi
        log "drain request to $name failed (attempt ${attempt}/3)"
        sleep 5
    done
    return 1
}

# --- resolve slots -----------------------------------------------------------

live="$(current_slot)"

case "$live" in
    "$SLOT_A_NAME")
        target_name="$SLOT_B_NAME"
        target_port="$SLOT_B_PORT"
        target_management_port="$SLOT_B_MANAGEMENT_PORT"
        ;;
    *)
        target_name="$SLOT_A_NAME"
        target_port="$SLOT_A_PORT"
        target_management_port="$SLOT_A_MANAGEMENT_PORT"
        ;;
esac

if [ -n "$live" ] && [ "$live" != "$SLOT_A_NAME" ] && [ "$live" != "$SLOT_B_NAME" ]; then
    notify "unknown game container '${live}' is running; refusing to swap"
    exit 1
fi

# --- pull and compare --------------------------------------------------------

log "pulling ${IMAGE}"
docker pull -q "$IMAGE" >/dev/null
new_image_id="$(docker image inspect -f '{{.Id}}' "$IMAGE")"

if [ -n "$live" ] && [ "$(running_image_id "$live")" = "$new_image_id" ]; then
    log "${live} already runs the current image; nothing to do"
    exit 0
fi

# --- start the new slot ------------------------------------------------------

notify "starting ${target_name} on port ${target_port}"
start_slot "$target_name" "$target_port" "$target_management_port"

if ! wait_healthy "$target_name"; then
    notify "${target_name} failed to become healthy; keeping ${live:-none}. Last logs:"
    docker logs --tail 50 "$target_name" 2>&1 || true
    docker rm -f "$target_name" >/dev/null 2>&1 || true
    exit 1
fi

log "${target_name} is healthy and registered"

if [ -z "$live" ]; then
    notify "${target_name} is live (no previous slot to drain)"
    exit 0
fi

# --- drain the old slot ------------------------------------------------------

if drain "$live"; then
    notify "${live} draining; waiting up to $((DRAIN_TIMEOUT / 60))m for matches to end"
    if timeout "$DRAIN_TIMEOUT" docker wait "$live" >/dev/null 2>&1; then
        log "${live} exited on its own"
    else
        notify "${live} still had sessions after $((DRAIN_TIMEOUT / 60))m; stopping it"
        docker stop -t "$STOP_GRACE" "$live" >/dev/null || true
    fi
else
    notify "could not put ${live} into DRAINING; stopping it after ${STOP_GRACE}s grace"
    docker stop -t "$STOP_GRACE" "$live" >/dev/null || true
fi

docker rm "$live" >/dev/null 2>&1 || true
notify "swap complete: ${target_name} on port ${target_port}"
