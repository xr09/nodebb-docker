# NodeBB container image. Two stages: clone and install, then a slim runtime.

ARG NODE_VERSION=24

# Bump to upgrade NodeBB. CI derives every image tag from it, by grepping for
# this line — so it has to stay the only one that assigns a value. Declared
# before the first FROM to be global; each stage re-declares it bare, which
# inherits this default without repeating it.
ARG NODEBB_VERSION=v4.15.0

# Space-separated npm package names, baked in at build time:
#
#   docker build --build-arg PLUGINS="nodebb-plugin-foo@1.2.4 nodebb-theme-bar@2.0.0" .
#
# Pin versions. The layer is cached on the literal PLUGINS string, so against a
# warm cache an unpinned name reinstalls the previously-resolved version and
# silently misses updates.
ARG PLUGINS=""

# --- build ------------------------------------------------------------------
FROM node:${NODE_VERSION} AS build

ARG NODEBB_VERSION

# DAEMON and SILENT are runtime-only; this stage never starts NodeBB.
ENV NODE_ENV=production \
    USER=nodebb \
    NPM_CONFIG_UPDATE_NOTIFIER=false

WORKDIR /usr/src/app/

# tini is copied into the final stage; git is needed for the clone.
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get -y --no-install-recommends install \
        tini git ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 1001 ${USER} \
    && useradd --uid 1001 --gid 1001 \
           --home-dir /usr/src/app/ --shell /bin/bash ${USER} \
    && chown -R ${USER}:${USER} /usr/src/app/

# Numeric, so Kubernetes runAsNonRoot can enforce it without reading /etc/passwd.
USER 1001

# --depth 1 on a tag: that release, not its history.
RUN git clone --depth 1 --branch ${NODEBB_VERSION} \
        https://github.com/NodeBB/NodeBB.git . \
    && rm -rf .git

# NodeBB's real dependency manifest lives in install/, not at the root.
RUN cp /usr/src/app/install/package.json /usr/src/app/package.json

RUN npm install --omit=dev && rm -rf .npm

# Declared here, not at the top of the stage: BuildKit invalidates every layer
# below an ARG whose value changed, so a stage-top declaration made a PLUGINS
# change re-run the clone and the core install too.
# Keep this line under the core install.
ARG PLUGINS

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

ARG NODEBB_VERSION
ARG PLUGINS

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
    NPM_CONFIG_UPDATE_NOTIFIER=false \
    NPM_CONFIG_FUND=false \
    NPM_CONFIG_AUDIT=false \
    NPM_CONFIG_IGNORE_SCRIPTS=true

WORKDIR /usr/src/app/

# Nothing consumes these; they exist so an override fails the build instead of
# being silently ignored. Do not delete them.
ARG UID=1001
ARG GID=1001
RUN { [ "${UID}" = 1001 ] && [ "${GID}" = 1001 ] || { \
          echo "Error: UID/GID are fixed at 1001 and cannot be overridden." >&2; \
          echo "       Bind mounts are unsupported; named volumes take their" >&2; \
          echo "       ownership from the image, leaving nothing to align with." >&2; \
          exit 1; \
      } ; } \
    && groupadd --gid 1001 ${USER} \
    && useradd --uid 1001 --gid 1001 \
           --home-dir /usr/src/app/ --shell /bin/bash ${USER} \
    && mkdir -p /usr/src/app/logs/ /opt/config/ \
    && chown -R ${USER}:${USER} /usr/src/app/ /opt/config/

COPY --from=build --chown=${USER}:${USER} /usr/src/app/ /usr/src/app/install/docker/setup.json /usr/src/app/
COPY --from=build --chown=${USER}:${USER} /usr/bin/tini /usr/local/bin/tini

# Ours, not NodeBB's. Upstream's still ships in the tree from the COPY above, at
# install/docker/entrypoint.sh, but is never on PATH and never executed.
COPY --chown=${USER}:${USER} entrypoint.sh /usr/local/bin/entrypoint.sh

RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/tini

# Numeric, so Kubernetes runAsNonRoot can enforce it without reading /etc/passwd.
USER 1001

EXPOSE 4567

# /api/v3/ping returns {"pong":true} with no auth and no database access. node,
# because the slim base has no curl or wget. The long start period covers a first
# boot, which compiles assets before it serves.
HEALTHCHECK --interval=30s --timeout=5s --start-period=120s --retries=3 \
    CMD ["node", "-e", "require('http').get('http://127.0.0.1:4567/api/v3/ping', r => process.exit(r.statusCode === 200 ? 0 : 1)).on('error', () => process.exit(1))"]

# node_modules is deliberately absent, though upstream declares it — a stale
# anonymous volume would shadow the new one on every image update.
#
#   build          - compiled client assets, regenerated on upgrade
#   public/uploads - user-uploaded files
#   /opt/config    - config.json, written at first-run setup
VOLUME ["/usr/src/app/build", "/usr/src/app/public/uploads", "/opt/config"]

ENTRYPOINT ["tini", "--", "entrypoint.sh"]
