#!/bin/bash
#
# Replaces NodeBB's install/docker/entrypoint.sh. No fallback to it: this image
# installs nothing at runtime.
#
# Step-by-step behaviour and the variables honoured below:
# docs/NODEBB-IN-DOCKER.md, "What this image's entrypoint does".

set -euo pipefail

CONFIG_DIR="${CONFIG_DIR:-/opt/config}"
CONFIG="${CONFIG:-$CONFIG_DIR/config.json}"
NODEBB_INIT_VERB="${NODEBB_INIT_VERB:-install}"
NODEBB_BUILD_VERB="${NODEBB_BUILD_VERB:-build}"
START_BUILD="${START_BUILD:-${FORCE_BUILD_BEFORE_START:-false}}"

if [ -n "${NODEBB_ADDITIONAL_PLUGINS:-}" ]; then
  echo "Error: NODEBB_ADDITIONAL_PLUGINS is set, but this image installs nothing" >&2
  echo "       at runtime. Bake them into the image instead:" >&2
  echo "         docker build --build-arg PLUGINS=\"nodebb-plugin-foo@1.2.3\" ." >&2
  exit 1
fi

mkdir -p "$CONFIG_DIR"
if [ ! -w "$CONFIG_DIR" ]; then
  echo "Error: No write permission for $CONFIG_DIR. Exiting..." >&2
  exit 1
fi

echo "Dependencies come from the image. No npm install, no runtime plugin installs."

# A missing plugin only warns; a missing theme exits before anything names it.
# One glob to make that diagnosable without a shell in the container.
baked_themes=""
for d in /usr/src/app/node_modules/nodebb-theme-*; do
  [ -d "$d" ] || continue          # no match: the glob stays literal, skip it
  baked_themes="$baked_themes ${d##*/nodebb-theme-}"
done
echo "Baked themes:${baked_themes:- none}"
echo "  (a 'theme-not-found' exit means the active theme is not one of these — bake it"
echo "   via PLUGINS, or fall back to harmony with: nodebb reset -t)"

if [ ! -f "$CONFIG" ]; then
  echo "Config file not found at $CONFIG"
  echo "Starting installation session"
  exec /usr/src/app/nodebb "$NODEBB_INIT_VERB" --config="$CONFIG"
fi

# install/package.json is baked in, so it moves only when the image does — which
# is exactly when the schema migrations need to run.
package_hash=$(md5sum /usr/src/app/install/package.json | head -c 32)
if [ "$package_hash" != "$(cat "$CONFIG_DIR/install_hash.md5" 2>/dev/null || true)" ]; then
  echo "NodeBB image changed. Upgrading (schema + assets)..."
  # Two things here are load-bearing and must not be "simplified": `-s -b` rather
  # than a bare `nodebb upgrade`, and gating on the banner rather than the exit
  # code, which is 0 even when a step fails.
  upgrade_log=$(mktemp)
  /usr/src/app/nodebb upgrade -s -b --config="$CONFIG" 2>&1 | tee "$upgrade_log"
  if ! grep -q 'NodeBB Upgrade Complete' "$upgrade_log"; then
    rm -f "$upgrade_log"
    echo "Failed to upgrade NodeBB. Exiting..." >&2
    exit 1
  fi
  rm -f "$upgrade_log"
  echo -n "$package_hash" > "$CONFIG_DIR/install_hash.md5"
elif [ "$START_BUILD" = true ]; then
  echo "Build before start is enabled. Building..."
  /usr/src/app/nodebb "$NODEBB_BUILD_VERB" --config="$CONFIG" || {
    echo "Failed to build NodeBB. Exiting..." >&2
    exit 1
  }
else
  echo "NodeBB image unchanged. Skipping build..."
fi

# exec so that SIGTERM from `docker stop` reaches NodeBB rather than a bash frame
# that will not forward it. tini is PID 1.
exec npm start -- --config="$CONFIG" --no-silent --no-daemon
