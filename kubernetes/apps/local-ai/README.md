# local-ai (CUDA-accelerated LLM inference platform)

Self-hosted [LocalAI](https://localai.io) — an OpenAI-compatible LLM, image,
audio and agent platform (llama.cpp, diffusers, whisper, coqui, transformers,
vLLM backends) with a built-in web UI — running a **CUDA 13** build on the
GPU-capable worker `cluster-4`, following the standard app layout.

LocalAI is the intended **CUDA-based replacement for the
[llama-cpp](../llama-cpp/README.md) workload**. It runs in its own namespace
and **does not touch llama-cpp**: both share the single GPU on `cluster-4`, so
they cannot run at the same time (see [GPU cutover](#gpu-cutover)).

## Architecture

| Component      | Detail                                                                                                                                                                                                                                                                            |
| -------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Workload       | single-replica Deployment, `runtimeClassName: nvidia`, `strategy: Recreate`                                                                                                                                                                                                       |
| GPU            | 1x `nvidia.com/gpu` (RTX 2080Ti on `cluster-4`) via the [GPU Operator](../gpu-operator/README.md) device plugin                                                                                                                                                                   |
| Image          | `quay.io/go-skynet/local-ai:v4.12.1-gpu-nvidia-cuda-13` (pinned CUDA 13 build; Renovate tracks the version)                                                                                                                                                                       |
| Storage        | dynamic `truenas-iscsi` PVCs (RWO, single-writer): `local-ai-models` (200Gi → `/build/models`), `local-ai-images` (10Gi → `/tmp/generated/images`), `local-ai-data` (10Gi → `/data`), `local-ai-backends` (10Gi → `/backends`), `local-ai-configuration` (1Gi → `/configuration`) |
| Models         | installed at runtime via the web UI gallery, the `local-ai` CLI, or by dropping a GGUF + YAML config into the PVC                                                                                                                                                                 |
| Startup        | `LOCALAI_VRAM_WARM_LIMIT=0` — no remote gallery GGUF metadata probing at container startup (see [Startup](#startup))                                                                                                                                                              |
| Exposure       | `HTTPRoute` `local-ai.garage.neo-tix.com` → `envoy-external` gateway (API-key auth via `LOCALAI_API_KEY`)                                                                                                                                                                         |
| Traffic policy | route-scoped `BackendTrafficPolicy` disabling response compression (see [Pitfalls](#pitfalls))                                                                                                                                                                                    |
| Auth           | `LOCALAI_API_KEY` from SOPS-encrypted Secret `local-ai` (key `API_KEY`) — Bearer token required on API + web UI                                                                                                                                                                   |
| Probes         | startup `/readyz` (long budget), liveness `/healthz`, readiness `/readyz` (source-verified endpoints)                                                                                                                                                                             |

### Requesting the GPU

The classic extended-resource syntax, satisfied by the GPU Operator's
device plugin:

```yaml
resources:
    requests:
        nvidia.com/gpu: "1"
        memory: 8Gi
        cpu: "1"
    limits:
        nvidia.com/gpu: "1"
        memory: 24Gi
```

`runtimeClassName: nvidia` is required — the RuntimeClass is created by the
GPU Operator (see the [GPU Operator README](../gpu-operator/README.md)).

### CUDA 13 and the RTX 2080Ti

The `cluster-4` RTX 2080Ti is Turing (sm_75). CUDA 13's minimum supported
architecture is Turing (sm_75) — Maxwell/Pascal/Volta were dropped in
CUDA 13.0, but Turing is within the supported range — so the
`v4.12.1-gpu-nvidia-cuda-13` image runs on it with no `CUDA_DOCKER_ARCH`
override.

### Models

LocalAI manages models **dynamically** — there is no static preset file like
llama-cpp's `models.ini`. Models live in the models directory
(`/build/models` on the PVC), each as a GGUF (or other) file plus an optional
YAML config. Install one of three ways:

1. **Web UI → Models → Explore** — search the gallery and click **Install**.
   LocalAI auto-detects the GPU backend and downloads the right build.
2. **CLI** — `kubectl -n local-ai exec deploy/local-ai -- local-ai models
   install <name>` (or pass model names as container args).
3. **Manual** — copy a GGUF + a YAML config into the PVC's `/build/models`.

Example llama.cpp-style model config (drop as `<name>.yaml` next to the GGUF):

```yaml
name: my-model
parameters:
    model: llama.cpp-model.ggmlv3.q5_K_M.bin
context_size: 4096
threads: 1
f16: true
gpu_layers: 999 # offload every layer to the GPU
```

### Storage

LocalAI writes to several directories beyond the models path. Each is backed
by a dedicated `truenas-iscsi` PVC (`ReadWriteOnce`, single-writer — one pod
is the sole writer, matching the models volume). The mount paths mirror the
upstream `docker-compose.yaml` named volumes:

| PVC                      | Mount path              | Size  | Contents                                                    |
| ------------------------ | ----------------------- | ----- | ----------------------------------------------------------- |
| `local-ai-models`        | `/build/models`         | 200Gi | model weights + configs (LocalAI's models path)             |
| `local-ai-images`        | `/tmp/generated/images` | 10Gi  | images generated by the diffusion/image backends            |
| `local-ai-data`          | `/data`                 | 10Gi  | runtime data + caches (e.g. the remote VRAM-estimate cache) |
| `local-ai-backends`      | `/backends`             | 10Gi  | backend files installed at runtime                          |
| `local-ai-configuration` | `/configuration`        | 1Gi   | runtime-written model/agent configurations                  |

All PVCs expand on demand (`allowVolumeExpansion: true` on `truenas-iscsi`).

### Startup

`LOCALAI_VRAM_WARM_LIMIT=0` disables the background VRAM-estimate warm-up so
container startup does **not** probe remote gallery GGUF metadata (upstream
sets this same defensive default in its `docker-compose.yaml`). Remove the
override or set a positive limit to opt back into warming.

### Probes

The endpoints are source-verified (`core/http/routes/health.go`):

- `/healthz` — liveness, always 200 once the process is up. Deliberately
  independent of readiness so a long model preload never reads as a hung
  process (the pod is not restarted mid-download).
- `/readyz` — readiness, 503 while the startup preload is in progress, 200
  once serving.

The startup probe uses `/readyz` with a 10-minute budget (`failureThreshold:
60` × 10s) because the first boot downloads + loads the model from the PVC.

**Health endpoints are exempt from auth.** In `core/http/app.go`,
`routes.HealthRoutes(...)` is registered **before** `e.Use(authMiddleware)`,
so `/healthz` and `/readyz` do not require the Bearer token even with
`LOCALAI_API_KEY` set. This is why the kubelet probes work while the API and
web UI stay gated.

### Backend gallery (beellama)

LocalAI's built-in backend gallery (`DefaultBackendGalleriesJSON`) only lists
the upstream public backends. Our **beellama backend** (beellama.cpp with
KVarN KV-cache, published as a private image on GHCR) is not upstream, so the
deployment **extends** the gallery with a second one — the built-in gallery
is NOT replaced, only appended to:

- `LOCALAI_BACKEND_GALLERIES` — JSON list of gallery entries (`url` and
  `name` required). The `github:` URI
  `github:rafelbev/localai-beellama-backend/gallery.yaml@main` resolves to
  `raw.githubusercontent.com/rafelbev/localai-beellama-backend/main/gallery.yaml`,
  a file in the private backend repo.
- `LOCALAI_CREDENTIALS_FILE` — a YAML credentials file mounted from the
  `local-ai` Secret (key `CREDENTIALS_FILE`) at `/credentials/credentials.yaml`.
  Each entry has a `match` host (optionally with a path prefix) and exactly
  one of `basic`/`bearer`/`header` auth; parsing is strict (unknown fields
  make LocalAI exit). The entries use `bearer_env`, so the actual tokens live
  only in the Secret's `GITHUB_TOKEN` / `GHCR_TOKEN` keys — the mounted file
  contains no secret material:
  - `match: github.com/rafelbev` → `GITHUB_TOKEN` (fine-grained PAT) grants
    read access to the private gallery file. LocalAI maps
    `raw.githubusercontent.com/<org>` onto `github.com/<org>`, so one rule
    covers the raw host.
  - `match: ghcr.io` → `GHCR_TOKEN` grants read access to the private
    `ghcr.io/rafelbev/localai-beellama-backend` image when LocalAI pulls it
    as a backend.

**Adding a backend to the gallery in the future:** add a `GalleryBackend`
entry to `gallery.yaml` in the backend repo (fields: `name`, `description`,
`uri`, `alias`, `tags`, `version`), push, and bump the image tag in the
`uri` field. If the backend is served from a new private host, add a
credentials entry for that host in the Secret's `CREDENTIALS_FILE` key
(re-encrypt with sops) and add the matching env key to the deployment.

## GPU cutover

`cluster-4` has a **single GPU**. llama-cpp currently holds
`nvidia.com/gpu: 1`, so this pod is **Pending (unschedulable)** while
llama-cpp runs — and llama-cpp is undisturbed. The cutover is a deliberate,
manual step:

1. Let LocalAI schedule once the GPU is free (below).
2. Scale llama-cpp to 0 (keep its PVC for rollback):
   `kubectl -n llama-cpp scale deploy/llama-cpp --replicas=0`.
3. The LocalAI pod schedules and takes the GPU. Install models and test.
4. Once satisfied, delete the llama-cpp app (keep its PVC for rollback).

Do **not** delete llama-cpp's PVC until LocalAI is verified working.

## Verification

```bash
kubectl -n local-ai get pods -o wide            # scheduled on cluster-4 (once the GPU is free)
# health is public (exempt from auth):
curl -fsS https://local-ai.garage.neo-tix.com/healthz
# API requires the Bearer key (from the SOPS secret):
curl -fsS -H "Authorization: Bearer ***" https://local-ai.garage.neo-tix.com/v1/models
# without a key (should 401):
curl -fsS https://local-ai.garage.neo-tix.com/v1/models
# GPU in use:
talosctl --nodes 172.20.17.197 dmesg | grep -i nvidia   # or nvidia-smi via a debug container
```

## Pitfalls

- **GPU contention is by design.** One GPU on `cluster-4`; llama-cpp and
  LocalAI cannot both hold it. LocalAI stays Pending until llama-cpp is
  decommissioned — this is the staging/cutover plan, not a bug.
- **CUDA 13 supports the 2080Ti (Turing, sm_75).** No arch override needed.
- **Liveness must be `/healthz`, not `/readyz`.** Using `/readyz` for
  liveness would restart the pod mid-download during the long model preload.
- **Health endpoints are auth-exempt** (registered before the auth
  middleware in `app.go`), so probes work without a Bearer token.
- **Envoy response compression:** the global `BackendTrafficPolicy/envoy`
  (in `network`) sets Zstd/Brotli/Gzip compressors on every route and strips
  the client's `Accept-Encoding` from upstream requests, which breaks web-UI
  asset loading. The route-scoped policy omits the `compressor` field and
  repeats the global retry/keepalive/timeout settings (the disabled
  `requestTimeout` is required for long generations).
- **`strategy: Recreate`** avoids a surge mounting the RWO iSCSI PVC (or
  running two copies of a large model on one GPU) at once.
- **Memory is tunable.** The 8Gi request / 24Gi limit is a starting point for a
  large GPU model; raise the limit if a larger model + KV cache needs it.
- **Keep the models PVC headroom:** a 27B GGUF + drafter can be several GB;
  check free space before adding large models.
- **Authelia bypass:** like `llama-cpp`, `headscale`, `litellm` and
  `llama-cpp`, this route gates itself with its own API key and is included in
  the Authelia bypass whitelist — Authelia's 2FA does not stack on top of it.
