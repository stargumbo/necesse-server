<p align="center">
  <img src="https://raw.githubusercontent.com/stargumbo/necesse-server/main/docs/assets/banner.webp" alt="necesse-server" width="100%">
</p>

**Run a Necesse server in one command. It self-updates, saves on stop, and simplifies mod management.**

[![Docker pulls](https://img.shields.io/docker/pulls/stargumbo/necesse-server)](https://hub.docker.com/r/stargumbo/necesse-server)
[![Image version](https://img.shields.io/github/v/tag/stargumbo/necesse-server?sort=semver&label=image)](https://github.com/stargumbo/necesse-server/releases)
[![Game version](https://img.shields.io/badge/dynamic/regex?url=https%3A%2F%2Fhub.docker.com%2Fv2%2Frepositories%2Fstargumbo%2Fnecesse-server%2Ftags%2F%3Fname%3D-1.%26page_size%3D1%26ordering%3Dlast_updated&search=-(%5Cd%2B%5C.%5Cd%2B%5C.%5Cd%2B)%22&replace=%241&label=game)](https://hub.docker.com/r/stargumbo/necesse-server/tags)
[![License](https://img.shields.io/github/license/stargumbo/necesse-server)](LICENSE)
[![Weekly rebuild](https://github.com/stargumbo/necesse-server/actions/workflows/publish.yml/badge.svg)](https://github.com/stargumbo/necesse-server/actions/workflows/publish.yml)

## Running in 60 seconds

Save this as `docker-compose.yml`, pick a world name and a password, and forward UDP port
`14159` on your router to this machine.

```yaml
services:
  necesse:
    image: ghcr.io/stargumbo/necesse-server:2
    container_name: necesse
    restart: unless-stopped
    stop_grace_period: 60s
    ports: ["14159:14159/udp"]
    environment:
      WORLD_NAME: MyWorld
      SERVER_PASSWORD: changeme   # never appears in the logs
    volumes: ["./data:/home/necesse/.config/Necesse"]
```

```bash
docker compose up -d
```

The server files are already in the image, so the first start takes seconds;
`docker compose logs -f` ends with `Started server ...`. Your world, config and logs live in
`./data`. The same image is on Docker Hub as `stargumbo/necesse-server:2`. It runs on amd64 and
arm64 alike: an x86 server, a Raspberry Pi 5, an Ampere or Graviton VM and Docker Desktop on
Apple Silicon all pull the right image from that one tag.

## Your world is safe

Necesse does not save on SIGTERM; it saves on the console `stop` command. So when you run
`docker stop necesse` or `docker compose down`, the container types `stop` into the server
console, waits for `Completed world save before stopping server`, and exits cleanly. Keep
`stop_grace_period: 60s` in your compose file so the save always has the time it needs; the
server also autosaves on its own schedule in between.

## Mods from a Steam collection

Put your mods in a public Steam Workshop collection, set `MODS_COLLECTION` to the number in its
URL, and the server fetches them when it starts. Change the collection in the Steam client,
restart the container, and the mod list follows. Players subscribe to the same collection, and
Steam takes care of their side.

```yaml
    environment:
      MODS_COLLECTION: "3798847765"
```

## Stays current

The image is rebuilt every Monday so the base image and the Steam server build stay fresh, and
`docker compose pull` picks that up. The server also checks Steam for a new game build on every
start, and with `AUTO_UPDATE_INTERVAL_MINUTES` set it does so while running too, saving the
world before it restarts. Pick the tag that matches how much you want to move:

| Tag | Use it when |
| --- | --- |
| `2` | you want fixes and rebuilds without breaking changes (recommended) |
| `2.5.0-1.3.3` | you want a pin that **never moves** |
| `2.5.0` | you want that release, refreshed weekly while it is the newest |
| `1.3.3` | you want the newest image built for that game version |
| `latest` | you want whatever is newest |

## Configure

| Variable | What it does |
| --- | --- |
| `WORLD_NAME` | World to load or create. A single existing world in `./data` is picked up on its own. |
| `SERVER_PASSWORD` | Join password; blank runs the server open. Kept in a file only the server can read and never shown in the logs. `SERVER_PASSWORD_FILE` reads it from a Docker secret instead. |
| `SERVER_SLOTS` | Player slots (default `10`). |
| `SERVER_OWNER` | Player name that gets owner permissions on join. |
| `SERVER_MOTD` | Message shown to players on join. |
| `PAUSE_WHEN_EMPTY` | `1` pauses the world while nobody is online. |
| `MODS_COLLECTION` | Public Steam Workshop collection id to install mods from. |
| `AUTO_UPDATE_INTERVAL_MINUTES` | Minutes between checks for a new game build while running; `0` turns it off. |
| `PUID` / `PGID` | Owner of the files in `./data` (default `1000:1000`). |

Every variable, including the ones for ports, logging, save compression, the JVM and the
explicit mod list, is in the [reference](docs/reference.md). The repository's
[`docker-compose.yml`](docker-compose.yml) and [`.env.example`](.env.example) list them all if you
prefer a `.env` file.

## For players

The server cannot send mods to you. To join a modded server, open its Workshop collection in
Steam, press **Subscribe to all**, and start the game so Steam downloads the mods. When the
operator changes the collection, Steam adds or removes the subscriptions for you on your next
start.

If you see the **wrong mods** dialog, your enabled mods do not match the server's. Subscribe to
the server's collection, or disable the extra mods, and try again; the **Use server mods** button
only enables mods you already have, it cannot download any. Mods marked as client-side (UI and
cosmetic mods) do not have to match.

## More

- [Reference](docs/reference.md): every environment variable, `docker run`, tags and registries,
  secrets, the console, data and permissions, updates and troubleshooting, contributing.
- [Coming from another image](docs/migration.md): keep your volumes and variable names, and how
  to go back.
- [Internals](docs/internals.md): how the graceful stop, the password path and the Workshop
  fetch work.
- [Changelog](CHANGELOG.md).

Built on [andreas-glaser/necesse-docker-server](https://github.com/andreas-glaser/necesse-docker-server),
whose entrypoint and environment contract this image keeps. MIT licensed, with the original
copyright notice kept in [LICENSE](LICENSE).

<!-- docker-hub-overview-ends-here -->
