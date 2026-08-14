# Game server blue/green deployer

Replaces watchtower for the `game` module. Watchtower stops a container before
it starts the replacement, which kills every match in progress. This deployer
starts the new version on the idle slot first, then drains the live one and
lets it exit by itself once its session count reaches zero.

No proxy switching is involved: the client asks the lobby for a game server and
gets the `protocol://domain:port` the server registered in the `Server` table.
Blue and green register different hostnames, so handing matches to the new slot
is just the new container coming up `ACTIVE` and the old one going `DRAINING`.

## Slots

Each environment owns two containers. Both exist at all times; one runs, the
other sits stopped. A deploy rebuilds the stopped one on the new image, starts
it, then drains the live one — which then sits stopped, ready to be the target
of the next deploy.

| | `ac-game` | `dev-game` |
|---|---|---|
| Image tag | `:latest`, pushed from WordOnlineServer `deploy` | `:dev`, pushed from its `main` |
| Containers | `ac-game-blue`, `ac-game-green` | `dev-game-blue`, `dev-game-green` |
| Hostnames | `blue.game.ac.theevilent.com`, `green.game.ac.theevilent.com` | `blue.game.dev.ac.theevilent.com`, `green.game.dev.ac.theevilent.com` |
| Group label | `wordonline.group=ac-game` | `wordonline.group=dev-game` |
| Poll | 300s | 60s |
| Drain limit | 1h | 5m |

Both slots run together only during the overlap, from the moment the new one
reports healthy until the last match on the old one ends. Size the host for
both environments overlapping at once — worst case four game servers.

Each slot needs its own hostname in nginx, pointing at that container. Two
slots sharing a hostname cannot overlap: nginx can only route it to one of
them, and both would write to the same `Server` row, since the server looks its
row up by domain and port.

## How a slot is defined

Nowhere in this repository. A slot is defined by its own container.

The deployer rebuilds a slot the way watchtower does — inspect the container,
hand the same config back to the create endpoint, swap only the image. Volumes,
env, networks, labels and resource limits come from the container that was
already running correctly, so they cannot drift from what the slot needs, and
there is no list here to forget an entry from.

Config the image supplies is subtracted first. A container's inspected env and
labels mix what was asked for at create time with what the image itself
defined, and carrying the mix forward would let the old image's `JAVA_HOME` or
entrypoint shadow the new image's. Only the deliberate settings are carried
over.

The cost is that a slot's definition lives only on the host. If the host is
rebuilt, the slots are seeded again from a container brought up by hand or by
`~/deploy/game/docker-compose.yml`.

## Seeding

Run once per environment, cloning a game container that already runs correctly:

```bash
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
  -e SOURCE=ac-game -e GROUP=ac-game \
  -e BLUE_DOMAIN=blue.game.ac.theevilent.com \
  -e GREEN_DOMAIN=green.game.ac.theevilent.com \
  --entrypoint /usr/local/bin/seed.sh \
  ghcr.io/apptive-game-team/arcane-casters-deployer:latest
```

Both slots are created stopped. The source container keeps running and serving
— seeding does not hand over. `seed.sh` prints the handover steps: start one
slot, confirm it registers, drain the source, then remove the source so its
restart policy or its compose project cannot bring it back.

Two things are changed on the way in. `DOMAIN` becomes the slot's own
hostname, because two slots sharing one address would fight over a single
`Server` row. And compose labels are dropped, so `docker compose` in the source
project does not treat the clones as its own service and remove them.

## Setup

1. Create `.env` from `../env/deployer.env.example` with the image tags and a
   `CICD_TOKEN` per environment (a JWT carrying the `WORDONLINE_CICD`
   authority; the dev token is not valid in production).
2. `docker login ghcr.io` with a token that has `read:packages`. Both the game
   and deployer images are private.
3. Point nginx at the four slot hostnames.
4. Seed the slots for each environment, and hand over from the old container.
5. `docker compose up -d`

To run only one environment: `docker compose up -d ac-game-deployer`.

## Behaviour

Every `POLL_INTERVAL` seconds the deployer pulls `IMAGE` and compares its ID
against the live slot. When they differ:

1. Rebuild the idle slot from its own config on the new image, and start it.
2. Poll `HEALTH_PATH` over the docker network until the body contains
   `HEALTH_UP_PATTERN` (`HEALTH_TIMEOUT`). On failure the new slot is stopped,
   its last 50 log lines are reported, and the live slot is left alone.
3. Call `DRAIN_METHOD DRAIN_PATH` on the live slot with the `CICD_TOKEN` as a
   bearer token.
4. Wait for it to exit on its own (`DRAIN_TIMEOUT`). If matches outlive that,
   stop it with `STOP_GRACE` seconds of SIGTERM grace.

A swap can run longer than the poll interval; `flock` makes the next tick skip
rather than start a second swap.

If both slots are found running — the deployer was restarted mid-drain — the
one already on the new image is kept and the other is drained, finishing the
interrupted swap instead of starting a third container.

If no slot is running at all, the idle one is rebuilt on the current image and
started. The deployer doubles as the thing that brings the game server back.

## Container lifecycle

The java process is PID 1, so a drained server exiting with status 0 stops the
container by itself. The deployer only waits for that exit; it does not remove
the container, because that container's config is what the next swap rebuilds
the slot from.

Slots are seeded with `on-failure`, never `always`, even when the source
container used `always`. A drained server exits 0 on purpose, and `always`
would read that as a crash and bring the old version straight back up. The swap
also stops the container explicitly after it exits, in case a slot picked up a
reviving policy some other way.

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
