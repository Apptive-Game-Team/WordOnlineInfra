#!/usr/bin/env bash
#
# Polls the registry on an interval and runs the swap when the image changed.
# This is the container entrypoint; it replaces watchtower for the game server.
#
# swap.sh takes its own lock, so a tick that lands while a swap is still
# draining — or while someone runs swap.sh by hand — steps aside on its own.

set -uo pipefail

POLL_INTERVAL="${POLL_INTERVAL:-300}"

log() {
    printf '%s [deployer] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

terminate=0
trap 'terminate=1' TERM INT

log "polling ${IMAGE} every ${POLL_INTERVAL}s"

while [ "$terminate" -eq 0 ]; do
    /usr/local/bin/swap.sh
    status=$?
    case "$status" in
        0) ;;
        75) log "another swap is in progress; skipping this tick" ;;
        *) log "swap failed; will retry next tick" ;;
    esac

    # Slept a second at a time so `docker stop` does not have to wait out the
    # whole interval before the trap runs.
    for _ in $(seq "$POLL_INTERVAL"); do
        [ "$terminate" -eq 0 ] || break
        sleep 1
    done
done

log "shutting down"
