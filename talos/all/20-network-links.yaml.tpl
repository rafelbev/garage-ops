---
apiVersion: v1alpha1
kind: LinkAliasConfig
name: ethSel0
selector:
  match: glob("{{ .Node.Data.macAddr }}", mac(link.hardware_addr))
---
# The second NIC (trunk mode on the switch) is aliased to a stable name so the
# 802.1Q VLAN sub-interfaces can reference it regardless of kernel NIC naming.
apiVersion: v1alpha1
kind: LinkAliasConfig
name: trunk0
selector:
  match: glob("{{ .Node.Data.trunkMacAddr }}", mac(link.hardware_addr))
---
apiVersion: v1alpha1
kind: BondConfig
name: bond0
links:
  - ethSel0
bondMode: active-backup
mtu: {{ .Node.Data.mtu }}
addresses:
  - address: "{{ .Node.IP }}/25"
routes:
  - gateway: "{{ .Data.networkGateway }}"
{{- if eq .Node.Role "control-plane" }}
---
apiVersion: v1alpha1
kind: Layer2VIPConfig
link: bond0
name: "{{ .Data.clusterVip }}"
{{- end }}
