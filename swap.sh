#!/usr/bin/env bash
#
# Blue/green swap for the game server.
#
# Both slots exist as containers at all times; one runs, the other sits
# stopped. A swap recreates the stopped slot from its own previous config with
# the new image, starts it, then drains the running one and lets it exit by
# itself once its last match ends.
#
# The config is cloned the way watchtower does it — inspect the container and
# hand the same Config/HostConfig/NetworkingConfig back to the create endpoint
# with only the image swapped. Nothing about the slot is described here, so
# volumes, env files, networks and labels cannot drift out of sync with what
# the slot actually needs.
#
# Exit codes: 0 = swapped or already up to date, 1 = failed (live slot untouched).

set -euo pipefail

# Serialise every invocation, not just the polling loop's. A swap runs for as
# long as a drain takes, so a hand-run `swap.sh` and a scheduled tick overlap
# easily — and two swaps at once read each other's half-finished work as an
# interrupted swap and drain the slot the other just started.
#
# Exit 75 (EX_TEMPFAIL) means another swap holds the lock.
LOCK_FILE="${LOCK_FILE:-/tmp/game-swap.lock}"
if [ "${SWAP_LOCK_HELD:-}" != "1" ]; then
    exec env SWAP_LOCK_HELD=1 flock -n -E 75 "$LOCK_FILE" "$0" "$@"
fi

IMAGE="${IMAGE:?IMAGE is required}"
CICD_TOKEN="${CICD_TOKEN:?CICD_TOKEN is required}"

# Every container carrying this label belongs to this deployer. Each
# environment on the host needs its own value, otherwise one deployer treats
# the other's slots as its own and drains them.
GROUP_LABEL="${GROUP_LABEL:?GROUP_LABEL is required}"

# Ports inside the container. The deployer reaches the slots over the docker
# network, so nothing has to be published on the host.
CONTAINER_PORT="${CONTAINER_PORT:-8080}"
CONTAINER_MANAGEMENT_PORT="${CONTAINER_MANAGEMENT_PORT:-8081}"

# Endpoints on the game server. Overridable so a route change does not need a
# new deployer image.
HEALTH_PATH="${HEALTH_PATH:-/actuator/health}"
HEALTH_UP_PATTERN="${HEALTH_UP_PATTERN:-\"status\":\"UP\"}"
DRAIN_PATH="${DRAIN_PATH:-/api/server/servers/mine/state/draining}"
DRAIN_METHOD="${DRAIN_METHOD:-POST}"

HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-300}"   # seconds to wait for the new slot
DRAIN_TIMEOUT="${DRAIN_TIMEOUT:-3600}"    # seconds to wait for matches to end

# Seconds to leave both slots up after the new one reports UP, before the old
# one is drained.
#
# The lobby does not read the Server table to decide availability. It rediscovers
# the rows and probes each slot's public URL on its own schedule
# (`gameserver.refresh-interval`, 15s by default), and a slot counts as available
# only once one of those probes has actually succeeded. Draining the old slot the
# moment the new one answers on the management port therefore takes the old slot
# out of rotation before the lobby has had a tick to put the new one in — which
# is what a match sees as "no available game server". Waiting here spans at least
# one refresh, so the pool is never empty.
SETTLE_DELAY="${SETTLE_DELAY:-30}"
STOP_GRACE="${STOP_GRACE:-30}"            # SIGTERM grace when drain overruns
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"

DOCKER_SOCKET="${DOCKER_SOCKET:-/var/run/docker.sock}"
# Payloads are kept after a failed create so the container can be restored by
# hand instead of being lost.
SPOOL_DIR="${SPOOL_DIR:-/tmp/swap}"

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

api() {
    local method="$1" path="$2"
    shift 2
    curl -sS --fail-with-body --unix-socket "$DOCKER_SOCKET" \
        -X "$method" "http://localhost${path}" "$@"
}

all_slots() {
    docker ps -a --filter "label=${GROUP_LABEL}" --format '{{.Names}}'
}

# Anything not running counts as idle. A freshly seeded slot sits in `created`
# rather than `exited`, and a filter on `exited` alone would miss it.
running_slots() {
    docker ps --filter "label=${GROUP_LABEL}" --format '{{.Names}}'
}

slot_of() {
    docker inspect -f '{{index .Config.Labels "wordonline.slot"}}' "$1" 2>/dev/null || true
}

running_image_id() {
    docker inspect -f '{{.Image}}' "$1" 2>/dev/null || true
}

# Rebuild a container under the same name from its own config, on a new image.
#
# A container's inspected config mixes two things: what was asked for at create
# time, and what the image supplied. Copying the mix forward would pin the new
# image to the old image's defaults — a new JAVA_HOME or entrypoint would be
# shadowed by the old one and the swap would quietly run the wrong thing. So
# every field the image also defines is subtracted first, and only the
# deliberate settings are carried over. This is what watchtower does too.
#
# Hostname is dropped as well; keeping it would pin the new container to the
# old one's ID.
recreate() {
    local name="$1" image_id="$2"
    local payload="${SPOOL_DIR}/${name}.json"
    local old_image image_config

    mkdir -p "$SPOOL_DIR"

    old_image="$(docker inspect -f '{{.Image}}' "$name")"
    image_config="$(docker image inspect "$old_image" | jq '.[0].Config')"

    if ! docker inspect "$name" | jq \
        --arg image "$image_id" \
        --argjson img "$image_config" '
        .[0] as $c
        | $c.Config as $cfg
        | {
            Image: $image,
            Env: (($cfg.Env // []) - ($img.Env // [])),
            Labels: (
                ($cfg.Labels // {})
                | with_entries(
                    select(($img.Labels // {})[.key] != .value)
                  )
            ),
            HostConfig: $c.HostConfig,
            NetworkingConfig: {
                EndpointsConfig: (
                    $c.NetworkSettings.Networks
                    | with_entries(.value |= {
                        Aliases: (.Aliases // [] | map(select(. != null))),
                        Links: .Links,
                        DriverOpts: .DriverOpts
                      })
                )
            }
        }
        # Carried over only when the container overrode the image.
        + ( ["Cmd", "Entrypoint", "User", "WorkingDir", "ExposedPorts",
             "Volumes", "Healthcheck", "StopSignal", "Tty", "OpenStdin"]
            | map(select($cfg[.] != $img[.]) | {(.): $cfg[.]})
            | add // {}
          )' > "$payload"; then
        log "could not build a create payload for ${name}"
        return 1
    fi

    docker rm "$name" >/dev/null

    if ! api POST "/containers/create?name=${name}" \
        -H 'Content-Type: application/json' --data "@${payload}" >/dev/null; then
        notify "recreating ${name} failed; its config is saved at ${payload} inside the deployer"
        return 1
    fi

    rm -f "$payload"
    docker start "$name" >/dev/null
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

# Drain a slot and wait for it to exit. The container is left in place, not
# removed — its config is what the next swap rebuilds it from.
retire() {
    local name="$1"

    if drain "$name"; then
        notify "${name} draining; waiting up to $((DRAIN_TIMEOUT / 60))m for matches to end"
        if timeout "$DRAIN_TIMEOUT" docker wait "$name" >/dev/null 2>&1; then
            log "${name} exited on its own"
            # Belt and braces against a restart policy reviving it: the exit is
            # deliberate, so make sure docker leaves it down.
            docker stop -t 5 "$name" >/dev/null 2>&1 || true
            return 0
        fi
        notify "${name} still had sessions after $((DRAIN_TIMEOUT / 60))m; stopping it"
    else
        notify "could not put ${name} into DRAINING; stopping it after ${STOP_GRACE}s grace"
    fi

    docker stop -t "$STOP_GRACE" "$name" >/dev/null || true
}

# --- pull --------------------------------------------------------------------

log "pulling ${IMAGE}"
docker pull -q "$IMAGE" >/dev/null
new_image_id="$(docker image inspect -f '{{.Id}}' "$IMAGE")"

# --- resolve slots -----------------------------------------------------------

mapfile -t all < <(all_slots)
mapfile -t running < <(running_slots)

idle=()
for name in "${all[@]}"; do
    is_running=0
    for up in "${running[@]}"; do
        [ "$name" = "$up" ] && is_running=1 && break
    done
    [ "$is_running" -eq 1 ] || idle+=("$name")
done

if [ "${#all[@]}" -eq 0 ]; then
    notify "no container carries ${GROUP_LABEL}; the slots have to be seeded first"
    exit 1
fi

# Both slots up means an earlier swap was interrupted, most likely the deployer
# restarting while it waited for a drain. Finish that swap rather than start a
# third container: keep whichever slot already runs the new image.
if [ "${#running[@]}" -gt 1 ]; then
    keeper=""
    for name in "${running[@]}"; do
        if [ "$(running_image_id "$name")" = "$new_image_id" ]; then
            keeper="$name"
            break
        fi
    done
    keeper="${keeper:-${running[0]}}"

    notify "${#running[@]} slots running; resuming interrupted swap, keeping ${keeper}"
    for name in "${running[@]}"; do
        [ "$name" = "$keeper" ] || retire "$name"
    done
    exit 0
fi

live="${running[0]:-}"

if [ -n "$live" ] && [ "$(running_image_id "$live")" = "$new_image_id" ]; then
    log "${live} already runs the current image; nothing to do"
    exit 0
fi

# With nothing running, bring the group back up in place rather than swapping.
if [ -z "$live" ]; then
    target="${idle[0]}"
    notify "no slot is running; restarting ${target} on the current image"
    recreate "$target" "$new_image_id" || exit 1
    wait_healthy "$target" || exit 1
    notify "${target} is live"
    exit 0
fi

target=""
for name in "${idle[@]}"; do
    [ "$name" = "$live" ] && continue
    target="$name"
    break
done

if [ -z "$target" ]; then
    notify "${live} is running but has no idle counterpart; seed the second slot first"
    exit 1
fi

# --- swap --------------------------------------------------------------------

notify "swapping $(slot_of "$live") -> $(slot_of "$target"): rebuilding ${target}"

if ! recreate "$target" "$new_image_id"; then
    notify "could not rebuild ${target}; keeping ${live}"
    exit 1
fi

if ! wait_healthy "$target"; then
    notify "${target} failed to become healthy; keeping ${live}. Last logs:"
    docker logs --tail 50 "$target" 2>&1 || true
    docker stop -t 10 "$target" >/dev/null 2>&1 || true
    exit 1
fi

log "${target} is healthy and registered"

if [ "$SETTLE_DELAY" -gt 0 ]; then
    log "letting the lobby pick ${target} up; draining ${live} in ${SETTLE_DELAY}s"
    sleep "$SETTLE_DELAY"
fi

retire "$live"
notify "swap complete: ${target} is live, ${live} is stopped and idle"
