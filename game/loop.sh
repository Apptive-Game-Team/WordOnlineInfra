#!/usr/bin/env bash
#
# Polls the registry on an interval and runs the blue/green swap when the image
# changed. This is the container entrypoint; it replaces watchtower for the
# game server only.

set -uo pipefail

POLL_INTERVAL="${POLL_INTERVAL:-300}"
LOCK_FILE=/tmp/game-swap.lock

log() {
    printf '%s [deployer] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

terminate=0
trap 'terminate=1' TERM INT

log "polling ${IMAGE} every ${POLL_INTERVAL}s"

while [ "$terminate" -eq 0 ]; do
    # A swap can outlive the poll interval while it waits for matches to end.
    # flock makes the next tick skip instead of starting a second swap.
    flock -n "$LOCK_FILE" /usr/local/bin/swap.sh
    status=$?
    case "$status" in
        0) ;;
        1) log "swap failed; will retry next tick" ;;
        *) log "swap skipped (already running)" ;;
    esac

    for _ in $(seq "$POLL_INTERVAL"); do
        [ "$terminate" -eq 0 ] || break
        sleep 1
    done
done

log "shutting down"
