# Usage guide

How to deploy, configure, upgrade, and build `nodebb-docker`. For what the image
is and how tags work, see the [README](../README.md).

- [Usage](#usage) — first-run compose setup
  - [What does NOT work, and why](#what-does-not-work-and-why)
- [Two things worth knowing before you run it](#two-things-worth-knowing-before-you-run-it)
- [Plugins](#plugins)
- [Redis as a session store](#redis-as-a-session-store)
- [Upgrading NodeBB](#upgrading-nodebb)
- [Building locally](#building-locally)

## Usage

NodeBB listens on **4567**. Volumes: `/opt/config`, `/usr/src/app/public/uploads`,
`/usr/src/app/build`.

Getting a *first* run to work is the fiddly part, and the obvious approaches do
not work — see below. This is the shape that does:

```yaml
services:
  # Installs on first run and exits. Runs BEFORE the forum.
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

with `SETUP_JSON` built from your environment using NodeBB's **colon** key form
(`mongo:host`, `admin:username`), which is a different convention from the
`mongo__host` env form used at runtime. A complete, working implementation is at
[`websites/foroguzzi/setup.sh`](https://github.com/xr09/orbit1) in the author's
infrastructure repo.

### What does NOT work, and why

**Setting the `SETUP` environment variable.** Upstream's entrypoint does:

```sh
if [ -n "$SETUP" ]; then exec /usr/src/app/nodebb setup --config="$config"; fi
```

It passes `--config=<path to config.json>`, **not** the JSON. `nodebb setup`
takes its config as a *positional* argument (`.command('setup [config]')`), so
with `SETUP` set it runs **interactively** and blocks. And because it `exec`s,
the container exits when setup ends — under `restart: unless-stopped` it then
loops through setup forever.

**Supplying everything via environment variables and just starting.** The
entrypoint chooses what to run by testing whether the config *file* exists:

```sh
if [ -f "$CONFIG" ]; then start_forum ...; else nodebb install ...; fi
```

It never consults nconf. Measured directly: with `url`, `secret`, `database` and
the full mongo block all visible to nconf inside the container, NodeBB still
logged *"Launching web installer on port 4567"* and sat there waiting for a
browser.

Environment variables are still the right way to configure the **running**
forum — they just cannot get you past the first install.

## Two things worth knowing before you run it

### 1. `node_modules` is deliberately not a volume

Upstream's Dockerfile declares it:

```
VOLUME ["/usr/src/app/node_modules", "/usr/src/app/build", ...]
```

Docker then creates an anonymous volume from the image on first run — and on a
**later image update that stale volume shadows the new image's `node_modules`**.
Upgrade the image, and it silently keeps running the old dependencies and
plugins while everything reports success.

This image omits `node_modules` from the VOLUME list, so it comes from the image
and is correct by construction. **You do not need `--renew-anon-volumes`.**

If you are migrating from an image that did declare it, remove the old anonymous
volume once or you will keep the stale copy.

### 2. The container needs outbound network access

NodeBB's entrypoint (`install_dependencies()`) runs `npm install`
unconditionally on **every start**, so the container expects to reach the npm
registry at runtime. This is upstream behaviour and is not patched here —
maintaining a fork of the entrypoint across NodeBB releases costs more than it
saves.

Plan for it: give the NodeBB container an egress path. Its database containers
do not need one.

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

Baking at build time is preferred over NodeBB's `NODEBB_ADDITIONAL_PLUGINS`,
which npm-installs on every container start.

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
redis one. Measured: `sess:*` keys appear in Redis while config.json contains no
redis block at all.

So supply `redis__host` / `redis__port` / `redis__password` as **environment
variables** on the forum container. Removing them later on the assumption that
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
