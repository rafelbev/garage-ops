# GPU DeviceClass (DRA)

Cluster-scoped [Dynamic Resource Allocation](https://kubernetes.io/docs/concepts/resource-management/dynamic-resource-allocation/)
`DeviceClass` for the GPU-capable worker node (`cluster-4`).

The NVIDIA driver on `cluster-4` comes from Talos system extensions
(`nonfree-kmod-nvidia-lts` kernel modules + `nvidia-container-toolkit-lts`
userspace), not from the NVIDIA GPU Operator. The driver exposes the GPU
through DRA as a `ResourceSlice`; this `DeviceClass` selects the device and
lets workloads claim it.

## Requesting a GPU

Classic extended-resource syntax (routed through DRA via
`extendedResourceName: nvidia.com/gpu`):

```yaml
spec:
    containers:
        - name: llama-cpp
          image: ghcr.io/ggml-org/llama.cpp:latest
          resources:
              limits:
                  nvidia.com/gpu: 1
```

Explicit DRA claim (full control):

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
