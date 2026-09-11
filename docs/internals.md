# Internals

How the image does what the [README](../README.md) promises. Nothing here is needed to run a
server; it is for the curious and for anyone debugging one.

## What is inside the image

- **Base image `eclipse-temurin:17-jre-noble`** (Ubuntu 24.04 with the Temurin 17 JRE), itself a
  manifest list, so one Dockerfile builds `linux/amd64` and `linux/arm64`. `Server.jar` runs under
  that JRE (`/opt/java/openjdk/bin/java`; `JAVA_BIN` overrides the path). The only package added on
  top is `gosu`.
- **Game files from Steam through DepotDownloader.** The Necesse server (app `1169370`) is fetched
  at build time with Steam's anonymous dedicated-server access, natively on the platform doing the
  build, and the result is shared by both architectures: Steam's Linux build carries an x86-64 JRE
  (`jre/`) and x86-64 Steamworks natives (`linux64/`), and neither is downloaded, on either
  architecture (filelist `regex:^(?!jre/|linux64/).*$`). The server then logs `Natives path:
  INTERNAL` and loads its natives from `Server.jar`, which is how the developer's own Linux server
  zip runs. Everything else under `/app` is byte for byte what SteamCMD installed before 2.5.0.
  `UPDATE_ON_START=true` runs the same fetch at every start (`-validate` re-checks the files in
  place). DepotDownloader (GPL-2.0) is an unmodified official release binary, fetched by pinned
  version and sha256 in the Dockerfile and kept in the image at `/opt/depotdownloader/`; see
  [NOTICE](../NOTICE). It runs as the `necesse` user, keeps per-directory state in
  `<dir>/.DepotDownloader/` and its (anonymous) account settings under
  `/home/necesse/.local/share/IsolatedStorage`, none of it inside the bind mount.
- **Update detection.** `/app/.necesse-manifests` records the depot manifests installed in `/app`
  (written by the build and after every successful download). The auto-update monitor runs a
  DepotDownloader `-manifest-only` check into a scratch directory (manifests only, no game files)
  and compares; a difference is logged as `Auto-update: new build detected (local ..., remote ...)`,
  after which the server is stopped through the console (saving the world), refetched and
  relaunched.
- **One build, two platforms, two registries.** Every release is built for both platforms from one
  amd64 runner (the fetch stages run natively; only the arm64 runtime stage's `apt-get` runs under
  QEMU) and pushed to GHCR and Docker Hub as manifest lists, so a tag has the same digest on both.
  The publish workflow verifies that every tag covers both platforms and that the digests agree, and
  stops before any further tagging otherwise. All GitHub Actions are pinned by commit SHA; Dependabot
  tracks the actions and the base image (the DepotDownloader version is a Dockerfile `ARG`, bumped by
  hand together with its checksums).
- **Health check:** exec-form `pgrep -f Server.jar`, interval 30 s, start period 30 s, 3 retries.
  The container is unhealthy while DepotDownloader and the Workshop fetch run and healthy after
  `Started server`.

## Graceful stop

The server does not save on `SIGTERM`; it saves on the console `stop` command. The entrypoint
holds the server's stdin open on a FIFO (`/tmp/necesse-console`) and, from its `TERM` trap, types
`stop` into it, then waits up to `STOP_TIMEOUT_SECONDS` (default `50`) for the JVM to exit before
falling back to `SIGTERM`. The server logs `Starting world save` ... `Completed world save before
stopping server` and exits; the container follows with exit code 0. The same path runs before an
auto-update restart.

This is why the container must be given a real grace period (`stop_grace_period: 60s` in Compose,
`--stop-timeout 60` with `docker run`). With Docker's default 10-second grace the save still
usually completes on a small world, but do not rely on it. The server also autosaves on its own
schedule (with `LATEST_BACKUP*.zip` copies), so an unclean stop loses at most the interval since
the last autosave.

## The password path

The join password is the one real secret this image handles, and it stays on a narrow path:

- Resolved once at start from `SERVER_PASSWORD_FILE` (first line of the file) or, failing that,
  `SERVER_PASSWORD`. Both blank: the server starts open and prints one warning on stderr. A
  `SERVER_PASSWORD_FILE` that is missing, unreadable or empty makes the container exit non-zero
  instead of silently starting open.
- Written into the `password` field of the game's `cfg/server.cfg` (mode `0600`) before each
  start. `-password` is never passed on the command line, so `docker top`, `ps` and the game's own
  "Launched game with arguments" line never carry it. It is also removed from the Java process
  environment, as are the `PASSWORD` and `password` aliases.
- The game prints the password on start (`Started server ... with password "..."`). Its stdout
  and stderr pass through `redact.sh`, a fixed-string filter, so `docker logs` shows `****`
  instead. Any character is fine; the filter is not a regex. A comma or `//` in the password would
  break the `server.cfg` syntax, so the entrypoint refuses to start with either.
- The server runs with `umask 077`, so its log files, saves and cfg are created readable by the
  owner only. The game's own log files (`latest-server-log.txt`, `logs/*.txt`) do contain the
  password, unredacted, and that cannot be filtered, only permission-narrowed: treat them as
  sensitive, and remember that anything that copies the data directory copies the password with
  it.

## The console helper

`docker exec necesse console <command>` writes the command to the console FIFO and prints the
reply. It reads the reply from the redacted copy of the server output that `redact.sh` keeps in
`/tmp/necesse-output.log` (rotated at 1 MiB, one previous file), so the join password never shows
up there either. It returns after 2 s of silence or 10 s at most (`CONSOLE_QUIET_SECONDS`,
`CONSOLE_TIMEOUT_SECONDS`). `docker exec necesse sh -c 'echo players > /tmp/necesse-console'`
keeps working as the raw form.

## Workshop mods

Resolution and fetch run at container start, before the server launches, and never while the
server is running; the `AUTO_UPDATE_INTERVAL_MINUTES` restart path does not re-resolve or refetch.
`UPDATE_ON_START` (the Steam *app* update) and the Workshop items are independent: either can
update without touching the other. With `MODS_COLLECTION` and `MODS_WORKSHOP` both unset or blank
nothing happens: no Steam call, `mods/` untouched, no new log lines.

- **Collection resolution.** `MODS_COLLECTION` is resolved through Steam's public
  `GetCollectionDetails` endpoint (no API key, no Steam account) into the item ids it holds; the
  log line names the id and the item count (`Workshop collection: <id> resolved to N item(s): ...`).
  Only Workshop file items are taken; nested collections are **not** followed, each is skipped with
  a warning naming it, so add their items to your collection directly. A collection that resolves
  to **zero** items, an id that is not a public collection, or a non-numeric value is refused with a
  clear message: that is almost always a wrong id, not a wish to run unmodded. Workshop items live
  under the *client* app id `1169040`, not the server's `1169370`.
- **Last-known-good cache.** `data/ws-collection.txt` (mode `0600`) holds the ids from the last
  successful resolution. If Steam's Web API cannot be reached at a later start (outage, DNS,
  network), the entrypoint logs a warning with the cause and starts from that file, so the mod set,
  and with it the mods hash that players are checked against, stays exactly what it was. Only a
  start with no such file yet is governed by `MODS_FAIL_FAST`. Definite negative answers (a
  non-numeric id, an API result other than success, a collection with zero file items) are refused
  even when a cache exists.
- **Fetch and layout.** Each id is downloaded anonymously with DepotDownloader
  (`-app 1169040 -pubfile <id>`) into a fresh directory of its own outside the bind mount.
  DepotDownloader exits 0 even when the item does not exist, so success is the `Total downloaded:`
  line it prints after a completed download; on failure the last line of its output is the reason
  (`Unable to locate manifest ID for published file <id>` for a bad id). The single `.jar` the item
  contains is copied into `data/mods/` as **`ws-<id>-<OriginalName>.jar`**, mode `0600`, owned by
  `PUID:PGID`. The game loads bare jars from that directory, and the download lands outside the bind
  mount, which is why the jar is copied rather than linked. An unchanged item is fetched again (a few
  seconds; mods are small) and the copy is left as it is when identical; a changed one replaces the
  copy.
- **Managed vs. your own jars.** Only files named `ws-<id>-*.jar` are managed. When an id is no
  longer listed (removed from the collection or from `MODS_WORKSHOP`), its `ws-` jar is deleted on
  the next start (`removing <jar> (item <id> is no longer listed)`), the only deletion the
  entrypoint performs. Jars you place in `data/mods/` yourself are never touched, listed, or
  deleted, and they load alongside the managed ones. Clearing both variables turns the feature off
  and leaves whatever is in `mods/` in place; to remove managed jars, remove the ids first (or
  delete the `ws-*.jar` files by hand while the server is stopped).
- **`MODS_FAIL_FAST`** (default `true`): if any listed item fails to download, or the collection
  cannot be resolved and there is no `ws-collection.txt` to fall back to, the container exits
  non-zero before the server starts, naming the id and the cause. A server that comes up with only
  part of its mod list has a different mods hash and refuses every player who subscribed to the
  full list, so not starting is the safer failure. `false` logs a warning and starts with whatever
  fetched (a previously installed managed jar for a failed id is kept; a failed first resolution
  starts with the `MODS_WORKSHOP` ids only).
- **`data/ws-manifest.txt`** (beside `mods/`, not inside it: the game warns about every non-jar
  file in `mods/`) is rewritten after each fetch, one tab-separated line per listed id: the id, the
  jar name, the item's Workshop `manifest` and `timeupdated` values, and `status=ok|failed`. That is
  how you tell which revision of a mod is live. The two values come from Steam's public
  `GetPublishedFileDetails` endpoint (`hcontent_file` and `time_updated`; one request for all listed
  ids, no key, no login); if that request fails the fetch still runs and both read `-`. The
  anonymous fetch always takes the item's current revision; the copied jar is the only pin, so an
  author update is picked up on the next container start (the running server keeps the jar it
  loaded).
- **Not compatible with `LOCAL_DIR=1`.** With `-localdir` the game reads mods from `/app/mods`
  inside the image, where they would not survive a recreate; the entrypoint refuses that
  combination and exits.

## The join gate

The client's connect request carries a hash of its enabled mods (ids and versions, client-side
mods excluded), and the server compares it with its own. A mismatch is logged as
`Auth <steamid> ... connected with wrong mods` and the client sees the mods mismatch dialog. A
mod installed as a file on the server matches the same mod subscribed through the Workshop on the
client. The dedicated server loads mods flagged for an older game version without any warning; the
client shows "Wrong game version" in red for such a mod but still loads it, and the join works.
Joining with the same mod id at a different version than the server is untested: keep the same
items subscribed and let Steam update them; the server picks up author updates on its next
restart.
