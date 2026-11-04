# Apache Tika

Self-hosted [Apache Tika Server](https://tika.apache.org/) — a REST API for
content detection and metadata extraction from documents. Exposed at
`tika.garage.neo-tix.com`.

Based on the upstream Docker Compose sample (`apache/tika:latest-full`,
port 9998), adapted to this repo's Flux + SOPS conventions.

## Architecture

Single stateless pod, no PVC. The `-full` image variant ships the external
parsers the minimal image lacks: Tesseract OCR (with `eng`, `ita`, `fra`,
`spa`, `deu`, `jpn` language packs), GDAL, ImageMagick, ffmpeg, and font
sets — i.e. it can OCR scanned documents and parse geospatial rasters and
media.

| Component    | Value                                                                     |
| ------------ | ------------------------------------------------------------------------- |
| Image        | `apache/tika:4.2.0-1-full` (immutable build tag)                          |
| Port         | 9998 (REST server)                                                        |
| Process user | UID/GID `35002:35002` (non-root, per the image)                           |
| Memory       | 2Gi limit — the JVM sizes its heap from the limit                         |
| Health check | `GET /tika` → 200 ("This is Tika Server (Apache Tika 4.2.0). Please PUT") |

### Image tag

The upstream docs pin production to the **immutable** tag form
`<version>-<N>`: `4.2.0-1-full` is exactly what `latest-full` currently
points to (verified via the Docker Hub tags API — same digest date and
size). Renovate tracks the immutable tag; a plain `:latest-full` would be a
floating tag.

### Memory sizing

Tika's JVM sizes its heap from the container memory limit (do **not** pass
`-Xmx`). Tika Pipes forks additional JVMs inside the same container, and each
fork's heap also comes out of that limit — the 2Gi limit is sized for the
forks, not just the parent process.

## Authentication

Tika Server performs **no authentication** of its own (the image logs a
warning about this at startup). All access is gated by **Authelia 2FA** via
the `authelia-extauthz-tika` SecurityPolicy on the `tika-auth` HTTPRoute
(`failOpen: false`), following the standard per-app ext-authz pattern. Tika
is **not** in the Authelia bypass whitelist — LAN (`172.20.0.0/16`) and
headscale (`100.64.0.0/10`) sources bypass Authelia as usual, everything
else must authenticate.

## Using the API

```bash
# Extract text / metadata from a document
curl -T document.pdf https://tika.garage.neo-tix.com/tika

# Get just the metadata
curl -T document.pdf https://tika.garage.neo-tix.com/meta

# Content-type detection only
curl -T document.bin https://tika.garage.neo-tix.com/detect
```

From inside the cluster, call the service directly:
`http://tika.tika.svc.cluster.local:80`.

## Pitfalls

- **The probe path is `/tika`, not `/tika/status`.** `GET /tika` returns 200
  with the server version string; `/tika/status` and `/tika/health` do not
  exist in the 4.2.0 image (both 404 — verified against a live container).
- **`GET /tika` with no body is a 200** ("This is Tika Server ... Please
  PUT") — extraction is a `PUT`/`POST` with a document body.
- **The full image is ~600MB compressed** (2GB unpacked) vs ~190MB for the
  minimal variant — expect a longer pull.
- **No `tika-config.json` is mounted.** The server runs with built-in
  defaults (all parsers enabled). To tune (e.g. disable OCR, add presets),
  mount a config file and add `-c /tika-config.json` to the container
  command — see the upstream [Docker docs](https://tika.apache.org/docs/4.2.x/using-tika/docker.html).
