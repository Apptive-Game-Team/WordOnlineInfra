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

# Endpoints the deployer talks to. Overridable from the compose file so a route
# change on the server side does not need a new deployer image.
HEALTH_PATH="${HEALTH_PATH:-/actuator/health}"
HEALTH_UP_PATTERN="${HEALTH_UP_PATTERN:-\"status\":\"UP\"}"
DRAIN_PATH="${DRAIN_PATH:-/api/server/servers/mine/state/draining}"
DRAIN_METHOD="${DRAIN_METHOD:-POST}"

# Slot definitions: name, published app port, published management port, and an
# optional env file layered on top of GAME_ENV_FILE.
#
# The slot env file is where the address clients should reach this slot at
# lives — PROTOCOL, DOMAIN and EXTERNAL_PORT. Those are what the server writes
# into the Server table, and behind a proxy they are not the published host
# port. Without a slot env file the published port is advertised as is.
SLOT_A_NAME="${SLOT_A_NAME:-game-blue}"
SLOT_A_PORT="${SLOT_A_PORT:-8080}"
SLOT_A_MANAGEMENT_PORT="${SLOT_A_MANAGEMENT_PORT:-8081}"
SLOT_A_ENV_FILE="${SLOT_A_ENV_FILE:-}"
SLOT_B_NAME="${SLOT_B_NAME:-game-green}"
SLOT_B_PORT="${SLOT_B_PORT:-8090}"
SLOT_B_MANAGEMENT_PORT="${SLOT_B_MANAGEMENT_PORT:-8091}"
SLOT_B_ENV_FILE="${SLOT_B_ENV_FILE:-}"

# The management port is bound to loopback so only a local Prometheus can
# scrape it. The deployer itself reaches actuator over the docker network.
MANAGEMENT_BIND="${MANAGEMENT_BIND:-127.0.0.1}"

HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-300}"   # seconds to wait for the new slot
DRAIN_TIMEOUT="${DRAIN_TIMEOUT:-3600}"    # seconds to wait for matches to end
STOP_GRACE="${STOP_GRACE:-30}"            # SIGTERM grace when drain overruns
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"

# Identifies the containers this deployer owns. Every environment on the host
# needs its own value, otherwise one deployer treats the other's slots as its
# own and drains them.
GAME_LABEL="${GAME_LABEL:-wordonline.role=game}"

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

# Running slots this deployer owns, newest first.
running_slots() {
    docker ps --filter "label=${GAME_LABEL}" --filter status=running \
        --format '{{.Names}}'
}

# Image ID the given container was started from.
running_image_id() {
    docker inspect -f '{{.Image}}' "$1" 2>/dev/null || true
}

start_slot() {
    local name="$1" port="$2" management_port="$3" slot_env_file="${4:-}"
    local -a env_args=(--env-file "$GAME_ENV_FILE")

    if [ -n "$slot_env_file" ]; then
        if [ ! -r "$slot_env_file" ]; then
            log "slot env file ${slot_env_file} is missing or unreadable"
            return 1
        fi
        # Later files win, so the slot file overrides the shared one.
        env_args+=(--env-file "$slot_env_file")
    fi

    env_args+=(--env "PORT=${CONTAINER_PORT}")
    env_args+=(--env "MANAGEMENT_PORT=${CONTAINER_MANAGEMENT_PORT}")

    # Only advertise the published port when nothing else says otherwise. A
    # --env flag would beat the slot file, so this has to stay conditional.
    if [ -z "$slot_env_file" ] || ! grep -q '^[[:space:]]*EXTERNAL_PORT=' "$slot_env_file"; then
        env_args+=(--env "EXTERNAL_PORT=${port}")
    fi

    # Never take over a name that is still serving. The caller picked the idle
    # slot, so a running container here means the state is not what we think it
    # is, and forcing it would kill a server holding live matches.
    if docker ps --filter "name=^${name}$" --filter status=running -q | grep -q .; then
        log "refusing to start ${name}: a container with that name is running"
        return 1
    fi

    # A dead container from an earlier failed attempt would block the name.
    docker rm -f "$name" >/dev/null 2>&1 || true

    docker run -d \
        --name "$name" \
        --label "$GAME_LABEL" \
        --label 'com.centurylinklabs.watchtower.enable=false' \
        --network "$NETWORK" \
        "${env_args[@]}" \
        --publish "${port}:${CONTAINER_PORT}" \
        --publish "${MANAGEMENT_BIND}:${management_port}:${CONTAINER_MANAGEMENT_PORT}" \
        --restart on-failure:3 \
        "$IMAGE" >/dev/null
}

wait_healthy() {
    local name="$1" deadline=$((SECONDS + HEALTH_TIMEOUT))

    until curl -sf --max-time 5 \
        "http://${name}:${CONTAINER_MANAGEMENT_PORT}${HEALTH_PATH}" \
        | grep -qF "$HEALTH_UP_PATTERN"; do

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
        if curl -sf --max-time 10 -X "$DRAIN_METHOD" \
            -H "Authorization: Bearer ${CICD_TOKEN}" \
            "http://${name}:${CONTAINER_PORT}${DRAIN_PATH}" \
            >/dev/null; then
            return 0
        fi
        log "drain request to $name failed (attempt ${attempt}/3)"
        sleep 5
    done
    return 1
}

# Drain a slot, wait for it to exit on its own, then free the name.
retire() {
    local name="$1"

    if drain "$name"; then
        notify "${name} draining; waiting up to $((DRAIN_TIMEOUT / 60))m for matches to end"
        if timeout "$DRAIN_TIMEOUT" docker wait "$name" >/dev/null 2>&1; then
            log "${name} exited on its own"
        else
            notify "${name} still had sessions after $((DRAIN_TIMEOUT / 60))m; stopping it"
            docker stop -t "$STOP_GRACE" "$name" >/dev/null || true
        fi
    else
        notify "could not put ${name} into DRAINING; stopping it after ${STOP_GRACE}s grace"
        docker stop -t "$STOP_GRACE" "$name" >/dev/null || true
    fi

    docker rm "$name" >/dev/null 2>&1 || true
}

# --- pull --------------------------------------------------------------------

log "pulling ${IMAGE}"
docker pull -q "$IMAGE" >/dev/null
new_image_id="$(docker image inspect -f '{{.Id}}' "$IMAGE")"

# --- resolve slots -----------------------------------------------------------

mapfile -t slots < <(running_slots)

for name in "${slots[@]}"; do
    if [ "$name" != "$SLOT_A_NAME" ] && [ "$name" != "$SLOT_B_NAME" ]; then
        notify "unknown container '${name}' carries ${GAME_LABEL}; refusing to swap"
        exit 1
    fi
done

# Both slots running means an earlier swap was interrupted — the deployer was
# restarted while it waited for the drain. Finish that swap instead of starting
# a third container: keep whichever slot already runs the new image and retire
# the rest.
if [ "${#slots[@]}" -gt 1 ]; then
    keeper=""
    for name in "${slots[@]}"; do
        if [ "$(running_image_id "$name")" = "$new_image_id" ]; then
            keeper="$name"
            break
        fi
    done
    keeper="${keeper:-${slots[0]}}"

    notify "${#slots[@]} slots running; resuming interrupted swap, keeping ${keeper}"
    for name in "${slots[@]}"; do
        [ "$name" = "$keeper" ] || retire "$name"
    done
    exit 0
fi

live="${slots[0]:-}"

case "$live" in
    "$SLOT_A_NAME")
        target_name="$SLOT_B_NAME"
        target_port="$SLOT_B_PORT"
        target_management_port="$SLOT_B_MANAGEMENT_PORT"
        target_env_file="$SLOT_B_ENV_FILE"
        ;;
    *)
        target_name="$SLOT_A_NAME"
        target_port="$SLOT_A_PORT"
        target_management_port="$SLOT_A_MANAGEMENT_PORT"
        target_env_file="$SLOT_A_ENV_FILE"
        ;;
esac

if [ -n "$live" ] && [ "$(running_image_id "$live")" = "$new_image_id" ]; then
    log "${live} already runs the current image; nothing to do"
    exit 0
fi

# --- start the new slot ------------------------------------------------------

notify "starting ${target_name} on port ${target_port}"
if ! start_slot "$target_name" "$target_port" "$target_management_port" "$target_env_file"; then
    notify "could not start ${target_name}; keeping ${live:-none}"
    exit 1
fi

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

retire "$live"
notify "swap complete: ${target_name} on port ${target_port}"
