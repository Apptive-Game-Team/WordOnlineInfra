# WordOnlineInfra

Deployment and runtime configuration for the WordOnline servers. Application
code lives in the module repositories; this repository holds only what the host
running the containers needs.

Secrets are never committed. `env/*.env.example` tracks the key names; the
filled files exist on the server only.

## Contents

| Path | What |
|------|------|
| `game/` | Blue/green deployer for the game server — see [game/README.md](game/README.md) |
| `env/` | Example environment files, key names only |

## Images

| Image | Built by |
|-------|----------|
| `ghcr.io/apptive-game-team/arcane-casters-game` | WordOnlineServer — `latest` from `deploy`, `dev` from `main` |
| `ghcr.io/apptive-game-team/arcane-casters-deployer` | this repository, on every push touching `game/` |

Both are private. The host needs `docker login ghcr.io` with a `read:packages`
token before either can be pulled.

Not filled in yet: compose for `lobby`, `account`, `admin` and `website`,
the watchtower service that keeps those up to date, and the Prometheus scrape
configuration. Those need the files currently living on the server.

## Why the game server is special

Watchtower stops a container before starting its replacement. For the stateless
services that is fine. For the game server it kills every match in progress, so
`game/` replaces watchtower with a deployer that starts the new version on a
second port first, then asks the old one to drain and lets it exit by itself
once its last match ends.

Watchtower must be kept away from the game containers. The deployer labels the
ones it starts with `com.centurylinklabs.watchtower.enable=false`.
