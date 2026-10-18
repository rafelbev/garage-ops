# Talos Factory Schematic Specification

This document defines the exact Talos schematic customizations required for
the cluster nodes, so the schematics can be recreated at
[factory.talos.dev](https://factory.talos.dev) if they are ever lost.

Two schematics are in use (a third, pre-GPU, is kept for `cluster-3`):

| Schematic ID                                                       | Nodes                                    | Purpose                                                             |
| ------------------------------------------------------------------ | ---------------------------------------- | ------------------------------------------------------------------- |
| `c9078f9419961640c712a8bf2bb9174933dfcf1da383fd8ea2b7dc21493f8bac` | `cluster-1`, `cluster-2` (control-plane) | Base schematic with iSCSI tools                                     |
| `dc7b152cb3ea99b821fcb7340ce7168313ce393d663740b791c36f6e95fc8586` | `cluster-3` (worker)                     | iSCSI tools + QEMU guest agent                                      |
| `b35fa40a282aa26883402baf7eada609e8e297569df5ad436695631d7d0d8185` | `cluster-4` (GPU worker)                 | iSCSI tools + QEMU guest agent + NVIDIA driver (kernel + userspace) |

## Control-Plane Schematic

**Schematic ID:** `c9078f9419961640c712a8bf2bb9174933dfcf1da383fd8ea2b7dc21493f8bac`

### System Extensions

| Extension                | Purpose                                |
| ------------------------ | -------------------------------------- |
| `siderolabs/iscsi-tools` | iSCSI initiator for TrueNAS CSI access |

**YAML (as created in factory.talos.dev):**

```yaml
customization:
    systemExtensions:
        officialExtensions:
            - siderolabs/iscsi-tools
```

## GPU Worker Schematic (cluster-4)

**Schematic ID:** `b35fa40a282aa26883402baf7eada609e8e297569df5ad436695631d7d0d8185`

### System Extensions

| Extension                                 | Purpose                                           |
| ----------------------------------------- | ------------------------------------------------- |
| `siderolabs/iscsi-tools`                  | iSCSI initiator for TrueNAS CSI access            |
| `siderolabs/qemu-guest-agent`             | QEMU guest agent (Proxmox VM integration)         |
| `siderolabs/nonfree-kmod-nvidia-lts`      | NVIDIA driver kernel modules (LTS variant)        |
| `siderolabs/nvidia-container-toolkit-lts` | NVIDIA userspace driver + container toolkit (LTS) |

**YAML (as created in factory.talos.dev):**

```yaml
customization:
    systemExtensions:
        officialExtensions:
            - siderolabs/iscsi-tools
            - siderolabs/nonfree-kmod-nvidia-lts
            - siderolabs/nvidia-container-toolkit-lts
            - siderolabs/qemu-guest-agent
```

### Kernel Modules

The NVIDIA kernel modules must be loaded at boot (declared per-node in
`talos/topf.yaml` under `data.kernelModules`, rendered by
`talos/all/61-kernel-modules.yaml.tpl`):

- `nvidia`
- `nvidia_uvm`
- `nvidia_drm`
- `nvidia_modeset`

plus the standard iSCSI set (`iscsi_tcp`, `libiscsi`, `libiscsi_tcp`,
`scsi_transport_iscsi`).

### Notes

- The NVIDIA driver is provided by the Sidero extensions, **not** by the
  NVIDIA GPU Operator. The driver registers with the kubelet as a DRA driver
  and exposes the GPU to Kubernetes via
  [Dynamic Resource Allocation](https://kubernetes.io/docs/concepts/resource-management/dynamic-resource-allocation/)
  (selected by the `gpu` `DeviceClass` in `kubernetes/apps/gpu-deviceclass/`).
- The node carries the label `gpu-capable: "true"`
  (`talos/node/cluster-4/50-gpu-label.yaml`).
- The node is a Proxmox VM installed from the Talos **nocloud** image with
  PCI passthrough of the RTX 2080Ti.
