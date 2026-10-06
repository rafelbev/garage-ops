apiVersion: v1alpha1
kind: KubeNetworkConfig
dnsDomain: cluster.local
podSubnets:
  - "172.20.128.0/18"
serviceSubnets:
  - "172.20.64.0/19"
---
machine:
  certSANs:
    - "127.0.0.1"
    - "{{ .Data.clusterVip }}"
    - "{{ .Data.apiServerDomain }}"
