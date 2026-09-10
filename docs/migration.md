# Coming from another image

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

## andreasgl4ser-style

Same data directory, same environment variables. Change `image:` to
`ghcr.io/stargumbo/necesse-server:2` (or `stargumbo/necesse-server:2`) and recreate the container.
From then on the join password lives in `cfg/server.cfg` (mode 0600) instead of the command line;
see [Secrets](reference.md#secrets).
[`tests/fixtures/andreasgl4ser-style.yml`](../tests/fixtures/andreasgl4ser-style.yml) is such a
compose file.

## brammys-style

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
  command line or in `docker logs`; see [Secrets](reference.md#secrets).

[`tests/fixtures/brammys-style.yml`](../tests/fixtures/brammys-style.yml) is such a compose file
with only the image line changed.

## karyeet-style

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
  command and prints the reply (see [Console](reference.md#console)).

[`tests/fixtures/karyeet-style-file-cfg.yml`](../tests/fixtures/karyeet-style-file-cfg.yml) is
such a compose file with only the image line changed;
[`tests/fixtures/karyeet-style.yml`](../tests/fixtures/karyeet-style.yml) is the same with `cfg`
mounted as a directory.

## Aliases at a glance

| Alias | Canonical variable |
| --- | --- |
| `WORLD`, `world` | `WORLD_NAME` |
| `PASSWORD`, `password` | `SERVER_PASSWORD` |
| `OWNER`, `owner` | `SERVER_OWNER` |
| `SLOTS`, `slots` | `SERVER_SLOTS` |
| `MOTD` | `SERVER_MOTD` |
| `PAUSE`, `pauseWhenEmpty` | `PAUSE_WHEN_EMPTY` |
| `giveClientsPower` | `GIVE_CLIENTS_POWER` |
| `JVMARGS`, `JVM_OPTS` | `JAVA_OPTS` |

An alias fills its canonical variable only when that one is unset, and logs one
`WARN: <alias> is accepted as an alias of <canonical> ...` line. When both are set the canonical
variable wins and a `WARN` says so. The password aliases follow the same path as
`SERVER_PASSWORD`: written to `cfg/server.cfg`, redacted from the logs, removed from the Java
environment.

## Going back

Nothing is converted. World, logs, cfg and mods stay in your original directories in the game's own
format; the data directory only gained symlinks, which no other image looks at. Change the image
line back and recreate the container. One thing to know: `cfg/server.cfg` now carries the join
password in its `password` field (that is where this image keeps it), and the files this image
wrote are mode 0600.
