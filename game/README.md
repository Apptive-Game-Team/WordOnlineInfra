# Game server blue/green deployer

Replaces watchtower for the `game` module. Watchtower stops a container before
it starts the replacement, which kills every match in progress. This deployer
starts the new version on the idle slot first, then drains the old one and lets
it exit by itself once its session count reaches zero.

No proxy is involved: the client resolves `protocol://domain:port` from the
`Server` table, so switching slots is just a matter of the new container
registering itself as `ACTIVE` and the old one moving to `DRAINING`.

## Slots

| Slot | Container | App port | Management port |
|------|-----------|----------|-----------------|
| A | `game-blue` | 8080 | 8081 (loopback only) |
| B | `game-green` | 8090 | 8091 (loopback only) |

Both app ports stay open in the firewall at all times. Inside the container the
ports are always 8080/8081; only the published host ports differ, and the
published app port is injected as `EXTERNAL_PORT` so the server registers the
address clients can actually reach.

Prometheus needs both management ports as targets. Only one answers at a time,
so an `up == 0` alert has to require both to be down.

## Setup

1. Copy `../env/game.env.example` to `game.env` and fill it in — everything the
   server needs except `PORT`, `MANAGEMENT_PORT` and `EXTERNAL_PORT`, which the
   deployer injects per slot. This file holds secrets and is gitignored.
2. Create a `.env` next to the compose file with `GAME_IMAGE`, `CICD_TOKEN`
   (a JWT carrying the `WORDONLINE_CICD` authority) and optionally
   `DISCORD_WEBHOOK_URL`.
3. Make sure the `wordonline` docker network exists and the other services are
   attached to it.
4. Exclude the game containers from watchtower. The deployer labels the
   containers it starts with `com.centurylinklabs.watchtower.enable=false`;
   if watchtower runs in label-enable mode instead, no change is needed.
5. `docker compose up -d --build`

## Behaviour

Every `POLL_INTERVAL` seconds the deployer pulls `IMAGE` and compares its ID
against the running slot. When they differ:

1. Start the idle slot from the new image.
2. Poll `/actuator/health` on the docker network until it reports `UP`
   (`HEALTH_TIMEOUT`, default 300s). On failure the new container is removed,
   the last 50 log lines are reported, and the live slot is left untouched.
3. `POST /api/server/servers/mine/state/draining` on the old slot.
4. Wait for the old container to exit on its own (`DRAIN_TIMEOUT`, default
   1h). If matches outlive that, stop it with `STOP_GRACE` seconds of SIGTERM
   grace.

A swap can run longer than the poll interval; `flock` makes the next tick skip
rather than start a second swap.

The slots run with `--restart on-failure:3`, never `unless-stopped`. A drained
server exits with status 0, and `unless-stopped` would bring it straight back
up on the old image.

## Manual swap

```bash
docker compose exec game-deployer swap.sh
```

## Security

The deployer mounts `/var/run/docker.sock`, which is equivalent to root on the
host. Do not publish any port on this container, and only run an image built
from this directory.
