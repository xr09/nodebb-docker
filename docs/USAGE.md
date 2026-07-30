# Usage guide

How to deploy, configure, upgrade, and build `nodebb-docker`. For what the image
is and how tags work, see the [README](../README.md).

- [Usage](#usage) — first-run compose setup
  - [What doesn't work](#what-doesnt-work)
- [node_modules is not a volume](#node_modules-is-not-a-volume)
- [Nothing is installed at runtime](#nothing-is-installed-at-runtime)
- [Migrating from the published image](#migrating-from-the-published-image)
- [Recommended config.json settings](#recommended-configjson-settings)
- [Plugins](#plugins)
- [Redis as a session store](#redis-as-a-session-store)
- [Upgrading NodeBB](#upgrading-nodebb)
- [Building locally](#building-locally)

## Usage

NodeBB listens on 4567. Volumes: `/opt/config`, `/usr/src/app/public/uploads`,
`/usr/src/app/build`.

First install is the awkward part; the obvious approaches don't work. This
compose setup does:

```yaml
services:
  # Installs on first run and exits. Runs before the forum.
  setup:
    image: ghcr.io/xr09/nodebb-docker:4.14.0
    restart: 'no'
    depends_on: { mongo: { condition: service_healthy } }
    environment:
      CONFIG: /opt/config/config.json
    volumes:
      - nodebb-config:/opt/config
      - nodebb-build:/usr/src/app/build
      - ./setup.sh:/setup.sh:ro
    entrypoint: ['/bin/bash', '/setup.sh']

  nodebb:
    image: ghcr.io/xr09/nodebb-docker:4.14.0
    restart: unless-stopped
    depends_on:
      setup: { condition: service_completed_successfully }
    environment:
      # nconf is wired as nconf.env({separator:'__'}), so `mongo__host` becomes
      # mongo.host. Lowercase names are not a typo — nconf reads env keys
      # verbatim and NodeBB's config keys are lowercase.
      url: https://forum.example.com
      secret: <random>
      database: mongo
      mongo__host: mongo
      mongo__port: '27017'
      mongo__username: nodebb
      mongo__password: <secret>
      mongo__database: nodebb
    volumes:
      - nodebb-config:/opt/config
      - nodebb-uploads:/usr/src/app/public/uploads
      - nodebb-build:/usr/src/app/build
```

where `setup.sh` skips if `config.json` exists and otherwise runs

```bash
export CONFIG=/opt/config/config.json
cd /usr/src/app && ./nodebb setup "$SETUP_JSON"
```

with `SETUP_JSON` built from your environment using NodeBB's colon key form
(`mongo:host`, `admin:username`) — a different convention from the `mongo__host`
env form used at runtime. A complete implementation is at
[`websites/foroguzzi/setup.sh`](https://github.com/xr09/orbit1) in the author's
infrastructure repo.

### What doesn't work

**Setting the `SETUP` environment variable.** Upstream's entrypoint does:

```sh
if [ -n "$SETUP" ]; then exec /usr/src/app/nodebb setup --config="$config"; fi
```

It passes `--config=<path to config.json>`, not the JSON. `nodebb setup` takes
its config as a positional argument (`.command('setup [config]')`), so with
`SETUP` set it runs interactively and blocks. And because it `exec`s, the
container exits when setup ends — under `restart: unless-stopped` it loops
through setup forever.

This image does not implement `SETUP` at all, for that reason. Use the `setup.sh`
init-service pattern above.

**Supplying everything via environment variables and just starting.** The
entrypoint chooses what to run by testing whether the config file exists:

```sh
if [ -f "$CONFIG" ]; then start_forum ...; else nodebb install ...; fi
```

It never consults nconf: with `url`, `secret`, `database` and the full mongo
block all visible to nconf inside the container, NodeBB still logged "Launching
web installer on port 4567" and sat waiting for a browser.

Environment variables are still the right way to configure the running forum —
they just can't get you past the first install.

## node_modules is not a volume

Upstream's Dockerfile declares it:

```
VOLUME ["/usr/src/app/node_modules", "/usr/src/app/build", ...]
```

Docker then creates an anonymous volume from the image on first run, and on a
later image update that stale volume shadows the new image's `node_modules`.
Upgrade the image and it silently keeps running the old dependencies and plugins
while everything reports success.

This image omits `node_modules` from the VOLUME list, so it comes from the image
and is correct by construction. You do not need `--renew-anon-volumes`.

Migrating from an image that did declare it: remove the old anonymous volume
once, or you'll keep the stale copy.

## Nothing is installed at runtime

**This image replaces NodeBB's entrypoint.** It does not `npm install` on boot,
does not symlink `package.json` onto the config volume, and does not install
plugins at runtime. Dependencies come from the image and nowhere else.

That is a **breaking difference from upstream and from earlier versions of this
image**, so it is worth stating plainly what stops working:

- The admin panel's plugin **Install** and **Upgrade** buttons.
- `NODEBB_ADDITIONAL_PLUGINS` — refused with an error rather than ignored.
- The `SETUP` environment variable, which never worked properly anyway (see
  [What doesn't work](#what-doesnt-work)).

Installing a plugin is a rebuild with a different `PLUGINS` build-arg. Plugin
**activation** is unaffected — that is database state, not files, so the ACP's
enable/disable toggles work normally.

### Why

Upstream treats the persisted `package.json` as the source of truth, because
NodeBB installs plugins at runtime (`src/plugins/install.js` shells out to
`npm install <plugin>`). This image treats *itself* as the source of truth, via
the `PLUGINS` build-arg. Run both premises in one container and the volume wins
by deletion: the boot `npm install` prunes any plugin the image added that the
older persisted `package.json` doesn't list, logged only as a terse
`removed 1 package`.

Three things follow from removing it, beyond the obvious:

- **Boot is deterministic.** It no longer depends on the npm registry being
  reachable or unchanged.
- **Image rollback works.** Under upstream's model the persisted `package.json`
  does not roll back with the image, so the boot install drags `node_modules`
  toward the *newer* dependency set while running older code.
- **The lockfile stops drifting.** Upstream symlinks `package-lock.json` onto the
  volume and boot runs `npm install`, not `npm ci`, so resolved versions
  accumulate outside any source of truth.

### Outbound network

Nothing at boot needs it. The container will start on an internal-only network.

You may still want egress for the *application* — SMTP, S3, outbound webhooks,
OAuth providers — and that is fine; it's just no longer a requirement for the
container to come up.

One admin page does need it. `/admin/extend/plugins` calls
`plugins.listTrending()` against `packages.nodebb.org`, and unlike the two calls
beside it that one is not wrapped in a try/catch, so with no egress the whole
route returns a 500. The forum itself is unaffected, but an admin who lands there
first will read it as a broken image.

Logs are not persisted. `logs/output.log` is created on every start and stays
empty, because the container runs with `--no-silent` and NodeBB writes to stdout
instead — use `docker logs`. The ACP log viewer reads that file, so it shows
nothing by design.

> **`OVERRIDE_UPDATE_LOCK` is not a way to get this behaviour from upstream's
> entrypoint.** It reads like the fix — force the image's `package.json` over the
> volume's — and it crash-loops the container. `copy_or_link_files()` ends by
> symlinking source onto destination, so from the second start its seeding `cp`
> copies a file onto itself, fails, and `set -e` exits 1. A fresh container
> filesystem works, so it survives the deploy that introduces it and breaks on
> the next plain restart or host reboot.

`nodebb upgrade` still runs when the image's NodeBB version moves, gated on the
md5 of `install/package.json` — restricted to `-s -b` (schema and assets), the
parts that act on persistent state.

## Migrating from the published image

Earlier versions of this image ran upstream's entrypoint: `npm install` on boot, a
`package.json` persisted on the config volume, `node_modules` as a volume. If you
installed plugins or themes through the admin panel under one of those, they live
only in that volume and in the old `package.json` — this image does not read
either. Bake your plugin set first, then deploy, and the warnings below stay
empty.

**Plugins are a soft failure.** A plugin still marked active in the database but
absent from the image logs one line per plugin at boot and the forum starts
normally:

```
[plugins] "nodebb-plugin-foo" is active but not installed.
```

Activation is database state, so re-adding the plugin to `PLUGINS` and rebuilding
brings it back already enabled. Nothing to re-toggle.

**The active theme is a hard failure.** Themes are discovered by scanning
`node_modules`, so if the theme your forum is set to isn't in the image, NodeBB
throws `theme-not-found` and exits — the container will not boot, and the log does
not name the theme. The entrypoint prints what is baked in on every start so you
can compare:

```
Baked themes: harmony lavender peace persona
```

Those four ship with NodeBB and are in every build. If your forum uses one of
them you are unaffected. Otherwise either bake it:

```bash
docker build --build-arg PLUGINS="nodebb-theme-yours@1.2.3" -t my-nodebb .
```

or reset to `harmony` and pick again from the admin panel:

```bash
docker compose run --rm nodebb /usr/src/app/nodebb reset -t --config=/opt/config/config.json
```

## Recommended config.json settings

None of these are required, and the image does not set them for you — it stays
site-agnostic. They make the image's stance enforceable inside NodeBB rather than
only at the entrypoint.

| Setting | What it buys | What it costs |
|---|---|---|
| `"acpPluginInstallDisabled": true` | The admin panel's Install and Upgrade buttons return a proper error instead of hanging on an npm call that cannot succeed. | Nothing. Note it does not cover *uninstall* of an already-installed plugin, which still tries to run npm and fails. |
| `"plugins:active": ["nodebb-plugin-foo", …]` | Makes the plugin set fully declarative and immutable: NodeBB refuses to change it, and the admin panel renders the toggles disabled. Matches the baked-image model exactly. | You lose admin-panel enable/disable entirely. Every change becomes a config change. |
| `"dep-check": false` | Skips the boot-time scan of `node_modules` against `package.json`. | Nothing for a baked image, where the two agree by construction. It would hide genuine drift if you ever hand-edit the tree. |

## Plugins

Empty by default, so the published image stays vanilla and reusable. To bake
plugins in, build a variant:

```bash
docker build \
  --build-arg PLUGINS="nodebb-plugin-markdown@3.1.0 nodebb-theme-harmony@1.2.0" \
  -t my-nodebb .
```

**Pin plugin versions.** The plugin install is a cached layer keyed on the exact
`PLUGINS` string, so against a warm build cache an unpinned name keeps installing
the version it first resolved and silently misses updates. A pinned version bump
changes the string, rebuilds only the plugin layer (the core install stays
cached), and installs exactly that version.

Baking at build time is the *only* way here. NodeBB's
`NODEBB_ADDITIONAL_PLUGINS`, which npm-installs on every container start, is
refused with an error — see
[Nothing is installed at runtime](#nothing-is-installed-at-runtime).

The default is kept empty on purpose: a plugin list baked into a public image
discloses the attack surface of whichever forum it was built for.

## Redis as a session store

Declaring a `redis` block is all it takes to make Redis the session store while
another database stays primary — from `src/database/index.js`:

```js
} else if (nconf.get('redis')) {
    // if redis is specified, use it as session store over others
```

**But `nodebb setup` does not persist it.** It writes only `url`, `secret`,
`database`, `port` and the primary database block into config.json, and drops the
redis one: `sess:*` keys appear in Redis while config.json contains no redis
block at all.

So supply `redis__host` / `redis__port` / `redis__password` as environment
variables on the forum container. Removing them later on the assumption that
config.json holds them silently moves sessions back to the primary database —
the forum keeps working, so nothing flags it.

## Upgrading NodeBB

Edit `ARG NODEBB_VERSION` in the Dockerfile, commit, push. CI derives all four
tags from that value, so they cannot drift from what was actually built.

Read NodeBB's own upgrade notes first — major versions may need a schema upgrade
step, which the entrypoint performs against the existing database.

## Building locally

```bash
docker build -t nodebb-docker:dev .
docker build --build-arg NODEBB_VERSION=v4.13.0 -t nodebb-docker:4.13.0 .
```

amd64 only in CI. Add `linux/arm64` to `platforms` in the workflow if you need it.
