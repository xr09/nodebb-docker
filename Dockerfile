# NodeBB container image — site-agnostic.
#
# Structure mirrors NodeBB's own Dockerfile, with two deliberate differences
# documented at the VOLUME line and in the README.

ARG NODE_VERSION=24

# --- build ------------------------------------------------------------------
FROM node:${NODE_VERSION} AS build

# Bump this to upgrade NodeBB. CI derives every image tag from it, so the commit
# that changes it is the commit that publishes the new version.
ARG NODEBB_VERSION=v4.14.0

# Space-separated npm package names, baked in at build time.
#
# EMPTY BY DEFAULT, and that is the point: the published image is vanilla NodeBB
# and reusable by anyone. Baking a specific forum's plugin list into the default
# would leak that forum's attack surface and break the agnostic premise. Build a
# variant instead:
#   docker build --build-arg PLUGINS="nodebb-plugin-foo nodebb-theme-bar" .
#
# Baking at build time rather than using NODEBB_ADDITIONAL_PLUGINS means the
# running container does not npm-install plugins on every start.
ARG PLUGINS=""

ENV NODE_ENV=production \
    DAEMON=false \
    SILENT=false \
    USER=nodebb \
    UID=1001 \
    GID=1001 \
    NPM_CONFIG_UPDATE_NOTIFIER=false

WORKDIR /usr/src/app/

# corepack must be enabled as root — it writes shims into /usr/local/bin.
# tini is copied into the final stage; git is needed for the clone below.
RUN corepack enable \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get -y --no-install-recommends install \
        tini git ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid ${GID} ${USER} \
    && useradd --uid ${UID} --gid ${GID} --home-dir /usr/src/app/ --shell /bin/bash ${USER} \
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

ARG NODEBB_VERSION=v4.14.0
ARG PLUGINS=""

LABEL org.opencontainers.image.title="nodebb" \
      org.opencontainers.image.description="NodeBB forum, built from source at a pinned release" \
      org.opencontainers.image.source="https://github.com/xr09/nodebb-docker" \
      org.opencontainers.image.licenses="MIT" \
      org.nodebb.version="${NODEBB_VERSION}" \
      org.nodebb.plugins="${PLUGINS}"

ENV NODE_ENV=production \
    DAEMON=false \
    SILENT=false \
    USER=nodebb \
    UID=1001 \
    GID=1001 \
    NPM_CONFIG_UPDATE_NOTIFIER=false \
    NPM_CONFIG_FUND=false \
    NPM_CONFIG_AUDIT=false \
    NPM_CONFIG_IGNORE_SCRIPTS=true

WORKDIR /usr/src/app/

RUN corepack enable \
    && groupadd --gid ${GID} ${USER} \
    && useradd --uid ${UID} --gid ${GID} --home-dir /usr/src/app/ --shell /bin/bash ${USER} \
    && mkdir -p /usr/src/app/logs/ /opt/config/ \
    && chown -R ${USER}:${USER} /usr/src/app/ /opt/config/

COPY --from=build --chown=${USER}:${USER} /usr/src/app/ /usr/src/app/install/docker/setup.json /usr/src/app/
COPY --from=build --chown=${USER}:${USER} /usr/bin/tini /usr/src/app/install/docker/entrypoint.sh /usr/local/bin/

RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/tini

USER ${USER}

EXPOSE 4567

# NOTE: `/usr/src/app/node_modules` is deliberately NOT declared here, and
# upstream's Dockerfile does declare it.
#
# A declared VOLUME makes Docker create an anonymous volume from the image on
# first run. On a LATER image update that stale volume shadows the new image's
# node_modules — so a rebuilt image with upgraded dependencies or new plugins
# silently keeps running the old ones, while every surface says the deploy
# succeeded. (Same shape as postgres:18 moving PGDATA: the container works and
# quietly ignores the thing you changed.)
#
# Omitting it means node_modules comes from the image and is correct by
# construction, so consumers need no `--renew-anon-volumes` workaround. The
# trade-off is that runtime `npm install` writes to the container layer rather
# than a volume, which is what we want for an immutable image.
#
# The three below are genuine state and must persist:
#   build          - compiled client assets, regenerated on upgrade
#   public/uploads - user-uploaded files
#   /opt/config    - config.json, written at first-run setup
VOLUME ["/usr/src/app/build", "/usr/src/app/public/uploads", "/opt/config"]

ENTRYPOINT ["tini", "--", "entrypoint.sh"]
