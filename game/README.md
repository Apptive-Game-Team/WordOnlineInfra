# Game server blue/green deployer

Replaces watchtower for the `game` module. Watchtower stops a container before
it starts the replacement, which kills every match in progress. This deployer
starts the new version on the idle slot first, then drains the old one and lets
it exit by itself once its session count reaches zero.

No proxy is involved: the client resolves `protocol://domain:port` from the
`Server` table, so switching slots is just a matter of the new container
registering itself as `ACTIVE` and the old one moving to `DRAINING`.

## Environments

One deployer per environment, both defined in `docker-compose.yml`.

| | `ac-game` | `dev-game` |
|---|---|---|
| Image tag | `:latest`, pushed from WordOnlineServer `deploy` | `:dev`, pushed from its `main` |
| Slots | `ac-game-blue` 8080, `ac-game-green` 8090 | `dev-game-blue` 7080, `dev-game-green` 7090 |
| Management | 8081 / 8091, loopback only | 7081 / 7091, loopback only |
| Network | `net` | `net` |
| Label | `wordonline.role=ac-game` | `wordonline.role=dev-game` |
| Poll | 300s | 60s |
| Drain limit | 1h | 5m |
| Env file | `ac-game.env` | `dev-game.env` |
| Slot env files | `ac-game-blue.env`, `ac-game-green.env` | `dev-game-blue.env`, `dev-game-green.env` |

`GAME_LABEL` is what keeps the two apart. Each deployer only ever looks at
containers carrying its own label, so it cannot see — or drain — the other
environment's slots. Adding a third environment means a third distinct label,
container name pair and port pair.

Both environments sit on the same `net` network, so nothing at the network
layer stops a dev server from reaching production. The separation lives
entirely in the two env files: give them different databases and different
account servers.

## Slots

Only one slot per environment exists at a time. The idle slot is a name, not a
stopped container — nothing occupies it until a swap starts. Both containers run
together only during the overlap, from the moment the new one reports healthy
until the last match on the old one ends. Size the host for both environments
overlapping at once, worst case four game servers.

All four app ports stay open in the firewall at all times. Inside the container
the ports are always 8080/8081; only the published host ports differ.

Prometheus needs all four management ports as targets. Only one per environment
answers at a time, so an `up == 0` alert has to require both slots of an
environment to be down.

## Advertised address

`PROTOCOL`, `DOMAIN` and `EXTERNAL_PORT` are what the server writes into the
`Server` table, and that row is the address clients dial. It is not necessarily
the port the container publishes — behind a proxy the two differ.

Each slot therefore gets its own env file, layered on top of the environment's
shared one:

```
ac-game.env            database, account server, JWT key — both slots
  ac-game-blue.env     PROTOCOL, DOMAIN, EXTERNAL_PORT for blue
  ac-game-green.env    the same for green
```

Later files win, so a key set in the slot file overrides the shared one. Keep
the slot files down to what actually differs between blue and green.

Without slot files — drop `SLOT_A_ENV_FILE` and `SLOT_B_ENV_FILE` from the
compose file — the deployer advertises the published host port instead, which
is right when clients reach the container directly. The fallback also applies
per key: a slot file that leaves `EXTERNAL_PORT` out still gets the published
port.

## Setup

1. Copy the env examples onto the host and fill them in. They hold secrets and
   are gitignored.

   | From | To |
   |------|-----|
   | `../env/ac-game.env.example` | `ac-game.env` |
   | `../env/dev-game.env.example` | `dev-game.env` |
   | `../env/slot.env.example` | `ac-game-blue.env`, `ac-game-green.env`, `dev-game-blue.env`, `dev-game-green.env` |
   | `../env/deployer.env.example` | `.env` |

   The two game env files must not share a database or an account server.
   `PORT` and `MANAGEMENT_PORT` are absent from all of them on purpose — the
   deployer injects those.
2. `docker login ghcr.io` with a token that has `read:packages`. Both the game
   and deployer images are private.
3. Make sure the `net` network exists and the other services are attached to
   it.
4. Exclude the game containers from watchtower. The deployer labels the
   containers it starts with `com.centurylinklabs.watchtower.enable=false`;
   if watchtower runs in label-enable mode instead, no change is needed.
5. `docker compose up -d`

To run only one environment: `docker compose up -d ac-game-deployer`.

## Behaviour

Every `POLL_INTERVAL` seconds the deployer pulls `IMAGE` and compares its ID
against the running slot. When they differ:

1. Start the idle slot from the new image.
2. Poll `HEALTH_PATH` on the docker network until the body contains
   `HEALTH_UP_PATTERN` (`HEALTH_TIMEOUT`, default 300s). On failure the new
   container is removed, the last 50 log lines are reported, and the live slot
   is left untouched.
3. Call `DRAIN_METHOD DRAIN_PATH` on the old slot, with the `CICD_TOKEN` as a
   bearer token.
4. Wait for the old container to exit on its own (`DRAIN_TIMEOUT`). If matches
   outlive that, stop it with `STOP_GRACE` seconds of SIGTERM grace.

The endpoints are compose variables, not baked into the image. When the
server-side routes move, edit `docker-compose.yml` and restart the deployers.

A swap can run longer than the poll interval; `flock` makes the next tick skip
rather than start a second swap.

When no slot is running at all — the server was drained by hand, or crashed
past its restart budget — the image comparison is skipped and the next tick
just starts a slot. The deployer doubles as the thing that brings the game
server back.

## Container lifecycle

The java process is PID 1, so a drained server exiting with status 0 stops the
container by itself. Nothing has to stop it. The deployer only waits for that
exit and then removes the container so the slot name is free again.

That is why the slots run with `--restart on-failure:3` and never
`unless-stopped` — the latter would read the drain exit as something to undo
and bring the old image straight back up.

## Manual swap

```bash
docker compose exec ac-game-deployer swap.sh
```

## Updating the deployer itself

Nothing updates it automatically; it is excluded from watchtower and does not
replace itself. After a new deployer image is pushed:

```bash
docker compose pull && docker compose up -d
```

Safe at any time. Restarting a deployer mid-swap only abandons the wait — the
new slot keeps running and the next tick finishes the drain.

## Security

The deployer mounts `/var/run/docker.sock`, which is equivalent to root on the
host. Do not publish any port on these containers, and only run an image built
from this directory.
