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
- **The join password stays off the command line and out of the logs.** Written to `cfg/server.cfg`
  (0600), redacted from `docker logs`, removed from the Java environment; `SERVER_PASSWORD_FILE`
  takes a Docker secret. See Secrets below.
- **Steam Workshop mods, fetched by the server.** `MODS_WORKSHOP=<id>,<id>` pulls the listed items
  anonymously at container start and keeps them as managed jars in `data/mods`. Players still have
  to subscribe themselves. See Workshop mods below.
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

## Secrets

The join password is the one real secret this image handles, and since 2.1.0 it stays on a
narrow path:

- **Two inputs.** `SERVER_PASSWORD` (plain environment variable, as before) or
  `SERVER_PASSWORD_FILE` (path of a file whose first line is the password, e.g. a Docker
  secret under `/run/secrets/`). If both are set, **`SERVER_PASSWORD_FILE` wins**. Both unset
  or blank: the server starts without a password and prints one warning on stderr. A
  `SERVER_PASSWORD_FILE` that is missing, unreadable or empty makes the container exit
  non-zero instead of silently starting open.
- **Never on the command line.** The entrypoint writes the password into the `password`
  field of the game's `cfg/server.cfg` (mode `0600`) before each start and does not pass
  `-password`, so `docker top`, `ps` and the game's own "Launched game with arguments" line
  never carry it. It is also removed from the Java process environment.
- **Redacted output.** The game prints the password on start (`Started server ... with
  password "..."`). Its stdout/stderr pass through `redact.sh`, a fixed-string filter, so
  `docker logs` shows `****` instead. Any character is fine; the filter is not a regex.
- **Appdata files are `0600`.** The server runs with `umask 077`, so its log files (which
  do contain the password, unredacted), saves and cfg are created readable by the owner
  only. Treat `latest-server-log.txt` and `logs/*.txt` as sensitive anyway: they live on the
  host, and anything that copies the data directory (backups) copies the password with it.
- **Two characters are off limits:** a comma or `//` in the password would break the
  `server.cfg` syntax, so the entrypoint refuses to start with either.

Compose with a Docker secret:

```yaml
services:
  necesse:
    image: ghcr.io/stargumbo/necesse-server:2
    environment:
      - SERVER_PASSWORD_FILE=/run/secrets/necesse_password
    secrets:
      - necesse_password
secrets:
  necesse_password:
    file: ./necesse_password.txt   # one line, not committed
```

The plain `.env` route (`SERVER_PASSWORD=...` with `env_file: .env`) keeps working unchanged.

---

## Workshop mods

Since 2.2.0 the container can install [Steam Workshop](https://steamcommunity.com/app/1169040/workshop/)
mods on the server side. With `MODS_WORKSHOP` unset or blank nothing changes: the entrypoint never
touches `mods/` and behaves exactly like 2.1.0.

```bash
docker run -d ... -e MODS_WORKSHOP=2827931647,3344934623 ghcr.io/stargumbo/necesse-server:2
```

- **`MODS_WORKSHOP`**: comma-separated Workshop item ids (the number in the item's URL). At every
  container start, before the server launches, each id is downloaded with an anonymous SteamCMD
  login (`workshop_download_item 1169040 <id>`; no Steam account is involved) and the single `.jar`
  it contains is copied into `data/mods/` as **`ws-<id>-<OriginalName>.jar`**, mode `0600`, owned
  by `PUID:PGID`. The game loads bare jars from that directory; the Workshop's own
  `content/<id>/` layout is not loadable, and the download lands outside the bind mount, which is
  why the jar is copied rather than linked. An unchanged item is revalidated (about 6 s) and the
  copy is left as it is; a changed one replaces the copy. Expect roughly 10 s per item on a fresh
  container.
- **Managed vs. your own jars.** Only files named `ws-<id>-*.jar` are managed. When an id is
  removed from `MODS_WORKSHOP`, its `ws-` jar is deleted on the next start. Jars you place in
  `data/mods/` yourself are never touched, listed, or deleted, and they load alongside the managed
  ones. Clearing `MODS_WORKSHOP` entirely turns the feature off and leaves whatever is in `mods/`
  in place; to remove managed jars, remove the ids first (or delete the `ws-*.jar` files by hand
  while the server is stopped).
- **`MODS_FAIL_FAST`** (default `true`): if any listed item fails to download, the container exits
  non-zero before the server starts, naming the id. A server that comes up with only part of its
  mod list has a different mods hash and refuses every player who subscribed to the full list, so
  not starting is the safer failure. Set it to `false` to log a warning and start with whatever
  fetched (a previously installed managed jar for the failed id is kept).
- **`data/ws-manifest.txt`** (beside `mods/`, not inside it: the game warns about every non-jar file
  in `mods/`) is rewritten after each fetch, one tab-separated line per listed
  id: the id, the jar name, the Workshop `manifest` and `timeupdated` values from SteamCMD's
  `appworkshop_1169040.acf`, and `status=ok|failed`. That is how you tell which revision of a mod
  is live. Anonymous SteamCMD always fetches the item's current revision; the copied jar is the
  only pin, so an author update is picked up on the next container start (the running server keeps
  the jar it loaded).
- **Not compatible with `LOCAL_DIR=1`.** With `-localdir` the game reads mods from `/app/mods`
  inside the image, where they would not survive a recreate; the entrypoint refuses that
  combination and exits.
- The fetch runs only at container start, never while the server is running, and not on the
  `AUTO_UPDATE_INTERVAL_MINUTES` restart path. `UPDATE_ON_START` (the Steam *app* update) and the
  Workshop items are independent: either can update without touching the other.

### For players

The server cannot push mods to anyone. To join a modded server you must **subscribe to the same
Workshop items yourself** in the Steam Workshop for Necesse, then start the game so Steam
downloads them; the mod list in the game's Mods menu should match the server's `MODS_WORKSHOP`.
What to expect:

- A client without the server's mods is refused (the server logs `connected with wrong mods`;
  the client shows the mods mismatch dialog). The **"Use server mods"** button in that dialog
  cannot download anything: it only enables mods already installed on your side.
- Mods marked `clientside=true` in their `mod.info` (UI or cosmetic mods) do not have to match:
  a client without them still joins a server that has them, and vice versa.
- The dedicated server loads mods flagged for an older game version without any warning. The
  client shows "Wrong game version" in red for such a mod but still loads it, and the join works.
- Joining with the same mod id at a different version than the server is **untested**. Keep the
  same items subscribed and let Steam update them; the server picks up author updates on its next
  restart.

---

## Environment Variables

| Variable | Purpose |
| --- | --- |
| `WORLD_NAME` | World to load or create. |
| `SERVER_PASSWORD` | Join password; blank disables. Written into `cfg/server.cfg`, never passed on the command line (see Secrets). |
| `SERVER_PASSWORD_FILE` | Path of a file holding the password (first line), e.g. a Docker secret. Wins over `SERVER_PASSWORD`. Missing/unreadable/empty file = container exits. |
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
| `MODS_WORKSHOP` | Comma-separated Steam Workshop item ids to install server-side as `data/mods/ws-<id>-*.jar` (see Workshop mods). Blank disables; not allowed with `LOCAL_DIR=1`. |
| `MODS_FAIL_FAST` | `true` (default): a failed Workshop download stops the container before the server starts. `false`: warn and start with what fetched. |
| `JAVA_OPTS` | Extra JVM flags (e.g. `-Xmx2G`). The official `StartServer-nogui.sh` uses `-XX:+UseG1GC -XX:MaxGCPauseMillis=50 …`; pass them here if you want the same tuning. |
| `JAVA_BIN` | Path of the JRE to launch with (default `/app/jre/bin/java`, the JRE bundled with the Steam build). |
| `STOP_TIMEOUT_SECONDS` | How long the entrypoint waits for the server to exit after typing `stop` before falling back to `SIGTERM` (default `50`; keep it below the container's stop grace period). |
| `PUID` / `PGID` | Host UID/GID to chown the bind mount to. The entrypoint remaps the `necesse` user before launching the JVM. |
| `IMAGE_TAG` | Override image tag in Compose (default `latest`). |

---

## Data, Permissions & Monitoring

- Saves live under `/home/necesse/.config/Necesse` (mapped to `./data`): worlds as
  `saves/worlds/<name>.zip`, config under `cfg/`, logs under `logs/`, mods under `mods/`. Back it
  up regularly before upgrades or migrations.
- Set `PUID`/`PGID` to the owner you want for the bind mount. Files the server writes are owned by
  that UID:GID and created `0600` (directories `0700`): the server runs with `umask 077` because its
  log files contain the join password.
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
- **Container exits with `Workshop mods: item(s) ... could not be fetched`:** the id is wrong, the
  item was removed or hidden, or Steam was unreachable. Check the id in the Workshop URL; the
  SteamCMD output just above names the reason (`File Not Found` for a bad id). Set
  `MODS_FAIL_FAST=false` only if you accept starting with a partial mod set.
- **Players get "wrong mods":** compare `data/ws-manifest.txt` with what they have subscribed;
  every non-clientside mod must be present on both sides at the same version.

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
