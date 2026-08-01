# nodebb-docker

A maintained container image for [NodeBB](https://github.com/NodeBB/NodeBB),
built from source at a pinned release.

```
ghcr.io/xr09/nodebb-docker:4.14.4
```

## Tags

Derived from `ARG NODEBB_VERSION` in the Dockerfile:

| Tag | Moves |
|---|---|
| `4.14.4` | never — pin this in production |
| `4.14` | on patch releases |
| `4` | on minor releases |
| `latest` | every build |

Pin the exact version. Weekly rebuilds refresh the base image underneath a given
tag, so `latest` can change without any commit here.

## The image installs nothing at runtime

It replaces NodeBB's entrypoint: no `npm install` on boot, no runtime plugin
installs. Dependencies come from the image, and plugins are baked in with the
`PLUGINS` build-arg.

This breaks the admin panel's plugin **Install** and **Upgrade** buttons, and
`NODEBB_ADDITIONAL_PLUGINS` is refused rather than ignored. Enabling and disabling
plugins still works — that is database state, not files.

Upgrading from an older tag with plugins or a theme installed through the admin
panel needs a read of
[Migrating from the published image](docs/USAGE.md#migrating-from-the-published-image)
first. A theme that isn't in the image stops the container from booting.

## Trying it

[`compose.yaml`](compose.yaml) is a working stack — Mongo, a one-shot install
service, and the forum:

```bash
cp .env.example .env    # edit it, at minimum the passwords
docker compose up -d
```

## Documentation

Deployment, configuration, upgrades, and local builds:
**[docs/USAGE.md](docs/USAGE.md)**.

What NodeBB writes where, and why the image is shaped this way:
**[docs/NODEBB-IN-DOCKER.md](docs/NODEBB-IN-DOCKER.md)**.

Two other things that could trip people up: `node_modules` is deliberately not a
volume, and first-run install can't be done through environment variables alone —
both covered in the usage guide.

## License

MIT for the files in this repository. NodeBB itself is
[GPL-3.0](https://github.com/NodeBB/NodeBB/blob/master/LICENSE) and is fetched at
build time, not redistributed here in source form.
