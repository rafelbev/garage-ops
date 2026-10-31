# L2 bridges on the VLAN sub-interfaces of the trunk NIC (trunk0). Each bridge
# has the matching VLAN sub-interface as its only link and carries no IP of its
# own — pods connect to the bridge via the `bridge` CNI (bundled in the Multus
# thick image) and get their own IPs from the host-local IPAM in the matching
# NetworkAttachmentDefinition (see kubernetes/apps/kube-system/multus).
#
# The `bridge` CNI is used instead of `macvlan` because the thick Multus image
# bundles the `bridge` plugin but not `macvlan` — see the official Sidero Talos
# Multus guide (docs.siderolabs.com/kubernetes-guides/cni/multus).
---
apiVersion: v1alpha1
kind: BridgeConfig
name: br-vlan20
links:
  - trunk0.20
---
apiVersion: v1alpha1
kind: BridgeConfig
name: br-vlan40
links:
  - trunk0.40
