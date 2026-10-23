# GPU DeviceClass (DRA)

Cluster-scoped [Dynamic Resource Allocation](https://kubernetes.io/docs/concepts/resource-management/dynamic-resource-allocation/)
`DeviceClass` for the GPU-capable worker node (`cluster-4`).

The NVIDIA driver on `cluster-4` comes from Talos system extensions
(`nonfree-kmod-nvidia-lts` kernel modules + `nvidia-container-toolkit-lts`
userspace), not from the NVIDIA GPU Operator. The driver exposes the GPU
through DRA as a `ResourceSlice`; this `DeviceClass` selects the device for
explicit DRA claims.

## Requesting a GPU

The classic syntax is now satisfied by the **device plugin** deployed by
the [GPU Operator](../gpu-operator/README.md) (time-sliced — see that
README for the config and caveats):

```yaml
spec:
    containers:
        - name: llama-cpp
          image: ghcr.io/ggml-org/llama.cpp:latest
          resources:
              limits:
                  nvidia.com/gpu: 1
```

Explicit DRA claim (full control, independent of the device plugin):

```yaml
apiVersion: v1
kind: Pod
metadata:
    name: llama-cpp
spec:
    resources:
        claims:
            - name: gpu
    resourceClaims:
        - name: gpu
          source:
              apiGroup: device.k8s.io
              kind: DeviceClass
              name: gpu
    containers:
        - name: llama-cpp
          image: ghcr.io/ggml-org/llama.cpp:latest
          resources:
              resources:
                  - name: gpu
```

The implicit DRA extended-resource name
`deviceclass.resource.kubernetes.io/gpu` can also be used in
`resources.limits` for DRA-backed allocation without a claim block.

## Why there is no `extendedResourceName`

Since Kubernetes 1.37 (DRA Extended Resource, stable — KEP-5004), a
single node must not provide the same extended resource through both DRA
and a device plugin. The GPU Operator's device plugin owns
`nvidia.com/gpu` on `cluster-4`, so this class deliberately does not set
`extendedResourceName`. Explicit DRA claims through the class are
unaffected.

## Node label

`cluster-4` carries the node label `gpu-capable: "true"`
(`talos/node/cluster-4/50-gpu-label.yaml`), so workloads can also use a
plain `nodeSelector`/`nodeAffinity` on it.

## Verification

```bash
kubectl get deviceslices
kubectl get deviceclass gpu -o yaml
# after a claim:
kubectl get resourceclaim -A
```
