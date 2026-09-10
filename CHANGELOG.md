# Changelog

All notable changes to this project are documented here. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/) and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [2.3.0] - 2026-09-09

Mod changes no longer need a `.env` edit or a container recreate. A Steam Workshop **collection**
is now the recommended source of the mod list: edit it in the Steam client, restart the
container, done; players subscribe to the collection with one click. `MODS_WORKSHOP` stays as
the explicit-list alternative. With both unset the image behaves exactly as 2.2.0.

### Added
- `MODS_COLLECTION`: one public Workshop collection id. At container start, before the 2.2.0
  fetch, the collection is resolved through Steam's public `ISteamRemoteStorage/GetCollectionDetails`
  endpoint (POST, no API key, no login) into its file items; the log names the id and the item
  count. The ids are handed to the unchanged 2.2.0 fetch/manage/manifest path, so the `ws-<id>-`
  jar layout, revalidation, prefix-only deletion and `ws-manifest.txt` are as before. When
  `MODS_WORKSHOP` is also set the union is fetched; an id in both is fetched once
  (`entrypoint.sh`).
- `<data>/ws-collection.txt` (`0600`): the ids from the last successful resolution. If the Web API
  cannot be reached on a later start, the entrypoint warns with the cause and starts from this
  file, so the mods hash players are checked against does not change. A resolution failure with
  no such file yet is governed by `MODS_FAIL_FAST`: `true` exits non-zero naming the collection
  and the cause, `false` warns and starts with the `MODS_WORKSHOP` ids only.
- Refusals with a clear message: a non-numeric `MODS_COLLECTION`, an id that is not a public
  collection, or a collection with zero file items (a wrong id, not a wish to run unmodded).
  Nested collections are not followed: each is skipped with a warning naming it.
- `MODS_COLLECTION` in `.env.example`, `docker-compose.yml` and the image `ENV` defaults. README
  "Workshop mods" section rewritten around the collection workflow; "For players" now says to
  subscribe to the collection.

### Changed
- The managed-jar removal log line reads "is no longer listed" instead of naming
  `MODS_WORKSHOP`, since an id can now also drop out of the collection.
- `LOCAL_DIR=1` is refused when either `MODS_COLLECTION` or `MODS_WORKSHOP` is set (2.2.0
  refused it for `MODS_WORKSHOP` only).
- The image now installs `curl` (about 12 MB of rootfs) to make the Web API request; the
  `steamcmd` base ships no HTTP client.

## [2.2.0] - 2026-09-09

Steam Workshop mods can now be installed by the container itself. With `MODS_WORKSHOP` unset the
image behaves exactly as 2.1.0: no SteamCMD Workshop call, no writes to `mods/`, no new log lines.

### Added
- `MODS_WORKSHOP`: comma-separated Workshop item ids. At container start, before the server
  launches, each id is fetched with an anonymous SteamCMD login (`workshop_download_item 1169040`)
  and its single jar is copied flat into `<data>/mods/` as `ws-<id>-<OriginalName>.jar` (`0600`,
  `PUID:PGID`). The game only loads bare jars from that directory and SteamCMD's download lands
  outside the bind mount, hence the copy. An unchanged item is revalidated and the existing copy is
  left untouched (`entrypoint.sh`).
- Managed-jar semantics: only `ws-<id>-*.jar` files are managed. On each start, managed jars whose
  id is no longer listed are deleted; that is the only deletion the entrypoint performs. Jars the
  operator places in `mods/` are never touched. Clearing `MODS_WORKSHOP` turns the feature off and
  leaves `mods/` as it is.
- `MODS_FAIL_FAST` (default `true`): a failed download exits the container non-zero before the
  server starts, naming the id, because a partial mod set changes the mods hash and locks every
  subscribed player out. `false` logs a warning and starts with what fetched.
- `<data>/ws-manifest.txt` (beside `mods/`, since the game warns about non-jar files inside it),
  rewritten after each fetch: one line per listed id with the jar
  name, the Workshop `manifest` and `timeupdated` values, and `status=ok|failed`, so the operator
  can see which Workshop revision is live.
- `MODS_WORKSHOP` together with `LOCAL_DIR=1` is refused with a clear message: with `-localdir` the
  game reads mods from `/app/mods` inside the image, where managed jars would not persist.
- README "Workshop mods" section with a "For players" subsection (players must subscribe to the
  same ids themselves; the server cannot push mods; "Use server mods" cannot download;
  `clientside=true` mods do not need to match; older-`gameVersion` mods load without warning;
  same-id different-version joins are untested). `MODS_WORKSHOP` and `MODS_FAIL_FAST` in
  `.env.example`, `docker-compose.yml` and the image `ENV` defaults.

## [2.1.0] - 2026-09-07

The join password no longer leaves the secret path. Four exposure surfaces from 2.0.x are closed
(`entrypoint.sh`, `redact.sh`, `Dockerfile`); the runtime contract is otherwise unchanged and an
existing `.env` deployment needs no edits.

### Changed
- The password is written into the `password` field of the game's `cfg/server.cfg` (mode `0600`)
  before every start instead of being passed as `-password` on the Java command line, so it no
  longer appears in `docker top`, `ps`, or the game's "Launched game with arguments" log line. On a
  first start the file is seeded with the game's own defaults so the loader finds every key.
- The entrypoint no longer echoes the password in its "Starting Necesse server with command" line
  (there is nothing to echo any more), and drops `SERVER_PASSWORD`/`SERVER_PASSWORD_FILE` from the
  Java process environment.
- The server's stdout/stderr are piped through `redact.sh`, a fixed-string (non-regex), line-buffered
  filter that replaces the password with `****`, so `docker logs` never shows it. The console FIFO
  used for the graceful `stop` is untouched.
- The server runs with `umask 077`: its log files, saves and cfg are created `0600`. The game still
  writes the password into its own log files under the data directory; they are now owner-only.

### Added
- `SERVER_PASSWORD_FILE`: read the password from a file (first line), e.g. a Docker secret. Takes
  precedence over `SERVER_PASSWORD`. Missing, unreadable or empty file: the container exits non-zero
  with a clear message rather than starting without a password.
- README "Secrets" section; a commented `secrets:` example in `docker-compose.yml`;
  `SERVER_PASSWORD_FILE` in `.env.example`.
- Both `SERVER_PASSWORD` and `SERVER_PASSWORD_FILE` unset or blank now prints one stderr warning
  (the server still starts open, as before). A password containing a comma or `//` is refused
  because it cannot be stored in `server.cfg`.

## [2.0.1] - 2026-09-07

### Fixed
- The image `HEALTHCHECK` was shell-form, so `pgrep -f 'Server.jar'` ran inside `sh -c "..."` whose own argv contains `Server.jar`; pgrep matched that wrapper shell, the container reported healthy from the first check (while SteamCMD was still installing) and could never become unhealthy. The check is now exec-form (`["pgrep", "-f", "Server.jar"]`), so there is no wrapper to self-match and health follows the real `Server.jar` process (`Dockerfile`). Found on the 2.0.0 deploy.

## [2.0.0] - 2026-09-07

First release of the `stargumbo/necesse-server` fork, published as `ghcr.io/stargumbo/necesse-server`. The fork keeps upstream's tags (v0.1.0–v1.3.3), so its own versioning starts above them at 2.0.0; the upstream history below is unchanged.

### Changed
- Image is now based on `ghcr.io/steamcmd/steamcmd:debian-13` (official SteamCMD image) instead of `debian:bullseye-slim` with a hand-installed SteamCMD (`Dockerfile`).
- `Server.jar` runs under the JRE bundled with the Steam build (`/app/jre/bin/java`); the distro `openjdk-17-jre-headless` layer is gone. `JAVA_BIN` overrides the path (`entrypoint.sh`).
- SteamCMD state for the `necesse` user is baked at build time (warm-up, sdk32/sdk64 links, retried `app_update`), so runtime updates start from a working client (`Dockerfile`).
- Auto-update restarts now stop the server via the console `stop` command instead of `pkill`, so the world is saved before the new build is applied (`entrypoint.sh`).
- Publishing moved from Docker Hub to GHCR: tag pushes build `:X.Y.Z`, `:X.Y`, `:X`, `:latest`; a Monday cron and manual dispatch rebuild the newest tag with `pull: true`; GitHub Actions pinned by commit SHA (`.github/workflows/publish.yml`, replaces `release.yml`).
- Compose example targets the GHCR image and sets `stop_grace_period: 60s` (`docker-compose.yml`, `README.md`).
- `SERVER_PASSWORD` no longer has an image-level default; pass it at run time (`Dockerfile`).

### Added
- Graceful stop: the server's stdin is a FIFO held open by the entrypoint; the `TERM` trap types `stop` into the console and waits up to `STOP_TIMEOUT_SECONDS` (default 50) for the JVM to exit before falling back to `SIGTERM`. Verified: a plain `SIGTERM` does not save the world; the console `stop` does (`entrypoint.sh`).
- Dependabot for the `docker` and `github-actions` ecosystems, weekly (`.github/dependabot.yml`).
- OCI `licenses` label; `source`/`url` labels point at the fork.

### Removed
- `release.yml` (GitHub release archives + Docker Hub push); superseded by `publish.yml`.


## [1.3.3] - 2025-11-07
### Fixed
- Auto-update watcher now reads SteamCMD manifests from the install directory, preventing hourly restarts when no new Necesse build is available (`entrypoint.sh`).

## [1.3.2] - 2025-10-28
### Fixed
- Container now falls back to the previous server build when SteamCMD fails (e.g. `state is 0x6`) instead of restarting in a loop, and logs where to inspect the failure (`entrypoint.sh`).

## [1.3.1] - 2025-10-27
### Added
- Image-level healthcheck matching the Compose probe so `docker run` users get liveness status (`Dockerfile`).
### Changed
- Compose service now relies on the baked-in healthcheck and enforces memory limits with `mem_limit`/`mem_reservation` so limits work outside Swarm (`docker-compose.yml`).
- README Compose example mirrors the actual service definition, listing explicit environment variables instead of `env_file` (`README.md`).
- Docker Hub overview now matches the Compose configuration and documents the built-in healthcheck and memory hints (`docs/DOCKER_HUB_OVERVIEW.md`, `docs/index.md`).

## [1.3.0] - 2025-10-24
### Added
- README badges for CI status, latest release, Docker pulls, and image size.
- Necesse trailer GIF below the badges.
### Changed
- README examples now default to the `latest` image tag and reference the bundled `docker-compose.yml` / `.env.example`.

## [1.2.0] - 2025-10-23
### Added
- Contributor documentation under `docs/` (Git workflow, commit, and release guides plus index).

## [1.1.0] - 2025-10-22
### Added
- GitHub Actions publishes Docker images to Docker Hub (`andreasgl4ser/necesse-server`) on tagged releases.
### Changed
- `docker-compose.yml` now defaults to the published Docker Hub image and accepts an optional `IMAGE_TAG`.
- README refocused on Docker Hub workflows with updated quickstart examples.

## [1.0.0] - 2025-10-22
### Added
- Automatic update watcher controlled by `AUTO_UPDATE_INTERVAL_MINUTES` that checks Steam for new builds and restarts the server.
### Changed
- Reworked README for server admins with clearer quickstart, management guidance, and streamlined feature notes.
- Auto-update now logs when periodic checks are enabled so admins know the cadence.

## [0.1.0] - 2025-10-19
### Added
- Debian-based Docker image that installs Necesse via SteamCMD and exposes configurable server flags.
- Compose file with health check, persistent data volume, and environment-driven configuration.
- Hardened entrypoint with optional auto-update, UID/GID remapping, and safe argument construction.
- Documentation and sample `.env` covering setup, updates, and troubleshooting.
- GitHub Actions CI workflow running shellcheck and docker build.
