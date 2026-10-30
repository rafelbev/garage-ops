# llama-cpp (GPU-accelerated LLM inference)

Self-hosted LLM inference server running
[llama-server](https://github.com/Anbeeld/beellama.cpp) from the
`ghcr.io/anbeeld/beellama.cpp:server-cuda13-v0.4.9` image (a CUDA 13.3
build of [beelama.cpp](https://github.com/Anbeeld/beellama.cpp), a fork of
llama.cpp with DFlash2/KVarN support) on the GPU-capable worker
`cluster-4`, following the standard app layout.

## Architecture

| Component      | Detail                                                                                                                                |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| Workload       | single-replica Deployment, `runtimeClassName: nvidia`                                                                                 |
| GPU            | 1x `nvidia.com/gpu` (RTX 2080Ti on `cluster-4`) via the [GPU Operator](../gpu-operator/README.md) device plugin                       |
| Model config   | ConfigMap `llama-cpp-models` (`models.ini`) mounted at `/config/models.ini`, consumed via `--models-preset`                           |
| Model storage  | static NFS PV `models-pv` (4Ti, TrueNAS `/mnt/storage/models`) mounted at `/root/.cache/huggingface` — the HuggingFace download cache |
| Exposure       | `HTTPRoute` `llama-cpp.garage.neo-tix.com` → `envoy-external` gateway (API-key auth via `--api-key`)                                  |
| Traffic policy | route-scoped `BackendTrafficPolicy` disabling response compression (see pitfall below)                                                |
| Auth           | `--api-key` from SOPS-encrypted Secret `llama-cpp` (key `API_KEY`) — requires `Authorization: Bearer *** header on all endpoints      |

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

The default model is a ~27B GGUF — `ConwayResearch/Underdog-Saluki-27B-1.0`
(IQ2-mix, 7.89 GB) — with a 256k-token context and q4_0/q4_0 KV cache. The
prior default was `ukisai/Swift-1.5-Qwen3.8-27B-GSQ-RCO` (IQ3_XXS + MTP
draft, ~10.4 GB); Saluki is ~2.5 GB smaller, so it leaves more VRAM headroom
for the KV cache. Weight + KV host memory comfortably exceeds the initial
1Gi/4Gi guess, so the deployment is tuned to **8Gi request / 22Gi limit**
(encoded in `deployment.yaml`). The startup probe gets a 10-minute budget
(`failureThreshold: 60` x 10s) because the first model load from NFS is
slow — the prefetch Job (below) removes the download from that window.

### Model presets

`models.ini` is a standard INI preset file (`--models-preset`):

- `[*]` section: shared defaults (threads, flash-attn, mmap, KV cache
  types, sampling).
- One section per model, keyed by the HuggingFace repo id
  (`hf-repo`). On first boot llama-server downloads the repo into the
  mounted HuggingFace cache (`/root/.cache/huggingface` on the NFS PVC),
  so models persist across pod restarts and the PVC only grows. The
  built-in `--hf-repo`/`--hf-file` download is used (no manual `hf-cli`);
  `--hf-file` pins the exact GGUF, and the `mmproj` vision add-on is
  downloaded automatically when present in the repo.
- `load-on-startup: true` autoloading is controlled per model
  (`--models-autoload`, `--models-max 1`) — exactly one model loads at
  startup; the rest are on-demand via the router.

The default model is `ConwayResearch/Underdog-Saluki-27B-1.0` (IQ2-mix).
Tuning notes:

- **DFlash2 speculative decoding.** The Saluki preset enables `draft-dflash`
  via a separate drafter repo (`z-lab/Qwen3.8-27B-DFlash2-GGUF`, `Q4_K_M`,
  1.14 GB) pointed at by `hf-repo-draft`. The drafter is NOT in the Saluki
  repo, so the preset must name it explicitly. `spec-draft-n-max = 4` and
  `spec-draft-ngl = all` keep the drafter fully on GPU. This requires a
  llama.cpp build with the DFlash2 spec-type merged (PR #27342, 2026-08);
  beelama.cpp ships DFlash2 as a core feature, so the
  `server-cuda13-v0.4.9` build satisfies that.
- **Vision retained.** The repo ships `mmproj-...-Q8_0.gguf` / `-F16.gguf`;
  the server auto-downloads and loads it, so image inputs work through the
  OpenAI chat API with no extra flags.
- **Context 256k, q4_0/q4_0 KV.** Saluki's 7.89 GB weights leave ~2.5 GB more
  VRAM headroom than the ~10.4 GB Qwen default, so the same 256k context the
  Qwen preset used fits with room to spare (q4_0/q4_0 keeps the KV within the
  22Gi host limit). The DFlash2 drafter adds ~1.7 GiB (model + KV + compute),
  which still fits within the 22Gi limit.
- **Sampling for agentic/coding:** `temp 0.6`, `top-p 0.95`, `top-k 20`,
  `min-p 0.05` (a small safety net that drops near-zero-probability tokens).
- **Reasoning:** thinking stays ON (`reasoning = on`, `reasoning-format
  auto`, `reasoning-preserve`) at `reasoning_effort: low` — the least effort
  that still retains quality for a 2-bit quant. `parallel_tool_calls: true`
  is kept because Saluki is specifically tuned for parallel tool calls.

To add a model: add a section to the ConfigMap, run the prefetch Job (below),
and push — Flux redeploys the pod, which loads the new model from the cache.

### Prefetching models (first-boot warm-up)

`prefetch.yaml` is a one-shot `Job` that pre-downloads the default model into
the shared HuggingFace cache (the NFS PVC) so the server's first boot with a
new model is fast — it finds the file already cached and skips the multi-GB
download.

- **No GPU:** it only writes to the shared RWX NFS volume, so it never touches
  the running model's VRAM and cannot disturb it.
- **Same cache layout:** it uses the same `huggingface_hub` cache the server
  reads (`HF_HUB_CACHE=/root/.cache/huggingface/hub`), so a file written here
  is picked up by the server on boot.
- **Idempotent:** `hf download` is a no-op when the file is already cached,
  so re-applying (Flux reconcile) is cheap and safe.
- **To prefetch a new model:** change the repo/file in `prefetch.yaml` and
  re-apply.

### Testing a new model safely (branch-tracking)

The live cluster must never be left without a working model. To test a new
model without risking the running one:

1. Commit the `models.ini` change + `prefetch.yaml` to a feature branch and
   push it.
2. Point a **test `GitRepository`** at the branch (in `flux-system`) and a
   **test `Kustomization`** (`llama-cpp-test`, **`prune: false`**) at the
   branch's `app` path. `prune: false` is critical: deleting the test
   Kustomization must NOT delete the shared resources — the production
   Kustomization re-asserts the previous model.
3. Run the prefetch Job first (warms the cache), so the swap's downtime is
   only the model _load_ from NFS (minutes), not a download (hours).
4. Flux redeploys the pod (Recreate); the new model loads from the cache. Test
   a prompt from inside the pod:
   `kubectl -n llama-cpp exec deploy/llama-cpp -- sh -c 'curl -s
   -H "Authorization: Bearer $API_KEY" -d @/tmp/req.json
   localhost:8080/v1/chat/completions'`.
5. **Rollback:** delete the test `Kustomization` + `GitRepository` (+ the
   prefetch Job). The production Kustomization re-applies the previous model,
   which loads from the cache.

Delete the test `GitRepository` after the PR merges (the production
`ks.yaml` already points at the standard `flux-system` source).

## Verification

```bash
kubectl -n llama-cpp get pods -o wide          # scheduled on cluster-4
# with API key:
curl -fsS -H "Authorization: Bearer <key>" https://llama-cpp.garage.neo-tix.com/health
# without API key (should 401):
curl -fsS https://llama-cpp.garage.neo-tix.com/health
talosctl --nodes 172.20.17.197 dmesg | grep -i nvidia   # or nvidia-smi via debug container
```

## Pitfalls

- **CUDA 13.3 supports the RTX 2080Ti (Turing, sm_75):** the
  `server-cuda13` image is built against CUDA 13.3, whose minimum supported
  architecture is Turing (sm_75) — Maxwell/Pascal/Volta were dropped in
  CUDA 13.0. The `cluster-4` RTX 2080Ti is Turing, so it is within the
  supported range; the image is built for all supported architectures, so
  no `CUDA_DOCKER_ARCH` override is needed.
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
  (beelama.cpp image) **requires** `Accept-Encoding: gzip` to serve its
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
