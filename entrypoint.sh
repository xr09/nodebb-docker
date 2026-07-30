#!/bin/bash
#
# THE entrypoint. This REPLACES NodeBB's install/docker/entrypoint.sh — that
# script is not shipped in this image and there is no fallback to it.
#
# That is a deliberate reversal of this repo's earlier position ("do not fork
# upstream's entrypoint"), and it is a BREAKING CHANGE for anyone consuming the
# published image: plugins can no longer be installed at runtime, from the admin
# panel or otherwise. Read the next section before considering it a bug.
#
# WHY
#
# Upstream's entrypoint is built around NodeBB's native plugin model, where
# plugins are installed at RUNTIME from the admin panel — src/plugins/install.js
# shells out to `npm install <plugin>` against the live tree. To make that
# survive a container being replaced, it splits state:
#
#   package.json + lockfile  ->  symlinked onto the config volume, DURABLE
#   node_modules             ->  image, EPHEMERAL
#   npm install on boot      ->  reconciles the second against the first
#
# Coherent for admin-installed plugins. Actively wrong for an image built with
# PLUGINS baked in, where the IMAGE is the source of truth: the persisted
# package.json then SHADOWS the image's, and the boot-time npm install DELETES
# any plugin the image added that the older persisted file does not list.
# Observed on a consumer forum as a bare `removed 1 package`, with the plugin
# present in the image and absent from the running container.
#
# The two models cannot both be right in the same container, and the persisted
# one wins by deletion. This image is built for baked-in plugins — PLUGINS is a
# build-arg, the plugin set is asserted at build time — so it commits to that
# model rather than shipping a switch between two premises.
#
# Three further things this buys, none of which depend on dropping egress:
#
#   - Boot is a pure function of the image and the database. It no longer
#     depends on the npm registry being reachable or unchanged.
#   - Rolling back to an older image tag actually rolls back dependencies.
#     Under upstream's model the persisted package.json does not roll back, so
#     the boot install drags node_modules toward the NEWER dependency set while
#     running older code.
#   - package-lock.json stops drifting. Upstream symlinks it onto the volume and
#     boot runs `npm install`, not `npm ci`, so resolved versions accumulate
#     outside any source of truth.
#
# WHAT IT COSTS: the ACP's plugin Install and Upgrade buttons no longer work.
# Installing a plugin is a rebuild with a different PLUGINS build-arg. Plugin
# ACTIVATION is unaffected — that is database state, not files. NodeBB's `SETUP`
# environment variable is not supported either; it never worked properly (it
# passes the config PATH where `nodebb setup` wants JSON, then execs, so the
# container loops under a restart policy).
#
# NOT AN ALTERNATIVE TO ANY OF THIS: OVERRIDE_UPDATE_LOCK. It reads like a way to
# make the image authoritative under upstream's entrypoint, and it crash-loops
# the container. copy_or_link_files() ENDS by symlinking source onto destination,
# so from the second start its seeding `cp` copies a file onto itself, fails, and
# `set -e` exits 1. A fresh container filesystem works, so it survives the deploy
# that introduces it and breaks on the next plain restart or host reboot.

set -e

CONFIG_DIR="${CONFIG_DIR:-/opt/config}"
CONFIG="${CONFIG:-$CONFIG_DIR/config.json}"
NODEBB_INIT_VERB="${NODEBB_INIT_VERB:-install}"
NODEBB_BUILD_VERB="${NODEBB_BUILD_VERB:-build}"
START_BUILD="${START_BUILD:-${FORCE_BUILD_BEFORE_START:-false}}"

# Refuse rather than ignore. This variable's entire job is to npm-install at
# runtime, which is the thing this image no longer does; silently dropping it
# would start a forum missing plugins somebody explicitly asked for.
if [ -n "${NODEBB_ADDITIONAL_PLUGINS:-}" ]; then
  echo "Error: NODEBB_ADDITIONAL_PLUGINS is set, but this image installs nothing" >&2
  echo "       at runtime. Bake them into the image instead:" >&2
  echo "         docker build --build-arg PLUGINS=\"nodebb-plugin-foo@1.2.3\" ." >&2
  exit 1
fi

# Same reasoning as upstream's check_directory, minus the chown/chmod repair:
# far less is written here now (config.json and the hash below), and a volume
# this container cannot write is a misconfiguration worth failing on.
mkdir -p "$CONFIG_DIR"
if [ ! -w "$CONFIG_DIR" ]; then
  echo "Error: No write permission for $CONFIG_DIR. Exiting..." >&2
  exit 1
fi

echo "Dependencies come from the image. No npm install, no runtime plugin installs."

# A plugin active in the database but missing from the image only warns —
# src/plugins/data.js getPluginPaths() logs "is active but not installed" and
# filters it out. A missing THEME is fatal: src/meta/themes.js setupPaths()
# throws theme-not-found and src/start.js exits, with nothing in the log naming
# the cause. Themes are found by scanning node_modules, so a theme installed
# through the ACP under an older image does not survive into a rebuilt one.
# One `ls` to make that diagnosable without a shell in the container.
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

# The same gate upstream uses, and here it is the right one: install/package.json
# is NodeBB's own manifest, baked into the image, so it can only move when the
# image does — which is precisely when `nodebb upgrade` needs to run its schema
# migrations. Under upstream's model that same file is reached through a mutable
# symlink, which is what makes the gate unreliable there.
package_hash=$(md5sum /usr/src/app/install/package.json | head -c 32)
if [ "$package_hash" != "$(cat "$CONFIG_DIR/install_hash.md5" 2>/dev/null || true)" ]; then
  echo "NodeBB image changed. Upgrading (schema + assets)..."
  # -s -b, NOT a bare `nodebb upgrade`, which would defeat the whole design.
  # From src/cli/index.js, upgrade takes five flags and "By default all options
  # are enabled. Passing any options disables that default":
  #
  #   -m --package  rewrite package.json from defaults   <- must not
  #   -i --install  bring base dependencies up to date   <- must not (npm install)
  #   -p --plugins  check installed plugins for updates  <- must not (registry)
  #   -s --schema   update the data store schema         <- yes
  #   -b --build    rebuild assets                       <- yes
  #
  # The first three are exactly what this image exists to avoid, and they are
  # unnecessary anyway: dependencies arrived with the new image. What still has
  # to happen is the work against PERSISTENT state — migrating the database and
  # recompiling assets — which is what -s -b does. Caught by the tests in
  # CLAUDE.md, which saw `up to date` in the log of a bare upgrade.
  # The exit code of `nodebb upgrade` cannot be trusted as a success signal: a
  # database that is unset or not yet reachable logs "Database type not set!" and
  # the process still returns 0. Upstream's build_forum() has the same shape, and
  # the consequence is worse than a bad start — the hash below would be recorded,
  # so every LATER start sees a matching hash, skips the migration, and runs new
  # code against an un-migrated schema, with nothing anywhere reporting a problem.
  # runSteps() in src/cli/upgrade.js prints its banner only after every step has
  # returned, so require that instead of, not in addition to, the exit code.
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

# exec, where upstream uses a plain `npm start ... || exit 1`. tini is PID 1, so
# exec makes npm its direct child and a SIGTERM from `docker stop` reaches NodeBB
# rather than a bash frame that will not forward it.
exec npm start -- --config="$CONFIG" --no-silent --no-daemon
