apiVersion: v1alpha1
kind: KubeNetworkConfig
dnsDomain: cluster.local
podSubnets:
  - "{{ .Data.podSubnet }}"
serviceSubnets:
  - "{{ .Data.serviceSubnet }}"
---
machine:
  certSANs:
    - "127.0.0.1"
    - "{{ .Data.clusterVip }}"
    - "{{ .Data.apiServerDomain }}"
