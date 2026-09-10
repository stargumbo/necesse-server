# Necesse Dedicated Server (Docker)

[![CI](https://github.com/stargumbo/necesse-server/actions/workflows/ci.yml/badge.svg)](https://github.com/stargumbo/necesse-server/actions/workflows/ci.yml)
[![Publish](https://github.com/stargumbo/necesse-server/actions/workflows/publish.yml/badge.svg)](https://github.com/stargumbo/necesse-server/actions/workflows/publish.yml)
[![Latest tag](https://img.shields.io/github/v/tag/stargumbo/necesse-server?sort=semver)](https://github.com/stargumbo/necesse-server/tags)

Dockerised [Necesse](https://necessegame.com/) dedicated server, published as
**`ghcr.io/stargumbo/necesse-server`** and, with the same digests, as
**`stargumbo/necesse-server`** on Docker Hub. It installs the server from Steam (app `1169370`),
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
- **One build, two registries, weekly rebuilds.** Every release is pushed to GHCR and Docker Hub
  from a single build, tagged by image version (`:X.Y.Z`, `:X.Y`, `:X`, `:latest`) and by game
  version (`:X.Y.Z-<game>`, `:<game>`, `:<game major.minor>`); a Monday cron rebuilds the newest
  release with `pull: true` so the base image and the Steam server build refresh unattended. See
  Tags below. All GitHub Actions are pinned by commit SHA; Dependabot tracks both.
- **The join password stays off the command line and out of the logs.** Written to `cfg/server.cfg`
  (0600), redacted from `docker logs`, removed from the Java environment; `SERVER_PASSWORD_FILE`
  takes a Docker secret. See Secrets below.
- **Steam Workshop mods, fetched by the server.** `MODS_COLLECTION=<collection id>` resolves a
  public Workshop collection at container start and keeps its items as managed jars in
  `data/mods`; edit the collection in Steam and restart the container to change mods. Players
  subscribe to the collection. `MODS_WORKSHOP=<id>,<id>` is the explicit-list alternative. See
  Workshop mods below.
- **Works with volumes and variable names from other Necesse images.** brammys-style and
  karyeet-style mounts are used in place, their environment names are accepted as aliases, a single
  existing world is picked up by name, and `docker exec necesse console players` replaces
  `docker attach`. See Coming from another image.
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

To follow a specific image, change the tag (see Tags below); `:2` is the recommended pin.

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

## Tags

The image is pushed to two registries from one build, so a tag resolves to the same digest on
both. Use whichever your platform finds more easily (Synology Container Manager and Portainer
search Docker Hub by default):

| Registry | Image |
| --- | --- |
| GitHub Container Registry | `ghcr.io/stargumbo/necesse-server` |
| Docker Hub | `stargumbo/necesse-server` (`docker.io/stargumbo/necesse-server`) |

Each release `vX.Y.Z` of this image is built against one Necesse version, `<game>` (for example
`1.3.3`, read from `Server.jar` inside the published image), and carries these tags:

| Tag | Example | Points at | Moves when |
| --- | --- | --- | --- |
| `X` | `2` | newest image of that major (**recommended pin**) | every release and weekly rebuild within the major |
| `X.Y` | `2.3` | newest image of that minor | every patch release and weekly rebuild within the minor |
| `X.Y.Z` | `2.3.1` | that release | the weekly rebuild, while it is the newest release (same code, refreshed base image and Steam build) |
| `latest` | `latest` | newest image | every release and weekly rebuild |
| `<game>` | `1.3.3` | newest image built for that game version | every release built for that game version; a weekly rebuild only when the game version changed |
| `<game major.minor>` | `1.3` | newest image built for that game minor | same rule as `<game>` |
| `X.Y.Z-<game>` | `2.3.1-1.3.3` | exactly one image, forever | never |

So `2` follows fixes and rebuilds without breaking changes, `1.3.3` follows the newest image that
runs that game version, and `2.3.1-1.3.3` is the fully immutable pin. The weekly rebuild
(Mondays, 05:17 UTC) exists so that the SteamCMD base image and the Steam server build stay
current between releases; when Steam ships a new game version, the rebuild publishes new
`<game>` tags for it and the previous `<game>` tags keep pointing at the last image built for the
previous version.

---

## Coming from another image

The image line is meant to be the only thing you change. Keep your volumes and your environment:
the entrypoint recognises the common layouts and variable names, says what it did in the first
lines of `docker logs`, and refuses to start rather than guess whenever two things could be meant.
Add `stop_grace_period: 60s` (Compose) or `--stop-timeout 60` (`docker run`) if your file does not
have it: this image saves the world on stop and needs the time.

Whichever image you come from, this image's own data directory, `/home/necesse/.config/Necesse`,
exists as well. It holds the game's `cache/` and `latest-server-log.txt` and, with Workshop mods
enabled, `ws-manifest.txt` and `ws-collection.txt`. Without a mount for it they live in an
anonymous Docker volume and are lost on a recreate, which costs nothing but the Workshop
last-known-good cache; mount `./data:/home/necesse/.config/Necesse` next to your existing volumes
if you want them kept.

### andreasgl4ser-style

Same data directory, same environment variables. Change `image:` to
`ghcr.io/stargumbo/necesse-server:2` (or `stargumbo/necesse-server:2`) and recreate the container.
From then on the join password lives in `cfg/server.cfg` (mode 0600) instead of the command line;
see Secrets. [`tests/fixtures/andreasgl4ser-style.yml`](tests/fixtures/andreasgl4ser-style.yml) is
such a compose file.

### brammys-style

Layout `/necesse/saves`, `/necesse/logs`, `/necesse/cfg` (and `/necesse/mods`); environment
`WORLD`, `PASSWORD`, `OWNER`, `SLOTS`, `MOTD`, `PAUSE`, `GIVE_CLIENTS_POWER`.

- **Keep your volumes.** Each mounted `/necesse/<name>` is linked into this image's data directory
  at start (`Using /necesse/saves for saves (legacy layout).` in the log, one line per path). The
  game reads and writes your files where they are; nothing is moved or copied. If the data
  directory already holds files under the same name the container exits instead, naming both
  locations.
- **Optionally rename the environment.** The names above are accepted as aliases, each one used
  logging one `WARN` that names the canonical variable: `WORLD` -> `WORLD_NAME`, `PASSWORD` ->
  `SERVER_PASSWORD`, `OWNER` -> `SERVER_OWNER`, `SLOTS` -> `SERVER_SLOTS`, `MOTD` -> `SERVER_MOTD`,
  `PAUSE` -> `PAUSE_WHEN_EMPTY` (`GIVE_CLIENTS_POWER` is the same name). When both are set the
  canonical one wins. `JVMARGS` -> `JAVA_OPTS` the same way. `LOGGING` and `ZIP` have no alias: use
  `ENABLE_LOGGING` and `ZIP_SAVES` (the defaults match).
- **World.** With `WORLD` unset, the single world under `saves/worlds/` is loaded and logged
  (`Loading existing world <name> (auto-detected from saves/worlds/).`); with several, set
  `WORLD_NAME`.
- **Password.** `PASSWORD` is written into `cfg/server.cfg` (0600) and no longer appears on the
  command line or in `docker logs`; see Secrets.

[`tests/fixtures/brammys-style.yml`](tests/fixtures/brammys-style.yml) is such a compose file with
only the image line changed.

### karyeet-style

Layout `/root/.config/Necesse/{saves,logs,cfg,mods}` with root-owned files; environment in
`server.cfg` key names (`world`, `slots`, `password`, `pauseWhenEmpty`, `giveClientsPower`, `owner`,
`MOTD`, ...); console through `docker attach`.

- **Keep your volumes**, as above, including `server.cfg` and `banned.cfg` mounted as **single
  files** (`./server.cfg:/root/.config/Necesse/cfg/server.cfg`): the directory holding them is
  linked in and the log says so (`... for cfg (legacy layout; server.cfg is a file mount, written in
  place).`). The join password is written into that mounted `server.cfg` in place, because a file
  mount cannot be replaced, so the file must be writable: mounted read-only, the container refuses
  to start and names the file, rather than run with a password other than the configured one.
  Mounting the directory instead (`./cfg:/root/.config/Necesse/cfg`) works as well.
- **Your password stays a password.** If the legacy `server.cfg` already carries a join password and
  no password variable is set here (`password`, `PASSWORD`, `SERVER_PASSWORD`,
  `SERVER_PASSWORD_FILE`), the container refuses to start instead of blanking the field and opening
  the server. Set `SERVER_PASSWORD` (to the same or a new password), or blank the field yourself to
  run open on purpose. This applies to every legacy layout.
- **`PUID` / `PGID`.** The server runs as an unprivileged user here, so the mounted files are
  re-owned to `PUID:PGID` (default `1000:1000`) at start. Set them to the ids the files should end
  up with.
- **Environment.** `world`, `slots`, `password`, `pauseWhenEmpty`, `giveClientsPower`, `owner`,
  `MOTD` and `JVM_OPTS` are accepted as aliases (one `WARN` each naming the canonical variable). The
  other keys (`port`, `language`, `zipSaves`, `maxClientLatencySeconds`, ...) are not read from the
  environment here: they stay in your `server.cfg`, which is used as it is.
- **Console.** Instead of `docker attach`, `docker exec necesse_server console players` types the
  command and prints the reply (see Console below).

[`tests/fixtures/karyeet-style-file-cfg.yml`](tests/fixtures/karyeet-style-file-cfg.yml) is such a
compose file with only the image line changed;
[`tests/fixtures/karyeet-style.yml`](tests/fixtures/karyeet-style.yml) is the same with `cfg`
mounted as a directory.

### Going back

Nothing is converted. World, logs, cfg and mods stay in your original directories in the game's own
format; the data directory only gained symlinks, which no other image looks at. Change the image
line back and recreate the container. One thing to know: `cfg/server.cfg` now carries the join
password in its `password` field (that is where this image keeps it), and the files this image
wrote are mode 0600.

<!-- docker-hub-overview-ends-here -->

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

The container installs [Steam Workshop](https://steamcommunity.com/app/1169040/workshop/) mods on
the server side. The recommended way (2.3.0) is a **Workshop collection**: you manage the mod list
in the Steam client, players subscribe to the collection with one click, and a container
**restart** applies changes. No `.env` edit, no recreate, no SSH. With `MODS_COLLECTION` and
`MODS_WORKSHOP` both unset or blank nothing changes: the entrypoint never calls Steam, never
touches `mods/`, and behaves exactly like 2.1.0.

```bash
docker run -d ... -e MODS_COLLECTION=3798051104 ghcr.io/stargumbo/necesse-server:2
```

1. In the Steam client (or on the website), create a collection for Necesse, add the mods, and
   make it **public**. The number in its URL is the collection id.
2. Set `MODS_COLLECTION=<that id>` once and start the container.
3. To add or remove a mod later: edit the collection, then restart the container
   (`docker restart necesse`, or the restart button in Container Manager / Portainer). The
   restart saves the world through the console `stop`, resolves the collection again, fetches
   what is new, deletes what was removed, and relaunches: about 40 s of downtime.

How it works, and what each setting does:

- **`MODS_COLLECTION`**: one public Workshop collection id. At every container start, before the
  server launches, the collection is resolved through Steam's public `GetCollectionDetails`
  endpoint (no API key, no Steam account) into the item ids it holds; the log line names the id
  and the item count. Nested collections inside it are **not** followed: each is skipped with a
  warning naming it, so add their items to your collection directly. A collection that resolves
  to **zero** items, an id that is not a public collection, or a non-numeric value is refused
  with a clear message: that is almost always a wrong id, not a wish to run unmodded. To run
  without mods, unset the variable.
- **`data/ws-collection.txt`** (mode `0600`) holds the ids from the last successful resolution.
  If Steam's Web API cannot be reached at a later start (outage, DNS, network), the entrypoint
  logs a warning with the cause and starts from that file, so the mod set, and with it the mods
  hash that players are checked against, stays exactly what it was. Only a start with no such
  file yet is governed by `MODS_FAIL_FAST`.
- **`MODS_WORKSHOP`**: the explicit alternative, a comma-separated list of Workshop item ids
  (the number in the item's URL). It can be used alone, or together with `MODS_COLLECTION`, in
  which case the union is fetched and an id present in both is fetched once. Changing it needs
  a recreate, which is why the collection is the recommended path.
- **Fetch and layout.** Each id is downloaded with an anonymous SteamCMD login
  (`workshop_download_item 1169040 <id>`) and the single `.jar` it contains is copied into
  `data/mods/` as **`ws-<id>-<OriginalName>.jar`**, mode `0600`, owned by `PUID:PGID`. The game
  loads bare jars from that directory; the Workshop's own `content/<id>/` layout is not
  loadable, and the download lands outside the bind mount, which is why the jar is copied rather
  than linked. An unchanged item is revalidated (about 6 s) and the copy is left as it is; a
  changed one replaces the copy. Expect roughly 10 s per item on a fresh container.
- **Managed vs. your own jars.** Only files named `ws-<id>-*.jar` are managed. When an id is no
  longer listed (removed from the collection or from `MODS_WORKSHOP`), its `ws-` jar is deleted
  on the next start. Jars you place in `data/mods/` yourself are never touched, listed, or
  deleted, and they load alongside the managed ones. Clearing both variables turns the feature
  off and leaves whatever is in `mods/` in place; to remove managed jars, remove the ids first
  (or delete the `ws-*.jar` files by hand while the server is stopped).
- **`MODS_FAIL_FAST`** (default `true`): if any listed item fails to download, or the collection
  cannot be resolved and there is no `ws-collection.txt` to fall back to, the container exits
  non-zero before the server starts, naming the id and the cause. A server that comes up with
  only part of its mod list has a different mods hash and refuses every player who subscribed to
  the full list, so not starting is the safer failure. Set it to `false` to log a warning and
  start with whatever fetched (a previously installed managed jar for a failed id is kept; a
  failed first resolution starts with the `MODS_WORKSHOP` ids only).
- **`data/ws-manifest.txt`** (beside `mods/`, not inside it: the game warns about every non-jar
  file in `mods/`) is rewritten after each fetch, one tab-separated line per listed id: the id,
  the jar name, the Workshop `manifest` and `timeupdated` values from SteamCMD's
  `appworkshop_1169040.acf`, and `status=ok|failed`. That is how you tell which revision of a mod
  is live. Anonymous SteamCMD always fetches the item's current revision; the copied jar is the
  only pin, so an author update is picked up on the next container start (the running server
  keeps the jar it loaded).
- **Not compatible with `LOCAL_DIR=1`.** With `-localdir` the game reads mods from `/app/mods`
  inside the image, where they would not survive a recreate; the entrypoint refuses that
  combination and exits.
- Resolution and fetch run only at container start, never while the server is running, and not
  on the `AUTO_UPDATE_INTERVAL_MINUTES` restart path. `UPDATE_ON_START` (the Steam *app* update)
  and the Workshop items are independent: either can update without touching the other.

### For players

The server cannot push mods to anyone. To join a modded server, **subscribe to the server's
collection** in the Steam Workshop for Necesse (the "Subscribe to all" button on the collection
page), then start the game so Steam downloads the mods. When the operator changes the collection,
Steam adds or removes the subscriptions for you on the next client start; if a server uses
`MODS_WORKSHOP` instead, subscribe to those item ids one by one. The mod list in the game's Mods
menu should match the server's. What to expect:

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
| `WORLD_NAME` | World to load or create. Unset: the single world under `saves/worlds/` is loaded; none there creates `world`; several make the container exit listing them (unless one is `world`, which is then loaded with a warning). |
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
| `MODS_COLLECTION` | One public Steam Workshop collection id, resolved at every start (no key, no login) into the items to install as `data/mods/ws-<id>-*.jar`; a restart applies collection edits (see Workshop mods). Blank disables; not allowed with `LOCAL_DIR=1`. |
| `MODS_WORKSHOP` | Comma-separated Steam Workshop item ids to install the same way; union with the collection. Blank disables; not allowed with `LOCAL_DIR=1`. |
| `MODS_FAIL_FAST` | `true` (default): a failed Workshop download, or a failed collection resolution with no `ws-collection.txt` to fall back to, stops the container before the server starts. `false`: warn and start with what fetched. |
| `JAVA_OPTS` | Extra JVM flags (e.g. `-Xmx2G`). The official `StartServer-nogui.sh` uses `-XX:+UseG1GC -XX:MaxGCPauseMillis=50 …`; pass them here if you want the same tuning. |
| `JAVA_BIN` | Path of the JRE to launch with (default `/app/jre/bin/java`, the JRE bundled with the Steam build). |
| `STOP_TIMEOUT_SECONDS` | How long the entrypoint waits for the server to exit after typing `stop` before falling back to `SIGTERM` (default `50`; keep it below the container's stop grace period). |
| `PUID` / `PGID` | Host UID/GID to chown the bind mount to. The entrypoint remaps the `necesse` user before launching the JVM. |
| `IMAGE_TAG` | Override image tag in Compose (default `latest`). |
| Aliases | `WORLD`, `PASSWORD`, `OWNER`, `SLOTS`, `MOTD`, `PAUSE`, `JVMARGS` and `world`, `password`, `owner`, `slots`, `pauseWhenEmpty`, `giveClientsPower`, `JVM_OPTS` fill the canonical variables above when those are unset, one `WARN` per alias used; see Coming from another image. |

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

### Console

`docker exec necesse console <command>` types a command into the running server's console and
prints the reply: `docker exec necesse console players` answers `Players online: 0/10`;
`console help` lists the server's commands. It writes to the FIFO the entrypoint holds open as the
server's stdin (`/tmp/necesse-console`; `docker exec necesse sh -c 'echo players > /tmp/necesse-console'`
keeps working) and reads the reply from the redacted copy of the server output that `redact.sh`
keeps in `/tmp/necesse-output.log` (rotated at 1 MiB), so the join password never shows up there
either. It returns after 2 s of silence or 10 s at most (`CONSOLE_QUIET_SECONDS`,
`CONSOLE_TIMEOUT_SECONDS`); with no arguments it prints usage. Run it as the container's default
user (no `-u`).

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
  3. `.github/workflows/publish.yml` builds once and pushes `ghcr.io/stargumbo/necesse-server` and
     `docker.io/stargumbo/necesse-server` with the tags listed under Tags, then syncs the Docker
     Hub overview from the top of this README. The same workflow can be dispatched manually to
     rebuild the newest tag. Docker Hub publishing needs the `DOCKERHUB_USERNAME` and
     `DOCKERHUB_TOKEN` repository secrets (a Hub access token, never a password); without them the
     workflow publishes to GHCR only and says so in its log.

---

## Reference

- [Necesse Dedicated Server wiki](https://wiki.necesse.net/wiki/Dedicated_server)
- [Necesse Multiplayer Linux guide](https://wiki.necesse.net/wiki/Multiplayer-Linux)
- [ghcr.io/stargumbo/necesse-server](https://github.com/stargumbo/necesse-server/pkgs/container/necesse-server)
  and [hub.docker.com/r/stargumbo/necesse-server](https://hub.docker.com/r/stargumbo/necesse-server) — the image
- [steamcmd/docker](https://github.com/steamcmd/docker) — the base image
- [andreas-glaser/necesse-docker-server](https://github.com/andreas-glaser/necesse-docker-server) — upstream

---

## License

Released under the [MIT License](LICENSE). The original work is copyright (c) 2025 Andreas
Christoph Glaser; this fork keeps that license and notice.
