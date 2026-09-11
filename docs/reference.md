# Reference

Everything the [README](../README.md) leaves out. For the mechanics behind these settings see
[Internals](internals.md); for keeping volumes and variable names from another image see
[Coming from another image](migration.md).

## Run with `docker run`

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
  ghcr.io/stargumbo/necesse-server:2
```

- Replace `changeme` with the password you want (leave blank to disable).
- The single bind mount stores saves, logs, and `cfg/server.cfg` under `./data`.
- Forward UDP port `14159` from your router/firewall to this host.
- `--stop-timeout 60` gives the server time to save when you `docker stop` it.

## Run with Docker Compose

The repository's [`docker-compose.yml`](../docker-compose.yml) lists every variable and reads them
from `.env`:

```bash
cp .env.example .env   # edit WORLD_NAME, SERVER_PASSWORD, PUID/PGID, ...
docker compose up -d
docker compose logs -f necesse
```

Never commit `.env`; it is ignored by `.gitignore`. Ship secrets through `.env` or your
orchestrator, not through the image.

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
| `X.Y` | `2.5` | newest image of that minor | every patch release and weekly rebuild within the minor |
| `X.Y.Z` | `2.5.0` | that release | the weekly rebuild, while it is the newest release (same code, refreshed base image and Steam build) |
| `latest` | `latest` | newest image | every release and weekly rebuild |
| `<game>` | `1.3.3` | newest image built for that game version | every release built for that game version; a weekly rebuild only when the game version changed |
| `<game major.minor>` | `1.3` | newest image built for that game minor | same rule as `<game>` |
| `X.Y.Z-<game>` | `2.5.0-1.3.3` | exactly one image, forever | never |

So `2` follows fixes and rebuilds without breaking changes, `1.3.3` follows the newest image that
runs that game version, and `2.5.0-1.3.3` is the fully immutable pin. The weekly rebuild
(Mondays, 05:17 UTC) exists so that the base image and the Steam server build stay current
between releases; when Steam ships a new game version, the rebuild publishes new `<game>` tags
for it and the previous `<game>` tags keep pointing at the last image built for the previous
version. Every tag is a manifest list for `linux/amd64` and `linux/arm64`; `docker pull` picks
the platform of the host (see [arm64 notes](#arm64-notes)).

## Secrets

The join password is the one real secret this image handles, and it stays on a narrow path (the
mechanics are in [Internals](internals.md#the-password-path)):

- **Two inputs.** `SERVER_PASSWORD` (plain environment variable) or `SERVER_PASSWORD_FILE` (path
  of a file whose first line is the password, e.g. a Docker secret under `/run/secrets/`). If
  both are set, **`SERVER_PASSWORD_FILE` wins**. Both unset or blank: the server starts without a
  password and prints one warning on stderr. A `SERVER_PASSWORD_FILE` that is missing, unreadable
  or empty makes the container exit non-zero instead of silently starting open.
- **Never on the command line, never in `docker logs`.** The password is written into
  `cfg/server.cfg` (mode `0600`) and the server output is redacted to `****`.
- **Appdata files are `0600`.** The game's own log files still contain the password; treat
  `latest-server-log.txt` and `logs/*.txt` as sensitive, and remember that backups of the data
  directory carry it.
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

## Workshop mods

The container installs [Steam Workshop](https://steamcommunity.com/app/1169040/workshop/) mods on
the server side. The recommended way is a **Workshop collection**: you manage the mod list in the
Steam client, players subscribe to the collection with one click, and a container **restart**
applies changes. No `.env` edit, no recreate, no SSH. With `MODS_COLLECTION` and `MODS_WORKSHOP`
both unset or blank the entrypoint never calls Steam and never touches `mods/`.

```bash
docker run -d ... -e MODS_COLLECTION=3798847765 ghcr.io/stargumbo/necesse-server:2
```

1. In the Steam client (or on the website), create a collection for Necesse, add the mods, and
   make it **public**. The number in its URL is the collection id.
2. Set `MODS_COLLECTION=<that id>` once and start the container.
3. To add or remove a mod later: edit the collection, then restart the container
   (`docker restart necesse`, or the restart button in Container Manager / Portainer). The
   restart saves the world through the console `stop`, resolves the collection again, fetches
   what is new, deletes what was removed, and relaunches: about 40 s of downtime.

The three settings:

- **`MODS_COLLECTION`**: one public Workshop collection id, resolved at every container start into
  the item ids it holds. Nested collections are not followed. A collection that resolves to zero
  items, an id that is not a public collection, or a non-numeric value is refused; to run without
  mods, unset the variable.
- **`MODS_WORKSHOP`**: the explicit alternative, a comma-separated list of Workshop item ids (the
  number in the item's URL). It can be used alone, or together with `MODS_COLLECTION`, in which
  case the union is fetched. Changing it needs a recreate, which is why the collection is the
  recommended path.
- **`MODS_FAIL_FAST`** (default `true`): a failed download, or a failed collection resolution with
  nothing cached to fall back to, stops the container before the server starts. `false` logs a
  warning and starts with what fetched.

Installed mods appear in `data/mods/` as `ws-<id>-<Name>.jar`; `data/ws-manifest.txt` says which
revision of each is live. Jars you place in `data/mods/` yourself are never touched. The full
behaviour (cache, fallback, manifest, what gets deleted when) is in
[Internals](internals.md#workshop-mods).

## Environment variables

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
| `UPDATE_ON_START` | `true` refreshes the server files from Steam (DepotDownloader, anonymous) on every start; the image already ships the build current at its own build time. |
| `AUTO_UPDATE_INTERVAL_MINUTES` | Background poll interval; the server is stopped via console `stop` (saving the world), updated, and restarted when a new Steam build is detected (a DepotDownloader manifest check; `0` disables). |
| `MODS_COLLECTION` | One public Steam Workshop collection id, resolved at every start (no key, no login) into the items to install as `data/mods/ws-<id>-*.jar`; a restart applies collection edits (see Workshop mods). Blank disables; not allowed with `LOCAL_DIR=1`. |
| `MODS_WORKSHOP` | Comma-separated Steam Workshop item ids to install the same way; union with the collection. Blank disables; not allowed with `LOCAL_DIR=1`. |
| `MODS_FAIL_FAST` | `true` (default): a failed Workshop download, or a failed collection resolution with no `ws-collection.txt` to fall back to, stops the container before the server starts. `false`: warn and start with what fetched. |
| `JAVA_OPTS` | Extra JVM flags (e.g. `-Xmx2G`). The official `StartServer-nogui.sh` uses `-XX:+UseG1GC -XX:MaxGCPauseMillis=50 …`; pass them here if you want the same tuning. |
| `JAVA_BIN` | Path of the JRE to launch with (default `/opt/java/openjdk/bin/java`, the image's Eclipse Temurin 17 JRE). |
| `STOP_TIMEOUT_SECONDS` | How long the entrypoint waits for the server to exit after typing `stop` before falling back to `SIGTERM` (default `50`; keep it below the container's stop grace period). |
| `PUID` / `PGID` | Host UID/GID to chown the bind mount to. The entrypoint remaps the `necesse` user before launching the JVM. |
| `IMAGE_TAG` | Override image tag in the repository's Compose file (default `latest`). |
| Aliases | `WORLD`, `PASSWORD`, `OWNER`, `SLOTS`, `MOTD`, `PAUSE`, `JVMARGS` and `world`, `password`, `owner`, `slots`, `pauseWhenEmpty`, `giveClientsPower`, `JVM_OPTS` fill the canonical variables above when those are unset, one `WARN` per alias used; see [Coming from another image](migration.md#aliases-at-a-glance). |

## Data, permissions and monitoring

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
`console help` lists the server's commands. It returns after 2 s of silence or 10 s at most; with
no arguments it prints usage. Run it as the container's default user (no `-u`). How it works is in
[Internals](internals.md#the-console-helper).

### Graceful stop

`docker stop` (and `docker compose stop`/`down`) makes the entrypoint type `stop` into the server
console. The server logs `Starting world save` … `Completed world save before stopping server` and
exits; the container follows with exit code 0. Give the container a real grace period
(`stop_grace_period: 60s` / `--stop-timeout 60`). Why this is needed and what happens on a
timeout is in [Internals](internals.md#graceful-stop).

## Updates and troubleshooting

- **Image updates:** every Monday the publish workflow rebuilds the newest release tag against the
  current base image and the current Steam server build and re-pushes the same tags, so
  `docker compose pull && docker compose up -d` picks up a fresh image without a new release.
- **In-container updates:** `UPDATE_ON_START=true` refreshes the server files from Steam with
  DepotDownloader at each start. `AUTO_UPDATE_INTERVAL_MINUTES` (e.g. `60`) enables polling; when
  Steam publishes a new build the server is stopped via console `stop`, updated, and restarted
  inside the same container.
- **Download errors:** the container keeps the previous server build if DepotDownloader fails
  (`DepotDownloader did not complete the download ...`); its own output is in `docker logs` just
  above that line.
- **Players cannot join:** confirm UDP port forwarding and public IP. Some port testers give false
  negatives; validate in-game if unsure.
- **Config changes ignored:** edit `.env`, then `docker compose up -d` to recreate with new flags.
  Necesse rewrites `server.cfg` on a clean shutdown, so do not hand-edit it while the server runs;
  the environment variables are reapplied on every start.
- **`Java runtime not found at ...`:** `JAVA_BIN` points at a path that does not exist in this image
  (`/app/jre/bin/java` was the default up to 2.4.0). Unset it; the image's JRE is
  `/opt/java/openjdk/bin/java`.
- **Container exits with `Workshop mods: item(s) ... could not be fetched`:** the id is wrong, the
  item was removed or hidden, or Steam was unreachable. Check the id in the Workshop URL; the line
  just above names the reason (`Unable to locate manifest ID for published file <id>` for a bad
  id). Set `MODS_FAIL_FAST=false` only if you accept starting with a partial mod set.
- **Container exits with `... is not a public Steam Workshop collection`:** the collection is
  private or the id is wrong. Set it to public in Steam, or check the number in its URL.
- **Players get "wrong mods":** compare `data/ws-manifest.txt` with what they have subscribed;
  every non-clientside mod must be present on both sides at the same version.

## arm64 notes

The image is published for `linux/amd64` and `linux/arm64` under the same tags; `docker pull`
picks the platform of the host. A Raspberry Pi 5, an Ampere or Graviton VM and Docker Desktop on
Apple Silicon all run the arm64 image natively. Nothing in this document is architecture-specific:
same variables, same data layout, same console, same stop path, same Workshop handling; the game
files are the same bytes on both, fetched by DepotDownloader running natively on either. The one
visible difference is performance, which is the hardware's.

Testing the arm64 image **under emulation** (`docker run --platform linux/arm64` on an x86 host,
which runs it under qemu-user) has one known artifact: the server boots, loads worlds and accepts
players, but after the console `stop` the world save completes and the process then fails to close
its UDP socket (`Error in server ticking: ... IOException: Invalid argument` from
`NativeThread.signal`) and never exits on its own. The entrypoint's `STOP_TIMEOUT_SECONDS` fallback
sends `SIGTERM`, so `docker stop` still returns within the grace period and the world is saved, but
the exit code is not 0. This does not happen on arm64 hardware: `.github/workflows/arm64.yml` runs
the console stop on GitHub's `ubuntu-24.04-arm` runners on every pull request and it exits 0 within
seconds. Do not run stop or socket-close checks under QEMU, and do not work around it in the image.

## Clone, develop, contribute

```bash
git clone https://github.com/stargumbo/necesse-server.git
cd necesse-server
cp .env.example .env
docker build -t necesse-server:dev .
docker compose up -d
```

- CI (`.github/workflows/ci.yml`) runs shellcheck, a full image build, `tests/run-platform.sh`
  against it and the two-platform buildx build the publish workflow uses, on pushes to `main` and
  on pull requests. `.github/workflows/arm64.yml` builds the image natively on an arm64 runner and
  runs the same `tests/run-platform.sh` there.
- `tests/run-platform.sh` is the architecture-independent suite (image contents, boot, world load,
  console, password path, healthcheck, `UPDATE_ON_START`, the auto-update restart, Workshop mods,
  console stop). `tests/run-fixtures.sh` exercises the compose files under `tests/fixtures/`
  (aliases, legacy mounts, the password guard, world auto-detect, the console helper, the log diff
  against the previous release); it needs an amd64 baseline image.
- DepotDownloader is pinned in the `Dockerfile` (`DD_VERSION`, `DD_SHA256_AMD64`, `DD_SHA256_ARM64`);
  bumping it means changing the three values together. Dependabot does not track it.
- Release process:
  1. Update [`CHANGELOG.md`](../CHANGELOG.md) and documentation.
  2. `git tag -a vX.Y.Z -m "vX.Y.Z"` and `git push --follow-tags`.
  3. `.github/workflows/publish.yml` builds once and pushes `ghcr.io/stargumbo/necesse-server` and
     `docker.io/stargumbo/necesse-server` with the tags listed under Tags. The same workflow can be
     dispatched manually to rebuild the newest tag. Docker Hub publishing needs the
     `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` repository secrets (a Hub access token, never a
     password); without them the workflow publishes to GHCR only and says so in its log.
- The Docker Hub overview is independent of releases: `.github/workflows/hub-readme.yml` syncs it
  from `README.md` on `main` whenever the README changes (see
  [Docker Hub overview](DOCKER_HUB_OVERVIEW.md)); it uses the same two secrets.

## Links

- [Necesse Dedicated Server wiki](https://wiki.necesse.net/wiki/Dedicated_server)
- [Necesse Multiplayer Linux guide](https://wiki.necesse.net/wiki/Multiplayer-Linux)
- [ghcr.io/stargumbo/necesse-server](https://github.com/stargumbo/necesse-server/pkgs/container/necesse-server)
  and [hub.docker.com/r/stargumbo/necesse-server](https://hub.docker.com/r/stargumbo/necesse-server), the image
- [eclipse-temurin](https://hub.docker.com/_/eclipse-temurin), the base image
- [SteamRE/DepotDownloader](https://github.com/SteamRE/DepotDownloader), fetches the game files
  (GPL-2.0; see [NOTICE](../NOTICE))
- [andreas-glaser/necesse-docker-server](https://github.com/andreas-glaser/necesse-docker-server), upstream

## License

Released under the [MIT License](../LICENSE). The original work is copyright (c) 2025 Andreas
Christoph Glaser; this fork keeps that license and notice.
