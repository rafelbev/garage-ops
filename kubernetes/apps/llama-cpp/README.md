# llama-cpp (GPU-accelerated LLM inference)

Self-hosted LLM inference server running
[llama-server](https://github.com/ggml-org/llama.cpp) from the
`ghcr.io/ggml-org/llama.cpp:full-cuda` image on the GPU-capable worker
`cluster-4`, following the standard app layout.

## Architecture

| Component      | Detail                                                                                                                                |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| Workload       | single-replica Deployment, `runtimeClassName: nvidia`                                                                                 |
| GPU            | 1x `nvidia.com/gpu` (RTX 2080Ti on `cluster-4`) via the [GPU Operator](../gpu-operator/README.md) device plugin                       |
| Model config   | ConfigMap `llama-cpp-models` (`models.ini`) mounted at `/config/models.ini`, consumed via `--models-preset`                           |
| Model storage  | static NFS PV `models-pv` (4Ti, TrueNAS `/mnt/storage/models`) mounted at `/root/.cache/huggingface` — the HuggingFace download cache |
| Exposure       | `HTTPRoute` `llama-cpp.garage.neo-tix.com` → `envoy-external` gateway (plain pass-through, no auth annotations)                       |
| Traffic policy | route-scoped `BackendTrafficPolicy` disabling response compression (see pitfall below)                                                |

### Requesting the GPU

The classic extended-resource syntax, satisfied by the GPU Operator's
time-sliced device plugin:

```yaml
resources:
    requests:
        nvidia.com/gpu: "1"
        memory: 8Gi
        cpu: "1"
    limits:
        nvidia.com/gpu: "1"
        memory: 22Gi
```

`runtimeClassName: nvidia` is required — the RuntimeClass is created by the
GPU Operator (see the [GPU Operator README](../gpu-operator/README.md)).

### Resource tuning (why 8Gi/22Gi)

The preset loads a ~27B GGUF (`ukisai/Swift-1.5-Qwen3.5-27B-GSQ-RCO`,
IQ3_XXS + MTP draft) with a 256k-token context and q8_0/q4_0 KV cache
checkpoints. Weight + KV host memory comfortably exceeds the initial
1Gi/4Gi guess, so the deployment was tuned live to
**8Gi request / 22Gi limit** and that is what is encoded in
`deployment.yaml`. The startup probe gets a 10-minute budget
(`failureThreshold: 60` x 10s) because the first model load from NFS is
slow.

### Model presets

`models.ini` is a standard INI preset file (`--models-preset`):

- `[*]` section: shared defaults (threads, flash-attn, mmap, KV cache
  types, sampling).
- One section per model, keyed by the HuggingFace repo id
  (`hf-repo`). On first boot llama-server downloads the repo into the
  mounted HuggingFace cache (`/root/.cache/huggingface` on the NFS PVC),
  so models persist across pod restarts and the PVC only grows.
- `load-on-startup: true` autoloading is controlled per model
  (`--models-autoload`, `--models-max 1`).

To add a model: add a section to the ConfigMap and push — Flux redeploys
the pod, which downloads the new repo into the cache on start.

## Verification

```bash
kubectl -n llama-cpp get pods -o wide          # scheduled on cluster-4
curl -fsS https://llama-cpp.garage.neo-tix.com/health
talosctl --nodes 172.20.17.197 dmesg | grep -i nvidia   # or nvidia-smi via debug container
```

## Pitfalls

- **SSA null-unset for the Recreate strategy:** switching
  `spec.strategy.type` to `Recreate` fails the Flux dry-run with
  `spec.strategy.rollingUpdate: Forbidden: may not be specified when
  strategy 'type' is 'Recreate'` — the API server had defaulted
  `rollingUpdate` (25%/25%) into the stored Deployment when it was
  created under the default `RollingUpdate` strategy. The manifest sets
  `rollingUpdate: null`, but **Flux's two-way strategic-merge patch
  computation drops nil fields**, so the manifest alone cannot remove
  the server-defaulted value from an _existing_ object (a plain
  `kubectl apply --server-side --dry-run` of the same manifest passes —
  only Flux's diff-based patch fails). The defaulted field must be
  removed from the live Deployment once:
  `kubectl -n llama-cpp patch deploy llama-cpp --type merge
  -p '{"spec":{"strategy":{"rollingUpdate":null}}}'`. With a clean live
  object, Flux's dry-run passes and SSA keeps the field unset.
- **Envoy response compression breaks the llama.cpp web UI:** the global
  `BackendTrafficPolicy/envoy` (in `network`) sets Zstd/Brotli/Gzip
  compressors on every route; Envoy's compression filter strips the
  client's `Accept-Encoding` from upstream requests, and llama-server
  (full-cuda image) **requires** `Accept-Encoding: gzip` to serve its
  built-in web UI — every web UI asset then responds
  `415 "Error: gzip is not supported by this browser"` while `/health`
  and `/models` (no gzip check) keep working. Port-forwarding the pod
  works because the browser's header reaches the server unmodified.
  Fix: `backendtrafficpolicy.yaml` — a route-scoped policy fully
  replaces the global one, so it repeats the global retry/keepalive/
  timeout settings (the disabled `requestTimeout` is required for long
  generations) and omits the `compressor` field.
- **A crash-looping `envoy-gateway` controller makes every new HTTPRoute
  look broken.** The controller pod stops writing route status
  (`Accepted`/`ResolvedRefs`) and new routes are silently not attached to
  any listener, while the data plane keeps serving the routes it already
  has. Symptom: `kubectl -n llama-cpp get httproute -o yaml` shows **no
  `status` at all**. Check `kubectl -n network get pods` — if
  `envoy-gateway` is in `CrashLoopBackOff` (here: a stale pod whose
  network namespace could no longer reach the API server,
  `dial tcp <svc-ip>:443: i/o timeout`), delete the pod; the replacement
  reconciles all routes within seconds.
- **Live-tuned values must be encoded in the manifest.** A live
  `kubectl patch` of the Deployment (the 8Gi/22Gi memory tuning) is
  reverted by Flux on the next reconciliation; the working values live in
  `deployment.yaml` now.
- **The test `GitRepository/llama-cpp` in `flux-system` was applied
  directly to the cluster** (no manifest in this repo) so this branch
  could be tested against the live cluster. The Kustomization now points
  at the standard `flux-system` source; delete the test GitRepository
  after this PR merges.
- **Keep the models PVC headroom:** it is a 4Ti RWX NFS volume shared by
  every GGUF downloaded; check free space before adding large models.
