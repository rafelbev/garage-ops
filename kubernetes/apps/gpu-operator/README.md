# NVIDIA GPU Operator

Deploys the [NVIDIA GPU Operator](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/overview.html)
(`nvidia/gpu-operator` Helm chart v26.7.2 from `https://helm.ngc.nvidia.com/nvidia`)
via Flux, following the standard app layout.

This is **point 4 of
[issue #83](https://github.com/rafelbev/garage-ops/issues/83)**: the
driver is **disabled** because the NVIDIA driver (kernel modules +
userspace) and the container toolkit on the GPU worker `cluster-4` come
from the Talos system extensions
(`siderolabs/nonfree-kmod-nvidia-lts` +
`siderolabs/nvidia-container-toolkit-lts`, see `talos/SPECIFICATION.md`).
Sidero's own
[nvidia-container-toolkit extension README](https://github.com/siderolabs/extensions/blob/main/nvidia-gpu/nvidia-container-toolkit/README.md)
recommends running the operator with the driver disabled; this goes one
step further and disables the operator's toolkit operand as well, since
the Sidero extension provides the toolkit and the containerd runtime
wiring (CDI + nvidia runtime) already.

## What the operator deploys here

The v26.x chart renders a `ClusterPolicy` CR; the operator daemon
(`gpu-operator` Deployment) then creates the operand DaemonSets from it.
With the values in `helmrelease.yaml`:

| Operand                                    | State                    | Why                                                                                                                                                             |
| ------------------------------------------ | ------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| driver                                     | off                      | comes from the Talos kernel-module extension                                                                                                                    |
| toolkit                                    | off                      | comes from the Talos userspace/toolkit extension (no `installDir` needed)                                                                                       |
| cdi                                        | **on** (NRI off)         | generates the CDI device spec; the NRI plugin ships with the toolkit operand in this chart and is redundant — containerd wiring comes from the Sidero extension |
| device-plugin                              | **on, time-sliced**      | exposes `nvidia.com/gpu` as a schedulable resource                                                                                                              |
| dcgm-exporter                              | on (default)             | GPU metrics to Prometheus (`ServiceMonitor` CRD exists in the cluster)                                                                                          |
| node-feature-discovery                     | on (default)             | labels nodes with GPU features                                                                                                                                  |
| mig-manager, gfd, vgpu*, vfio, cc, sandbox | off                      | datacenter-only, no-ops on a single consumer card                                                                                                               |
| `operator.runtimeClass`                    | `nvidia` (chart default) | only `cluster-4` has the `nvidia` RuntimeClass; operands don't need it, so the DaemonSets can run on the other nodes                                            |

## Time-slicing (concurrent GPU access)

The device plugin runs with a `sharing.timeSlicing` config (embedded
ConfigMap `device-plugin-config`): the single physical GPU is advertised
as **4** `nvidia.com/gpu` slots. Four pods each requesting
`nvidia.com/gpu: 1` therefore run on `cluster-4` at the same time and the
NVIDIA driver interleaves their kernels.

```yaml
resources:
    limits:
        nvidia.com/gpu: 1
```

This is the mechanism for the issue's goal of running llama.cpp, vllm,
audio.cpp and whisper concurrently on one card.

**Caveats:**

- Time-slicing oversubscribes _time_, not _memory_: every pod sees the
  full 11GB of VRAM. Size the models so their combined working set fits;
  a CUDA OOM in one pod does not affect the others' slots, but total VRAM
  pressure can degrade all of them.
- `failRequestsGreaterThanOne: false` lets a pod request more than one
  slot (e.g. `nvidia.com/gpu: 2`) for a heavier model — it gets a larger
  time share, not more VRAM.
- `renameByDefault: false` keeps the plain `nvidia.com/gpu` name (vs
  `nvidia.com/gpu.shared`).
- `replicas: 4` is a scheduling ceiling, not a recommendation to run four
  models at full load simultaneously.

## Why the `gpu` DeviceClass lost its `extendedResourceName`

The `gpu` `DeviceClass` in `kubernetes/apps/gpu-deviceclass/` previously
set `extendedResourceName: nvidia.com/gpu`, which routed the classic
syntax through DRA. That is no longer possible: since Kubernetes 1.37
(DRA Extended Resource, stable — see KEP-5004), **a single node must not
provide the same extended resource through both DRA and a device
plugin**. With the device plugin now owning `nvidia.com/gpu` on
`cluster-4`, the field was removed from the `DeviceClass`.

What this changes for workloads:

- `resources.limits: {nvidia.com/gpu: 1}` → now satisfied by the device
  plugin (time-sliced). Same syntax, no manifest changes needed.
- Explicit DRA claims (`resourceClaims` + `DeviceClass gpu`) **keep
  working** — that path is independent of `extendedResourceName`.
- The implicit DRA extended-resource name
  `deviceclass.resource.kubernetes.io/gpu` is also available for
  DRA-backed allocation.

## Verification (once cluster-4 is back on)

```bash
flux get hr -n gpu-operator
kubectl -n gpu-operator get pods -o wide
# the device plugin advertises the sliced slots:
kubectl get node cluster-4 -o jsonpath='{.status.allocatable.nvidia\.com/gpu}{"\n"}'
# expected: 4
# driver userspace files are under /usr/local (hostPaths.driverInstallDir):
kubectl -n gpu-operator exec ds/nvidia-device-plugin-daemonset -- ls /usr/local
# on the node: nvidia-smi
# single-GPU test:
kubectl run cuda-test --rm -i --restart=Never \
  --image=nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda12.5.0 -- \
  sh -c "nvidia-smi"   # or the vectoradd sample requesting nvidia.com/gpu: 1
# concurrent test: two pods requesting nvidia.com/gpu: 1 both Running
```

## Troubleshooting

### GPU Operator HelmRelease stuck in `Failed` — no device plugin (2026-10-24)

After PR #225 merged, `HelmRelease/gpu-operator/gpu-operator` failed with:

```
failed to create resource: server-side apply failed for object /cluster-policy
nvidia.com/v1, Kind=ClusterPolicy: ClusterPolicy.nvidia.com "cluster-policy" is
invalid: spec.operator: Invalid value: "null": spec.operator in body must be of
type object: "null"
```

**Root cause:** the `gpu-operator` chart v26.7.2 renders the whole `spec.operator`
block from non-empty values only, so setting `operator.runtimeClass: ""` made the
template emit `spec.operator: null`, which the `ClusterPolicy` CRD schema rejects
(the field must be an object). The release failed during `ClusterPolicy` creation
and therefore never created the device plugin — cluster-4 never advertised
`nvidia.com/gpu`.

**Fix:** keep the chart default (`operator.runtimeClass: nvidia`). Reconcile and
verify:

```bash
flux reconcile source git -n gpu-operator
kubectl -n gpu-operator get pods -o wide
kubectl get node cluster-4 -o jsonpath='{.status.allocatable.nvidia\.com/gpu}{"\n"}'
# expected: 4
```

## Notes

- `cluster-4` is the only node with an NVIDIA GPU. The operand DaemonSets
  run on all four nodes and simply find no GPU on the others (they
  advertise 0 slots there).
- No secrets are required — there is no sops component in this app.
- The DRA `DeviceClass` and the device plugin deliberately coexist: the
  plugin owns the classic `nvidia.com/gpu` name on `cluster-4`, the
  `DeviceClass` remains for explicit DRA claims.
