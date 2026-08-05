# How NodeBB behaves in a container

Reference for the mechanisms behind this image's design: what NodeBB writes and
when, which of its features need the filesystem versus the database, and what
upstream's container setup does differently. For how to deploy and configure the
image, see [USAGE.md](USAGE.md).

Observations were made against NodeBB 4.14.4; the image may ship a later patch.
Citations name files and functions rather than line numbers so they survive that.

- [What NodeBB writes at runtime](#what-nodebb-writes-at-runtime)
- [Plugins: install vs activate](#plugins-install-vs-activate)
- [Themes: why they are not plugins](#themes-why-they-are-not-plugins)
- [Boot and upgrade paths](#boot-and-upgrade-paths)
- [What this image's entrypoint does](#what-this-images-entrypoint-does)
- [What upstream's entrypoint does](#what-upstreams-entrypoint-does)
- [What is not file-backed](#what-is-not-file-backed)

## What NodeBB writes at runtime

Three volumes cover everything that matters: `/opt/config`,
`/usr/src/app/public/uploads`, `/usr/src/app/build`.

| Path | Written when | Persisted | If lost |
|---|---|---|---|
| `public/uploads/files/` | Post attachments, composer uploads, group covers | volume | User data |
| `public/uploads/profile/uid-<n>/` | Avatar and profile cover uploads | volume | User data |
| `public/uploads/category/` | Category images and icons | volume | Admin data |
| `public/uploads/system/` | Favicon, touch icons, site logo, og:image, screenshot | volume | Branding, mostly unrecoverable |
| `build/public/` | `nodebb build`, ACP "Rebuild & Restart" | volume | Regenerable |
| `build/public/client-<skin>.css` | An HTTP request for that skin | volume | Regenerable |
| `build/public/templates/emails/` | Emailer init, saving email settings | volume | Regenerable |
| `build/export/` | GDPR data exports, admin user CSV | volume | Pending downloads break |
| `/opt/config/config.json` | First install; some upgrade scripts | volume | Database credentials |
| `/opt/config/install_hash.md5` | This image's upgrade gate | volume | Forces one extra upgrade |
| `os.tmpdir()` | Every multipart upload, base64 image staging | no | Nothing, deleted after use |
| `logs/output.log` | Created every start | no | Nothing, see below |

Uploads go through `file.saveFileToLocal()` in `src/file.js`. Branding assets are
written by `src/controllers/admin/uploads.js`. Temp files come from
`src/middleware/multer.js`, which calls `multer.diskStorage({})` with no
`destination`, so multer falls back to the OS temp directory, and from
`src/image.js` for base64 staging.

One branding asset does not regenerate: `system/site-logo-x50.png`, the
email-safe logo. `src/meta/configs.js` only checks whether it exists and warns
`please re-upload your site logo` if not.

### build/ is written on ordinary requests

Not only by a build. `middleware.buildSkinAsset()` in `src/middleware/index.js`
calls `meta.css.buildBundle()` when someone requests a skin that has not been
compiled yet, writing `client-<skin>.css` during the request. `src/emailer.js`
compiles custom email templates in `buildCustomTemplates()`, which runs at emailer
init and again whenever email settings are saved. `build/export/` holds GDPR
exports and the admin user CSV until they are downloaded.

So `build/` is regenerable but must stay writable. It cannot be mounted
read-only, and it is not a candidate for dropping from the volume list.

### public/ is otherwise read-only

`public/src`, `public/language` and `public/scss` are compilation *sources*,
copied into `build/`. Nothing writes to them at runtime.

The only exception is the first-run web installer, which writes
`public/installer.css` and `public/bootstrap.min.css` and unlinks both once setup
finishes (`install/web.js`). Everything a running forum writes under `public/`
goes to `uploads/`.

### Use named volumes, not bind mounts

For the three data paths this image supports named volumes only, and it runs as a
fixed UID 1001 that cannot be overridden at build time. The two facts are the same
fact: a named volume takes its contents *and its ownership* from the image, so
there is nothing for a configurable UID to align with.

`USER` is set numerically rather than by name, so Kubernetes can enforce
`runAsNonRoot` without resolving `/etc/passwd` inside the image.

A bind mount keeps whatever the host directory already has, which breaks in two
ways. Ownership is the host's, so the container cannot write and the entrypoint
exits with `No write permission for /opt/config`. And content is the host's, so
the `public/uploads/{category,files,profile,sounds,system}` directories NodeBB
ships never appear — a named volume seeds them, a bind mount does not.

Most uploads survive the second problem because `file.saveFileToLocal()` creates
the parent directory first. `copyFavicon()` in `src/install.js` does not: it fails
with an ENOENT that is only logged, and the default favicon is silently absent.

Read-only bind mounts are unaffected and perfectly fine — `compose.yaml` uses one
to supply `setup.sh`.

### Logs

`loader.js` computes `logs/output.log`, creates the directory, and opens a
rotating stream — unconditionally, on every start. Content is only written when
`silent` is on; this image runs with `--no-silent`, so NodeBB logs to stdout and
the file stays empty. Use `docker logs`. The ACP log viewer reads that file and
therefore shows nothing.

## Plugins: install vs activate

These are separate operations with nothing in common, and the difference is what
makes a read-only `node_modules` workable.

**Installing** shells out to npm. `runPackageManagerCommand()` in
`src/plugins/install.js` runs `npm install <pkg>@<version> --save --ignore-scripts`,
which writes `package.json`, the lockfile, and `node_modules`. It needs a package
manager, network access, and a writable tree.

**Activating** is one database write. `Plugins.toggleActive()` adds or removes the
plugin id in a sorted set:

```js
await db.sortedSetAdd('plugins:active', count, id);
```

The score is load order. No filesystem access beyond reading `plugin.json` to
check whether the plugin is a system plugin. Every other writer agrees — the CLI's
`activate` command, the ACP's drag-to-reorder, first-time setup, and theme
switching all target that same sorted set.

So against a baked image: enabling, disabling and reordering plugins work
normally, and so does switching between baked themes. Only the Install, Uninstall
and Upgrade buttons break, because only those call npm.

Two details worth knowing:

- `Plugins.toggleInstall()` deactivates the plugin in the database *before*
  running npm. A failed install therefore leaves it deactivated.
- The install path publishes over pubsub, so in a cluster every node runs npm.

A plugin marked active in the database but missing from disk is not fatal.
`Data.getPluginPaths()` in `src/plugins/data.js` logs
`"<id>" is active but not installed.` and filters it out; the forum starts.
Re-adding the plugin to a later image brings it back already enabled, since the
activation was never lost.

## Themes: why they are not plugins

A missing theme is fatal where a missing plugin is a warning.

`Themes.get()` discovers themes by scanning `themes_path`, which defaults to
`node_modules`. A theme installed through the ACP under a mutable image lives
only in that tree, so a rebuilt image cannot see it. `Themes.setupPaths()` then
throws:

```js
const themeId = data.currentThemeId || 'nodebb-theme-harmony';
// …
const themeObj = data.themesData.find(themeObj => themeObj.id === themeId);

if (!themeObj) {
    throw new Error('theme-not-found');
}
```

That propagates out of `src/webserver.js` and exits through `src/start.js`. The
container does not start, and nothing in the log names the theme — which is why
this image's entrypoint prints the baked list on every boot.

The `nodebb-theme-harmony` fallback in that snippet applies only when `theme:id`
is unset. A theme that is set but missing does not fall back to it. `Themes.setPath()`
can also throw `theme-missing-templates` when the theme exists but its templates
directory does not.

NodeBB bundles four themes, so every build of this image contains `harmony`,
`lavender`, `peace` and `persona`. Anything else has to be baked in via `PLUGINS`.
Recovery from a forum pointing at an absent theme is `nodebb reset -t`, which
resets it to the default.

## Boot and upgrade paths

A normal start touches no package manager and needs no network. `npm start` runs
`loader.js`, which forks `app.js`, which calls `src/start.js`: database, config,
schema check, session store, sockets, cron, web server. The only package file
`loader.js` reads is `package.json`, for a version string.

`meta.dependencies.check()` scans `node_modules` against `package.json`. A missing
*plugin* is excused — `src/meta/dependencies.js` matches the plugin name pattern
and warns `Bundled plugin <name> not found, skipping dependency check` — while a
missing core dependency throws `dependencies-missing` and stops the boot.

### Upgrade flags

`nodebb upgrade` takes five flags, and its own help text states the rule:

> By default all options are enabled. Passing any options disables that default.

| Flag | Step | Does |
|---|---|---|
| `-m` | package | Rewrites `package.json` from defaults |
| `-i` | install | Runs `npm install` |
| `-p` | plugins | Checks the registry for plugin updates, npm-installs them |
| `-s` | schema | Migrates the database |
| `-b` | build | Recompiles assets |

Only `-s` and `-b` act on persistent state; the first three act on the tree the
image already provides. A bare `nodebb upgrade` enables all five, which is how an
image that installs nothing at runtime ends up installing at runtime anyway — one
layer down, inside NodeBB rather than the entrypoint. This image passes `-s -b`.

### Two behaviours that surprise people

**Any `./nodebb` command runs a package-manager preflight first.** Before
dispatching, `src/cli/index.js` version-checks seven bootstrap packages (`nconf`,
`async`, `commander`, `chalk`, `lodash`, `lru-cache`, `@xmldom/xmldom`) against
`install/package.json`. On any mismatch it calls `updatePackageFile()`,
`preserveExtraneousPlugins()` and `installAll()` — writing `package.json` and
shelling out to npm. This sits in front of `nodebb upgrade`, so it is on the boot
path whenever the image version moves. It stays a no-op only because the build
copies `install/package.json` to `package.json` and installs from that same file,
making the versions agree by construction. `loader.js` and `app.js` have no such
preflight, which is why the forum itself is started with `npm start`.

**`nodebb upgrade` exits 0 when a step fails.** A database that is unset or
unreachable logs `Database type not set!`, the schema step never runs, and the
process still returns 0. Any caller checking the exit code concludes it worked.
This image gates on the completion banner that `runSteps()` prints only after
every step returned.

### Network at runtime

Nothing at boot needs egress. Two things at runtime do:

- `/admin/extend/plugins` calls `plugins.listTrending()` against
  `packages.nodebb.org` inside a `Promise.all`, and unlike the two calls beside it
  that one is not wrapped in a try/catch. Without egress the whole route returns a
  500 while the forum itself is fine.
- A daily cron POSTs plugin usage data. It is wrapped and gated on a config
  setting, so it fails harmlessly.

## What this image's entrypoint does

`entrypoint.sh` in this repo, in order. It replaces upstream's script rather than
wrapping it, and there is no fallback to it.

1. Refuse `NODEBB_ADDITIONAL_PLUGINS` if set, with a non-zero exit. Its only job
   is to npm-install at runtime; ignoring it silently would start a forum missing
   plugins somebody asked for.
2. Create the config directory and fail if it is not writable.
3. List the themes baked into the image, because a missing one is fatal and
   nothing else in the log would name it.
4. If `config.json` does not exist, hand off to `nodebb install` — the web
   installer. This is the end of a clean first run; see
   [What doesn't work](USAGE.md#what-doesnt-work) for why the config file, not
   the environment, is what decides this.
5. Otherwise compare the md5 of `install/package.json` against
   `/opt/config/install_hash.md5`. On a difference run `nodebb upgrade -s -b`,
   then record the hash. Otherwise build only if `START_BUILD` is set.
6. `exec npm start`.

### Environment variables

| Variable | Default | Effect |
|---|---|---|
| `CONFIG_DIR` | `/opt/config` | Where `config.json` and the upgrade hash live |
| `CONFIG` | `$CONFIG_DIR/config.json` | Config file path. Honoured, unlike upstream, which overwrites it |
| `NODEBB_INIT_VERB` | `install` | Subcommand used when no config file exists |
| `NODEBB_BUILD_VERB` | `build` | Subcommand used by `START_BUILD` |
| `START_BUILD` | `false` | Rebuild assets on a start that is not an upgrade. `FORCE_BUILD_BEFORE_START` is accepted as an alias |
| `NODEBB_ADDITIONAL_PLUGINS` | — | Refused with an error. Bake plugins in with the `PLUGINS` build-arg |
| `SETUP` | — | Not implemented. It never worked; see [What doesn't work](USAGE.md#what-doesnt-work) |

### Why the upgrade gate hashes install/package.json

`install/package.json` is NodeBB's own dependency manifest, baked into the image.
It can only change when the image does, which is exactly when `nodebb upgrade`
needs to run its schema migrations — so the hash is a proxy for "the NodeBB
version moved" and nothing else.

Upstream uses the same gate, but reaches that file through the symlink
`copy_or_link_files()` creates onto the config volume, which makes it mutable at
runtime and the gate correspondingly unreliable. Here nothing rewrites it.

The upgrade runs with `-s -b` only, for the reasons in
[Upgrade flags](#upgrade-flags), and its success is judged by the completion
banner rather than the exit code, for the reason in
[Two behaviours that surprise people](#two-behaviours-that-surprise-people).

### Readiness probe

The image's `HEALTHCHECK` requests `/api/v3/ping`, answered by
`Utilities.ping.get` in `src/controllers/write/utilities.js`:

```json
{"status":{"code":"ok","message":"OK"},"response":{"pong":true}}
```

The handler returns a literal `{pong: true}`; the envelope around it comes from
`helpers.formatApiResponse`. The probe only tests for a 200, so the body does not
matter — what matters is that the route takes no authentication and touches no
database, so it reports whether the web server is answering and nothing else.

It runs through `node`, because the slim base image has no `curl`, `wget` or `nc`.
The URL is hardcoded to `127.0.0.1:4567`; the container's listen port is pinned
there, and only the host side of a port mapping ever moves.

### Signal handling

The last line is `exec npm start`, where upstream uses a plain
`npm start ... || exit 1`. `tini` runs as PID 1, so `exec` makes npm its direct
child and a `SIGTERM` from `docker stop` reaches NodeBB. Without it the signal
would land on a bash frame that does not forward it, and every stop would wait
out the timeout and then kill the forum.

## What upstream's entrypoint does

`install/docker/entrypoint.sh` in the NodeBB repo, in order. This image does not
use it, and does not ship it on `PATH`.

1. `set_defaults()` — reads `CONFIG_DIR`, `CONFIG`, `NODEBB_INIT_VERB`,
   `NODEBB_BUILD_VERB`, `START_BUILD` / `FORCE_BUILD_BEFORE_START`, `SETUP`,
   `PACKAGE_MANAGER`, `OVERRIDE_UPDATE_LOCK`, `NODEBB_ADDITIONAL_PLUGINS`. Note
   `CONFIG` is overwritten to `$CONFIG_DIR/config.json`, so setting it has no
   effect.
2. `check_directory()` — creates the config dir, then tries to chown and chmod it.
3. `copy_or_link_files()` — copies `package.json` and the lockfile into the config
   volume, deletes the lockfiles in the app directory, and symlinks both back. This
   is what makes the persisted `package.json` the source of truth.
4. `install_dependencies()` — `npm install`, unconditionally, on every start.
5. `install_additional_plugins()` — npm-installs each name in
   `NODEBB_ADDITIONAL_PLUGINS` and forces a rebuild.
6. `build_forum()` — compares the md5 of `install/package.json` against a stored
   hash and runs a bare `nodebb upgrade` when they differ.
7. `start_forum()` — `npm start`.

Upstream's Dockerfile also declares `node_modules` in its `VOLUME` list:

```
VOLUME ["/usr/src/app/node_modules", "/usr/src/app/build", "/usr/src/app/public/uploads", "/opt/config/"]
```

Coherent for a mutable forum where admins install plugins through the ACP. It is
the wrong model for an image that bakes its plugin set in, because the persisted
`package.json` shadows the image's and the boot `npm install` prunes anything the
image added that the older file does not list. See
[Nothing is installed at runtime](USAGE.md#nothing-is-installed-at-runtime).

### OVERRIDE_UPDATE_LOCK does not make the image authoritative

It reads like the fix — force the image's `package.json` over the volume's — and
it crash-loops the container. `copy_or_link_files()` ends by symlinking source
onto destination, so from the second start its seeding `cp` copies a file onto
itself, fails, and `set -e` exits 1. A fresh container filesystem works, so it
survives the deploy that introduces it and breaks on the next plain restart or
host reboot.

## What is not file-backed

Sessions, caches and search hold nothing on disk, so replacing a container or
running several loses nothing.

**Sessions** go to the database. `src/webserver.js` passes `db.sessionStore`,
built in `src/database/index.js` from `connect-mongo`, `connect-redis` or
`connect-pg-simple` depending on configuration. There is no memory or file store
in the tree.

**Caches** are in-process LRU objects, rebuilt on start. `build/cache-buster` is
an asset-versioning string, not a cache; if it is missing NodeBB warns and uses a
random value.

**Search** has no on-disk index. The ACP's own search reads template files at
request time to build an in-memory index, and full-text search over posts is
delegated to plugins that store their index in the database.
