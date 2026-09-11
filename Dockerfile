# Necesse Dedicated Server for linux/amd64 and linux/arm64: Eclipse Temurin 17 JRE base, game files fetched
# from Steam by DepotDownloader (anonymous dedicated-server subscription), one Dockerfile for both.
#
# Stages
#   depotdownloader  The official DepotDownloader release for the TARGET platform, downloaded and sha256-
#                    verified natively on the build platform (curl and unzip need no emulation) and copied
#                    into the runtime image: UPDATE_ON_START, AUTO_UPDATE_INTERVAL_MINUTES and the Workshop
#                    mods all fetch through it at run time.
#   game             The current Steam build of the server (app 1169370), fetched natively on the BUILD
#                    platform with the DepotDownloader for that platform. Steam's x86-64 JRE (jre/) and its
#                    x86-64 Steamworks natives (linux64/) are left out on both architectures: the server
#                    runs under the base image's JRE and loads its natives from Server.jar ("Natives path:
#                    INTERNAL"), which is how the developer's own Linux server zip runs as well. What is
#                    left is architecture-independent, so this stage is built once and shared.
#   (runtime)        eclipse-temurin:17-jre-noble for the target platform, plus gosu, the two stages above,
#                    the entrypoint and the console helper.
#
# DepotDownloader (https://github.com/SteamRE/DepotDownloader) is GPL-2.0 and is used exactly as released:
# fetched by the version and sha256 pinned here, never built from source, patched or vendored. See NOTICE.

ARG DD_VERSION=3.4.0
ARG DD_RELEASE_URL=https://github.com/SteamRE/DepotDownloader/releases/download/DepotDownloader_${DD_VERSION}
# sha256 of DepotDownloader-linux-x64.zip and DepotDownloader-linux-arm64.zip from that release.
ARG DD_SHA256_AMD64=a999dec66b4850fc961bd50366696d23c2d0fad7b18790e6a5647b2f19097a53
ARG DD_SHA256_ARM64=d9fb612ccebc1db8eeea3b4045d2221ec70431381393ce908fb72f01d4f9c812

# ---------------------------------------------------------------------------------------------------------
FROM --platform=$BUILDPLATFORM eclipse-temurin:17-jre-noble AS depotdownloader
ARG TARGETARCH
ARG DD_VERSION DD_RELEASE_URL DD_SHA256_AMD64 DD_SHA256_ARM64
RUN apt-get update && apt-get install -y --no-install-recommends unzip && rm -rf /var/lib/apt/lists/*
COPY --chmod=755 scripts/fetch-depotdownloader.sh /usr/local/bin/fetch-depotdownloader
RUN fetch-depotdownloader "${TARGETARCH}" /opt/depotdownloader

# ---------------------------------------------------------------------------------------------------------
FROM --platform=$BUILDPLATFORM eclipse-temurin:17-jre-noble AS game
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ARG BUILDARCH
ARG DD_VERSION DD_RELEASE_URL DD_SHA256_AMD64 DD_SHA256_ARM64
RUN apt-get update && apt-get install -y --no-install-recommends unzip && rm -rf /var/lib/apt/lists/*
COPY --chmod=755 scripts/fetch-depotdownloader.sh /usr/local/bin/fetch-depotdownloader
RUN fetch-depotdownloader "${BUILDARCH}" /dd

# STEAM_REFRESH is part of the cache key of the RUN below (an ARG declared before a RUN is), so the weekly
# rebuild, which passes a fresh value, downloads the current Steam build even when nothing else changed.
ARG STEAM_REFRESH=
# The filelist is the one entrypoint.sh writes for UPDATE_ON_START: everything except jre/ and linux64/.
# DepotDownloader still creates a directory for every path in the manifest, hence the empty-directory
# cleanup; a file under either directory means the filelist stopped matching, and the build fails.
# .necesse-manifests records the depot manifests this download installed, in the format entrypoint.sh's
# manifests_from_log produces, so the auto-update check has a baseline from the very first start.
RUN printf 'regex:^(?!jre/|linux64/).*$\n' > /tmp/filelist \
 && /dd/DepotDownloader -app 1169370 -os linux -osarch 64 -dir /app -filelist /tmp/filelist 2>&1 | tee /tmp/depotdownloader.log \
 && grep -q '^Total downloaded: ' /tmp/depotdownloader.log \
 && test -f /app/Server.jar \
 && sed -n -e 's/^Got manifest request code for depot \([0-9]*\) from app [0-9]*, manifest \([0-9]*\),.*/\1 \2/p' \
           -e 's/^Already have manifest \([0-9]*\) for depot \([0-9]*\)\..*/\2 \1/p' /tmp/depotdownloader.log \
    | sort -u > /app/.necesse-manifests \
 && test -s /app/.necesse-manifests \
 && if [ -n "$(find /app/jre /app/linux64 -type f 2>/dev/null | head -n 1)" ]; then \
        echo "the filelist did not exclude jre/ or linux64/" >&2; exit 1; fi \
 && rm -rf /app/jre /app/linux64 \
 && sha256sum /app/Server.jar && cat /app/.necesse-manifests && du -sh /app

# ---------------------------------------------------------------------------------------------------------
FROM eclipse-temurin:17-jre-noble

ARG BUILD_VERSION=dev
ARG BUILD_REVISION=unknown
ARG uid=1000
ARG gid=1000

# gosu drops privileges in the entrypoint. Everything else the entrypoint and the healthcheck use (bash,
# pgrep, curl for the Steam Web API, ca-certificates) is already in the base image. Ubuntu 24.04 ships an
# `ubuntu` account with uid/gid 1000; it goes, so that necesse can have the ids it has had since 2.0.0.
RUN apt-get update && apt-get install -y --no-install-recommends gosu \
 && rm -rf /var/lib/apt/lists/* \
 && if getent passwd ubuntu >/dev/null; then userdel -r ubuntu; fi \
 && if getent group ubuntu >/dev/null; then groupdel ubuntu; fi \
 && groupadd -g ${gid} necesse && useradd -u ${uid} -g necesse -s /bin/bash -m necesse \
 && mkdir -p /home/necesse/.config/Necesse /home/necesse/.local/share \
 && chown -R necesse:necesse /home/necesse

# DepotDownloader for this platform (binary, LICENSE, RELEASE.txt) and the game files.
COPY --from=depotdownloader /opt/depotdownloader /opt/depotdownloader
COPY --from=game --chown=necesse:necesse /app /app
COPY --chown=necesse:necesse --chmod=755 entrypoint.sh redact.sh /app/
# `docker exec <container> console players`: types a command into the server console and prints the reply.
COPY --chmod=755 console.sh /usr/local/bin/console
COPY NOTICE /usr/share/doc/necesse-server/NOTICE
WORKDIR /app

# The DepotDownloader binary for this platform runs here (under emulation in a cross build, which is enough
# for -V), and the game tree is what the game stage promised.
RUN /opt/depotdownloader/DepotDownloader -V \
 && test -f /app/Server.jar && test -s /app/.necesse-manifests \
 && test ! -e /app/jre && test ! -e /app/linux64

LABEL org.opencontainers.image.title="Necesse Dedicated Server" \
      org.opencontainers.image.description="Necesse dedicated server for linux/amd64 and linux/arm64: Server.jar under the Eclipse Temurin 17 JRE, game files fetched from Steam by DepotDownloader (anonymous). Fork of andreas-glaser/necesse-docker-server." \
      org.opencontainers.image.source="https://github.com/stargumbo/necesse-server" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${BUILD_VERSION}" \
      org.opencontainers.image.revision="${BUILD_REVISION}"

# Runtime identity and server defaults (all overridable at run time; see README). SERVER_PASSWORD is
# deliberately not defaulted here: pass it at run time only. WORLD_NAME, SERVER_SLOTS, PAUSE_WHEN_EMPTY
# and GIVE_CLIENTS_POWER are defaulted by the entrypoint instead (world / 10 / 0 / 0) after the 2.4.0
# environment aliases are applied, so that an alias such as SLOTS or pauseWhenEmpty can fill them.
ENV CONTAINER_USER=necesse CONTAINER_GROUP=necesse CONTAINER_UID=${uid} CONTAINER_GID=${gid} \
    WORLD_NAME= SERVER_PORT=14159 SERVER_SLOTS= SERVER_OWNER= SERVER_MOTD= \
    PAUSE_WHEN_EMPTY= GIVE_CLIENTS_POWER= ENABLE_LOGGING=1 ZIP_SAVES=1 SERVER_LANGUAGE=en \
    SETTINGS_FILE= BIND_IP= MAX_CLIENT_LATENCY= LOCAL_DIR=0 DATA_DIR= LOGS_DIR= \
    UPDATE_ON_START=false AUTO_UPDATE_INTERVAL_MINUTES=0 JAVA_OPTS= \
    MODS_COLLECTION= MODS_WORKSHOP= MODS_FAIL_FAST=true

EXPOSE 14159/udp
# Exec form on purpose: a shell-form check runs inside `sh -c "pgrep -f 'Server.jar' ..."`, whose own
# argv contains Server.jar, so pgrep matched the wrapper and the container was always "healthy" (2.0.0 bug).
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD ["pgrep", "-f", "Server.jar"]
VOLUME ["/home/necesse/.config/Necesse"]

ENTRYPOINT ["/app/entrypoint.sh"]
CMD []
