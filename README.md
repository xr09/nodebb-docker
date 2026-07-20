# nodebb-docker

A maintained container image for [NodeBB](https://github.com/NodeBB/NodeBB),
built from source at a pinned release.

```
ghcr.io/xr09/nodebb-docker:4.14.0
```

## Why this exists

The published NodeBB images are years stale:

| Image | Newest | |
|---|---|---|
| `nodebb/docker` (Docker Hub) | 1.19.12 | July **2023** |
| `ghcr.io/nodebb/nodebb` | date tags | mid-**2024** |
| NodeBB releases | 4.14.0 | July 2026 |

This image tracks current releases and is deliberately **site-agnostic** — no
forum-specific configuration, no baked plugin list.

## Tags

Derived from `ARG NODEBB_VERSION` in the Dockerfile:

| Tag | Moves |
|---|---|
| `4.14.0` | never — pin this in production |
| `4.14` | on patch releases |
| `4` | on minor releases |
| `latest` | every build |

Pin the exact version. Weekly rebuilds refresh the base image underneath a given
tag, so `latest` can change without any commit here.

## Documentation

Deployment, configuration, upgrades, and local builds: **[docs/USAGE.md](docs/USAGE.md)**.

Two things that trip people up: `node_modules` is deliberately not a volume, and
first-run install can't be done through environment variables alone — both
covered there.

## License

MIT for the files in this repository. NodeBB itself is
[GPL-3.0](https://github.com/NodeBB/NodeBB/blob/master/LICENSE) and is fetched at
build time, not redistributed here in source form.
