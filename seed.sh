#!/usr/bin/env bash
#
# Create the blue and green slots for an environment by cloning a game server
# container that already runs correctly.
#
# Run once per environment. After that the deployer rebuilds each slot from its
# own previous config and this script is not needed again.
#
# The source container is left running and untouched. The slots are created
# stopped, except the one named as ACTIVE_SLOT, which is left stopped too — the
# handover from the source container to a slot is a separate, deliberate step.
#
#   SOURCE=ac-game GROUP=ac-game \
#   BLUE_DOMAIN=blue.game.ac.theevilent.com \
#   GREEN_DOMAIN=green.game.ac.theevilent.com \
#   seed.sh

set -euo pipefail

SOURCE="${SOURCE:?SOURCE container is required}"
GROUP="${GROUP:?GROUP is required, e.g. ac-game}"
BLUE_DOMAIN="${BLUE_DOMAIN:?BLUE_DOMAIN is required}"
GREEN_DOMAIN="${GREEN_DOMAIN:?GREEN_DOMAIN is required}"

BLUE_NAME="${BLUE_NAME:-${GROUP}-blue}"
GREEN_NAME="${GREEN_NAME:-${GROUP}-green}"

DOCKER_SOCKET="${DOCKER_SOCKET:-/var/run/docker.sock}"

log() {
    printf '%s [seed] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

# Clone the source container under a new name, with its own slot identity.
#
# Compose labels are dropped so `docker compose` in the source project does not
# consider these containers part of a service and remove them. DOMAIN is
# replaced because the two slots have to register distinct addresses; sharing
# one would make them fight over a single row in the Server table.
create_slot() {
    local name="$1" slot="$2" domain="$3"

    if docker inspect "$name" >/dev/null 2>&1; then
        log "${name} already exists; leaving it alone"
        return 0
    fi

    docker inspect "$SOURCE" | jq \
        --arg name "$name" \
        --arg slot "$slot" \
        --arg domain "$domain" \
        --arg group "$group_label_value" '
        .[0] as $c
        | ($c.Config | del(.Hostname, .Domainname)) + {
            Env: (
                $c.Config.Env
                | map(select(startswith("DOMAIN=") | not))
                + ["DOMAIN=" + $domain]
            ),
            Labels: (
                ($c.Config.Labels // {})
                | with_entries(select(.key | startswith("com.docker.compose.") | not))
                + {
                    "wordonline.group": $group,
                    "wordonline.slot": $slot,
                    "com.centurylinklabs.watchtower.enable": "false"
                  }
            ),
            # A drained server exits 0 on purpose. Under `always` docker would
            # read that as a crash and bring the old version straight back up,
            # so slots restart only on actual failure.
            HostConfig: ($c.HostConfig | .RestartPolicy = {Name: "on-failure", MaximumRetryCount: 3}),
            NetworkingConfig: {
                EndpointsConfig: (
                    $c.NetworkSettings.Networks
                    | with_entries(.value |= {
                        Aliases: [$name],
                        Links: .Links,
                        DriverOpts: .DriverOpts
                      })
                )
            }
        }' > "/tmp/seed-${name}.json"

    curl -sS --fail-with-body --unix-socket "$DOCKER_SOCKET" \
        -X POST "http://localhost/containers/create?name=${name}" \
        -H 'Content-Type: application/json' \
        --data "@/tmp/seed-${name}.json" >/dev/null

    rm -f "/tmp/seed-${name}.json"
    log "created ${name} (${slot}) at ${domain}, stopped"
}

group_label_value="$GROUP"

log "cloning ${SOURCE} into ${BLUE_NAME} and ${GREEN_NAME}"
create_slot "$BLUE_NAME" blue "$BLUE_DOMAIN"
create_slot "$GREEN_NAME" green "$GREEN_DOMAIN"

cat <<EOF

Both slots exist and are stopped. ${SOURCE} is still running and serving.

To hand over, start one slot and check it registers, then drain ${SOURCE}:

  docker start ${BLUE_NAME}
  docker logs -f ${BLUE_NAME}
  # once it is UP and its row shows in the Server table:
  curl -X POST -H "Authorization: Bearer \$CICD_TOKEN" \\
    http://${SOURCE}:8080/api/server/servers/mine/state/draining

${SOURCE} exits by itself when its last match ends. Remove it afterwards so it
cannot be restarted by its restart policy or by compose.
EOF
