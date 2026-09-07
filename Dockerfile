# Necesse Dedicated Server — ghcr.io/steamcmd/steamcmd base, bundled Steam JRE (no distro Java)
FROM ghcr.io/steamcmd/steamcmd:debian-13

ARG BUILD_VERSION=dev
ARG BUILD_REVISION=unknown
ARG uid=1000
ARG gid=1000

# gosu drops privileges in the entrypoint; procps provides pgrep/pkill for the healthcheck and auto-update.
RUN apt-get update && apt-get install -y --no-install-recommends gosu procps \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd -g ${gid} necesse && useradd -u ${uid} -g necesse -s /bin/bash -m necesse \
 && mkdir -p /app /steamapps /home/necesse/.config/Necesse \
 && printf '%s\n' '@ShutdownOnFailedCommand 1' '@NoPromptForPassword 1' 'force_install_dir /app' \
      'login anonymous' 'app_update 1169370 validate' 'quit' > /steamapps/update_necesse.txt \
 && chown -R necesse:necesse /app /steamapps /home/necesse

# Bake the current Steam build (appid 1169370) as the runtime user, so the per-user SteamCMD state ships in the image.
# Warm SteamCMD (self-update) and add the sdk32/sdk64 links the base image creates for root; a cold first-run
# app_update otherwise fails with "Missing configuration". The install itself is retried because Steam
# occasionally refuses a fresh client's first app_update even when warm.
RUN gosu necesse env HOME=/home/necesse sh -c ' \
      steamcmd +quit >/dev/null && mkdir -p ~/.steam \
   && ln -sfn ~/.local/share/Steam/steamcmd/linux32 ~/.steam/sdk32 \
   && ln -sfn ~/.local/share/Steam/steamcmd/linux64 ~/.steam/sdk64 \
   && ln -sf ~/.steam/sdk32/steamclient.so ~/.steam/sdk32/steamservice.so \
   && ln -sf ~/.steam/sdk64/steamclient.so ~/.steam/sdk64/steamservice.so \
   && for i in 1 2 3; do steamcmd +runscript /steamapps/update_necesse.txt && break; echo "SteamCMD attempt $i failed; retrying"; done \
   && test -x /app/jre/bin/java && test -f /app/Server.jar'

COPY --chown=necesse:necesse --chmod=755 entrypoint.sh /app/entrypoint.sh
WORKDIR /app

LABEL org.opencontainers.image.title="Necesse Dedicated Server" \
      org.opencontainers.image.description="Necesse dedicated server on the official SteamCMD image, running Server.jar under the JRE bundled with the Steam build. Fork of andreas-glaser/necesse-docker-server." \
      org.opencontainers.image.source="https://github.com/stargumbo/necesse-server" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${BUILD_VERSION}" \
      org.opencontainers.image.revision="${BUILD_REVISION}"

# Runtime identity and server defaults (all overridable at run time; see README). SERVER_PASSWORD is
# deliberately not defaulted here: pass it at run time only.
ENV CONTAINER_USER=necesse CONTAINER_GROUP=necesse CONTAINER_UID=${uid} CONTAINER_GID=${gid} \
    WORLD_NAME=world SERVER_PORT=14159 SERVER_SLOTS=10 SERVER_OWNER= SERVER_MOTD= \
    PAUSE_WHEN_EMPTY=0 GIVE_CLIENTS_POWER=0 ENABLE_LOGGING=1 ZIP_SAVES=1 SERVER_LANGUAGE=en \
    SETTINGS_FILE= BIND_IP= MAX_CLIENT_LATENCY= LOCAL_DIR=0 DATA_DIR= LOGS_DIR= \
    UPDATE_ON_START=false AUTO_UPDATE_INTERVAL_MINUTES=0 JAVA_OPTS=

EXPOSE 14159/udp
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD pgrep -f 'Server.jar' >/dev/null || exit 1
VOLUME ["/home/necesse/.config/Necesse"]

# The base image's ENTRYPOINT is steamcmd itself; replace it.
ENTRYPOINT ["/app/entrypoint.sh"]
CMD []
