# NodeBB container image
#
# Structure mirrors NodeBB's own Dockerfile. Two deliberate differences: our own
# entrypoint, and node_modules is not a VOLUME. Both are documented where they
# happen.

ARG NODE_VERSION=24

# --- build ------------------------------------------------------------------
FROM node:${NODE_VERSION} AS build

# Bump this to upgrade NodeBB. CI derives every image tag from it, so the commit
# that changes it is the commit that publishes the new version.
ARG NODEBB_VERSION=v4.14.4
ARG UID=1001
ARG GID=1001

# Space-separated npm package names, baked in at build time.
#
# Empty by default: the published image is vanilla NodeBB. Plugin-bearing images
# are a build-arg override:
#
#   docker build --build-arg PLUGINS="nodebb-plugin-foo@1.2.4 nodebb-theme-bar@2.0.0" .
#
# Pin versions. This layer is cached on the literal PLUGINS string, so against a
# warm cache an unpinned name reinstalls the previously-resolved version and
# silently misses updates; a pinned bump changes the string and rebuilds it.
#
# This is the only way to add plugins here — the entrypoint installs nothing at
# runtime and refuses NODEBB_ADDITIONAL_PLUGINS.
ARG PLUGINS=""

ENV NODE_ENV=production \
    DAEMON=false \
    SILENT=false \
    USER=nodebb \
    UID=${UID} \
    GID=${GID} \
    NPM_CONFIG_UPDATE_NOTIFIER=false

WORKDIR /usr/src/app/

# corepack must be enabled as root — it writes shims into /usr/local/bin.
# tini is copied into the final stage; git is needed for the clone below.
RUN corepack enable \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get -y --no-install-recommends install \
        tini git ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && if getent group ${GID} >/dev/null; then \
           groupmod -n ${USER} "$(getent group ${GID} | cut -d: -f1)"; \
       else \
           groupadd --gid ${GID} ${USER}; \
       fi \
    && if getent passwd ${UID} >/dev/null; then \
           usermod -l ${USER} -g ${GID} -d /usr/src/app/ -s /bin/bash \
               "$(getent passwd ${UID} | cut -d: -f1)"; \
       else \
           useradd --uid ${UID} --gid ${GID} --home-dir /usr/src/app/ \
               --shell /bin/bash ${USER}; \
       fi \
    && chown -R ${USER}:${USER} /usr/src/app/

USER ${USER}

# Cloned rather than vendored, so this repo carries no copy of NodeBB to keep in
# sync. --depth 1 on a tag: we want that release, not its history.
RUN git clone --depth 1 --branch ${NODEBB_VERSION} \
        https://github.com/NodeBB/NodeBB.git . \
    && rm -rf .git

# NodeBB's real dependency manifest lives in install/, not at the root.
RUN cp /usr/src/app/install/package.json /usr/src/app/package.json

RUN npm install --omit=dev && rm -rf .npm

# Separate layer so changing PLUGINS does not invalidate the (expensive) core
# install above.
RUN if [ -n "${PLUGINS}" ]; then \
        echo "Installing plugins: ${PLUGINS}" \
        && npm install --omit=dev ${PLUGINS} \
        && rm -rf .npm ; \
    else \
        echo "No plugins requested (PLUGINS empty) — vanilla NodeBB" ; \
    fi

# --- final ------------------------------------------------------------------
FROM node:${NODE_VERSION}-slim AS final

ARG NODEBB_VERSION=v4.14.4
ARG UID=1001
ARG GID=1001
ARG PLUGINS=""

LABEL org.opencontainers.image.title="nodebb" \
      org.opencontainers.image.description="NodeBB forum, built from source" \
      org.opencontainers.image.source="https://github.com/xr09/nodebb-docker" \
      org.opencontainers.image.licenses="MIT" \
      org.nodebb.version="${NODEBB_VERSION}" \
      org.nodebb.plugins="${PLUGINS}"

ENV NODE_ENV=production \
    DAEMON=false \
    SILENT=false \
    USER=nodebb \
    UID=${UID} \
    GID=${GID} \
    NPM_CONFIG_UPDATE_NOTIFIER=false \
    NPM_CONFIG_FUND=false \
    NPM_CONFIG_AUDIT=false \
    NPM_CONFIG_IGNORE_SCRIPTS=true

WORKDIR /usr/src/app/

RUN corepack enable \
    && if getent group ${GID} >/dev/null; then \
           groupmod -n ${USER} "$(getent group ${GID} | cut -d: -f1)"; \
       else \
           groupadd --gid ${GID} ${USER}; \
       fi \
    && if getent passwd ${UID} >/dev/null; then \
           usermod -l ${USER} -g ${GID} -d /usr/src/app/ -s /bin/bash \
               "$(getent passwd ${UID} | cut -d: -f1)"; \
       else \
           useradd --uid ${UID} --gid ${GID} --home-dir /usr/src/app/ \
               --shell /bin/bash ${USER}; \
       fi \
    && mkdir -p /usr/src/app/logs/ /opt/config/ \
    && chown -R ${USER}:${USER} /usr/src/app/ /opt/config/

COPY --from=build --chown=${USER}:${USER} /usr/src/app/ /usr/src/app/install/docker/setup.json /usr/src/app/
COPY --from=build --chown=${USER}:${USER} /usr/bin/tini /usr/local/bin/tini

# Our entrypoint, replacing NodeBB's. Upstream's npm-installs on every boot and
# prunes plugins baked into the image, so it is never put on PATH and never
# executed — no fallback. It still ships in the tree from the COPY above, at
# install/docker/entrypoint.sh, wired to nothing. Reasoning in entrypoint.sh.
COPY --chown=${USER}:${USER} entrypoint.sh /usr/local/bin/entrypoint.sh

RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/tini

USER ${USER}

EXPOSE 4567

# `/usr/src/app/node_modules` is deliberately not declared here; upstream's
# Dockerfile does declare it.
#
# A declared VOLUME makes Docker create an anonymous volume from the image on
# first run. On a later image update that stale volume shadows the new image's
# node_modules, so a rebuild with upgraded dependencies or new plugins keeps
# running the old ones while every surface reports the deploy succeeded. Same
# shape as postgres:18 moving PGDATA. Omitting it means node_modules comes from
# the image and is correct by construction — no `--renew-anon-volumes` needed.
#
# The three below are genuine state and must persist:
#   build          - compiled client assets, regenerated on upgrade
#   public/uploads - user-uploaded files
#   /opt/config    - config.json, written at first-run setup
VOLUME ["/usr/src/app/build", "/usr/src/app/public/uploads", "/opt/config"]

ENTRYPOINT ["tini", "--", "entrypoint.sh"]
