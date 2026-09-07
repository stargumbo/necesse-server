# Necesse Dedicated Server (Docker)

[![CI](https://github.com/stargumbo/necesse-server/actions/workflows/ci.yml/badge.svg)](https://github.com/stargumbo/necesse-server/actions/workflows/ci.yml)
[![Publish](https://github.com/stargumbo/necesse-server/actions/workflows/publish.yml/badge.svg)](https://github.com/stargumbo/necesse-server/actions/workflows/publish.yml)
[![Latest tag](https://img.shields.io/github/v/tag/stargumbo/necesse-server?sort=semver)](https://github.com/stargumbo/necesse-server/tags)

Dockerised [Necesse](https://necessegame.com/) dedicated server, published as
**`ghcr.io/stargumbo/necesse-server`**. It installs the server from Steam (app `1169370`),
keeps saves on the host, exposes every server flag through environment variables, and
saves the world on `docker stop`.

This is a fork of [andreas-glaser/necesse-docker-server](https://github.com/andreas-glaser/necesse-docker-server)
(MIT). The entrypoint and environment contract are upstream's; the image itself is rebuilt:

- **Base image `ghcr.io/steamcmd/steamcmd:debian-13`** (the official SteamCMD image, rebuilt
  daily) instead of a hand-rolled SteamCMD install on Debian bullseye.
- **No distro Java.** The Steam build of the server ships its own JRE (`jre/bin/java`, currently
  Temurin 17); `Server.jar` runs under that, so there is no JVM-version drift between the image and
  the game.
- **Graceful stop that actually saves.** The server does not save on `SIGTERM`; it saves on the
  console `stop` command. The entrypoint holds the server's stdin open on a FIFO and types `stop`
  into it when the container is stopped (and before an auto-update restart), then waits for the
  JVM to exit. Give it a `stop_grace_period` of 60s.
- **GHCR publishing with weekly rebuilds.** Tag pushes build `:X.Y.Z`, `:X.Y`, `:X` and `:latest`;
  a Monday cron rebuilds the newest tag with `pull: true` so the base image and the Steam server
  build refresh unattended. All GitHub Actions are pinned by commit SHA; Dependabot tracks both.
- **amd64 only.**

---

## Run With `docker run`

```bash
docker run -d \
  --name necesse \
  --stop-timeout 60 \
  -p 14159:14159/udp \
  -v "$PWD/data:/home/necesse/.config/Necesse" \
  -e WORLD_NAME=MyWorld \
  -e SERVER_PASSWORD=changeme \
  -e SERVER_SLOTS=10 \
  -e UPDATE_ON_START=true \
  -e AUTO_UPDATE_INTERVAL_MINUTES=60 \
  ghcr.io/stargumbo/necesse-server:latest
```

- Replace `changeme` with the password you want (leave blank to disable).
- The single bind mount stores saves, logs, and `cfg/server.cfg` under `./data`.
- Forward UDP port `14159` from your router/firewall to this host.
- `--stop-timeout 60` gives the server time to save when you `docker stop` it.

To follow a specific image, change the tag to e.g. `:2.0.0` (or `:2.0`, `:2`).

---

## Run With Docker Compose

`docker-compose.yml` (the one in this repository is the same, with every variable listed):

```yaml
services:
  necesse:
    image: ghcr.io/stargumbo/necesse-server:${IMAGE_TAG:-latest}
    container_name: necesse
    restart: unless-stopped
    stop_grace_period: 60s
    ports:
      - "14159:14159/udp"
    environment:
      - WORLD_NAME=${WORLD_NAME:-MyWorld}
      - SERVER_PASSWORD=${SERVER_PASSWORD}
      - SERVER_SLOTS=${SERVER_SLOTS}
      - SERVER_OWNER=${SERVER_OWNER}
      - SERVER_MOTD=${SERVER_MOTD}
      - PAUSE_WHEN_EMPTY=${PAUSE_WHEN_EMPTY}
      - UPDATE_ON_START=${UPDATE_ON_START}
      - AUTO_UPDATE_INTERVAL_MINUTES=${AUTO_UPDATE_INTERVAL_MINUTES:-0}
      - PUID=${PUID}
      - PGID=${PGID}
    volumes:
      - ./data:/home/necesse/.config/Necesse
    mem_limit: 2g
    mem_reservation: 512m
```

```bash
cp .env.example .env   # edit WORLD_NAME, SERVER_PASSWORD, PUID/PGID, ...
docker compose up -d
docker compose logs -f necesse
```

Never commit `.env`; it is ignored by `.gitignore`. Ship secrets through `.env` or your
orchestrator, not through the image.

---

## Environment Variables

| Variable | Purpose |
| --- | --- |
| `WORLD_NAME` | World to load or create. |
| `SERVER_PASSWORD` | Join password; blank disables. |
| `SERVER_SLOTS` | Maximum concurrent players (1–250). |
| `SERVER_OWNER` | Owner player name (grants admin on join). |
| `SERVER_MOTD` | Message shown on join (`\n` for newline). |
| `SERVER_PORT` | UDP port inside the container (default 14159). |
| `PAUSE_WHEN_EMPTY` | `1` pauses when empty, `0` keeps running. |
| `GIVE_CLIENTS_POWER` | `1` smoother clients, `0` strict validation. |
| `ENABLE_LOGGING` | `1` writes log files, `0` disables. |
| `ZIP_SAVES` | `1` compresses saves, `0` stores plain folders. |
| `SERVER_LANGUAGE` | Language code for server messages (`en`, `de`, …). |
| `MAX_CLIENT_LATENCY` | Max seconds before kick (`-maxlatency`). |
| `SETTINGS_FILE` | Path to a custom `server.cfg` inside the container. |
| `BIND_IP` | Specific IP/interface for the server to bind. |
| `LOCAL_DIR` | `1` appends `-localdir` flag for local storage. |
| `DATA_DIR`, `LOGS_DIR` | Override in-container paths (folders auto-created). |
| `UPDATE_ON_START` | `true` runs SteamCMD on every boot. |
| `AUTO_UPDATE_INTERVAL_MINUTES` | Background poll interval; the server is stopped via console `stop` (saving the world), updated, and restarted when a new Steam build is detected (`0` disables). |
| `JAVA_OPTS` | Extra JVM flags (e.g. `-Xmx2G`). The official `StartServer-nogui.sh` uses `-XX:+UseG1GC -XX:MaxGCPauseMillis=50 …`; pass them here if you want the same tuning. |
| `JAVA_BIN` | Path of the JRE to launch with (default `/app/jre/bin/java`, the JRE bundled with the Steam build). |
| `STOP_TIMEOUT_SECONDS` | How long the entrypoint waits for the server to exit after typing `stop` before falling back to `SIGTERM` (default `50`; keep it below the container's stop grace period). |
| `PUID` / `PGID` | Host UID/GID to chown the bind mount to. The entrypoint remaps the `necesse` user before launching the JVM. |
| `IMAGE_TAG` | Override image tag in Compose (default `latest`). |

---

## Data, Permissions & Monitoring

- Saves live under `/home/necesse/.config/Necesse` (mapped to `./data`): worlds as
  `saves/worlds/<name>.zip`, config under `cfg/`, logs under `logs/`. Back it up regularly before
  upgrades or migrations.
- Set `PUID`/`PGID` to the owner you want for the bind mount. Files the server writes are owned by
  that UID:GID.
- Health check: `pgrep -f 'Server.jar'`. Use `docker compose ps` or
  `docker inspect --format '{{.State.Health.Status}}' necesse` to verify.
- Tail logs with `docker compose logs -f necesse` or from `data/logs/`.

### Graceful stop

`docker stop` (and `docker compose stop`/`down`) triggers the entrypoint's `TERM` trap, which types
`stop` into the server console. The server logs `Starting world save` … `Completed world save
before stopping server` and exits; the container follows with exit code 0. A plain `SIGTERM` to
the JVM would **not** save, which is why the container must be given a real grace period
(`stop_grace_period: 60s` / `--stop-timeout 60`). With Docker's default 10-second grace the save
still usually completes on a small world, but do not rely on it.

The server also autosaves on its own schedule (with `LATEST_BACKUP*.zip` copies), so an unclean
stop loses at most the interval since the last autosave.

---

## Updates & Troubleshooting

- **Image updates:** every Monday the publish workflow rebuilds the newest release tag against the
  current SteamCMD base and the current Steam server build and re-pushes the same tags, so
  `docker compose pull && docker compose up -d` picks up a fresh image without a new release.
- **In-container updates:** `UPDATE_ON_START=true` runs SteamCMD each start.
  `AUTO_UPDATE_INTERVAL_MINUTES` (e.g. `60`) enables polling; when Steam publishes a new build the
  server is stopped via console `stop`, updated, and restarted inside the same container.
- **SteamCMD errors:** the container keeps the previous server build if SteamCMD fails; inspect
  `/home/necesse/.local/share/Steam/logs/stderr.txt` inside the container for details.
- **Players cannot join:** confirm UDP port forwarding and public IP. Some port testers give false
  negatives—validate in-game if unsure.
- **Config changes ignored:** edit `.env`, then `docker compose up -d` to recreate with new flags.
  Necesse rewrites `server.cfg` on a clean shutdown, so do not hand-edit it while the server runs;
  the environment variables are reapplied on every start.
- **Bundled JRE missing:** if a future Steam build changes its layout the entrypoint exits with
  `Bundled JRE not found at /app/jre/bin/java`; set `JAVA_BIN` to the new path.

---

## Clone, Develop, Contribute

```bash
git clone https://github.com/stargumbo/necesse-server.git
cd necesse-server
cp .env.example .env
docker build -t necesse-server:dev .
docker compose up -d
```

- CI (`.github/workflows/ci.yml`) runs shellcheck and a full image build on pushes to `main` and
  on pull requests.
- Release process:
  1. Update [`CHANGELOG.md`](CHANGELOG.md) and documentation.
  2. `git tag -a vX.Y.Z -m "vX.Y.Z"` and `git push --follow-tags`.
  3. `.github/workflows/publish.yml` builds and pushes `ghcr.io/stargumbo/necesse-server`
     `:X.Y.Z`, `:X.Y`, `:X`, `:latest`. The same workflow can be dispatched manually to rebuild the
     newest tag.

---

## Reference

- [Necesse Dedicated Server wiki](https://wiki.necesse.net/wiki/Dedicated_server)
- [Necesse Multiplayer Linux guide](https://wiki.necesse.net/wiki/Multiplayer-Linux)
- [steamcmd/docker](https://github.com/steamcmd/docker) — the base image
- [andreas-glaser/necesse-docker-server](https://github.com/andreas-glaser/necesse-docker-server) — upstream

---

## License

Released under the [MIT License](LICENSE). The original work is copyright (c) 2025 Andreas
Christoph Glaser; this fork keeps that license and notice.
