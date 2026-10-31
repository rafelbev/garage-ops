# 802.1Q VLAN sub-interfaces on the trunk NIC (trunk0). The host sub-interface
# only needs to be UP — pods get their own IPs from the macvlan CNI via the
# matching NetworkAttachmentDefinition (see kubernetes/apps/kube-system/multus).
---
apiVersion: v1alpha1
kind: VLANConfig
name: trunk0.20
parent: trunk0
vlanID: 20
up: true
---
apiVersion: v1alpha1
kind: VLANConfig
name: trunk0.40
parent: trunk0
vlanID: 40
up: true
