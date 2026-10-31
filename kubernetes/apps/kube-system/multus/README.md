# Multus CNI (multi-homed pods on the trunk NIC)

Rolls out the [Multus CNI](https://github.com/k8snetworkplumbingwg/multus-cni) meta-plugin on
top of Cilium, so pods can be given a **second network interface** on the node's trunk NIC.
The primary network is unchanged: Cilium on `bond0` (the VLAN-30 access NIC). Multus delegates
the default interface to Cilium and adds a per-pod secondary interface on request.

## How it works

- **Primary network (unchanged):** Cilium, the default CNI. It is configured `cni.exclusive: false`
  (see `kubernetes/apps/kube-system/cilium/app/helmrelease.yaml`) so it does not evict Multus's
  CNI config.
- **Multus (thick DaemonSet):** `kube-multus-ds` in `kube-system`. It installs the `multus` CNI
  binary into `/opt/cni/bin` and writes `00-multus.conf`, which sorts first in `/etc/cni/net.d`
  and makes Multus the entry-point CNI. With `multusConfigFile: auto`, the daemon auto-detects the
  primary CNI config: it lists the CNI configs, excludes `00-multus*`, sorts lexically, and takes
  the first — `05-cilium.conflist` (Cilium) sorts before the leftover `10-flannel.conflist`, so
  Cilium is picked. No manual `primaryCniConfigFile` is needed.
- **Host layer 2:** Talos creates one 802.1Q VLAN sub-interface per target VLAN on the trunk NIC,
  and an L2 `BridgeConfig` per VLAN that sits on that sub-interface (see the Talos config below).
  The trunk NIC is aliased to the stable name `trunk0` via a MAC-based `LinkAliasConfig`.
- **Secondary interface:** a `bridge` CNI via a `NetworkAttachmentDefinition` (NAD) on the Talos
  L2 bridge. The `bridge` CNI is used (not `macvlan`) because the Multus **thick** image bundles
  the `bridge` plugin but not `macvlan` — see the official Sidero Talos Multus guide. Pods opt in
  via annotation.
- **IPAM (DHCP):** each pod's secondary interface gets its IP (and netmask) from the **DHCP
  server** on that VLAN, keyed by the interface's MAC. The NAD declares
  `capabilities.mac`, so each pod pins its MAC via the annotation; the DHCP server maps that MAC
  to a fixed IP. This gives deterministic, duplicate-free IPs with **no cross-node coordination**
  (unlike `host-local`, which is per-node and hands the same first IP to every node). Backed by a
  per-node `dhcp` daemon (`dhcp-daemon` DaemonSet) and the `dhcp` CNI binary (Talos
  SystemExtension — see below).

## Talos node config

Managed in `talos/` (applied via `just talos apply`):

- `talos/all/20-network-links.yaml.tpl` — aliases the second (trunk) NIC to `trunk0` using the
  per-node `trunkMacAddr` from `topf.yaml`.
- `talos/all/23-vlan-subinterfaces.yaml.tpl` — `VLANConfig` docs `trunk0.20` (VLAN 20) and
  `trunk0.40` (VLAN 40), parented on `trunk0`, `up: true`. The host sub-interface only needs to be
  UP — pods get their own IPs from the bridge CNI, so no host address is set.
- `talos/all/24-vlan-bridges.yaml.tpl` — `BridgeConfig` docs `br-vlan20` (link `trunk0.20`) and
  `br-vlan40` (link `trunk0.40`), each an L2 bridge with no address of its own. The `bridge` CNI
  attaches each pod's interface to the matching bridge.
- `talos/topf.yaml` — `nodes[].data.trunkMacAddr` (the trunk NIC MAC per node).

Verify the sub-interfaces are up: `talosctl get linkstatuses -o yaml` shows `trunk0.20` /
`trunk0.40` UP.

## NetworkAttachmentDefinitions

`app/nads.yaml` defines one NAD per VLAN. IPAM is **DHCP** (the DHCP server on that VLAN assigns
the IP, keyed by the interface's MAC); the NAD declares `capabilities.mac` so pods can pin their
MAC via the annotation. The subnets (`172.20.16.0/24` for VLAN 20, `172.20.18.0/23` for VLAN 40)
are the L2 subnets the DHCP servers serve — they are not used for IPAM (DHCP assigns the IP), but
they define the address space.

| NAD       | bridge      | VLAN subnet      | DHCP server |
| --------- | ----------- | ---------------- | ----------- |
| `vlan-20` | `br-vlan20` | `172.20.16.0/24` | VLAN 20     |
| `vlan-40` | `br-vlan40` | `172.20.18.0/23` | VLAN 40     |

## Attaching a pod to a VLAN

The NADs live in `kube-system`, so reference them by fully-qualified `<namespace>/<name>` —
Multus resolves NADs in the pod's own namespace by default, so an unqualified `vlan-20` from
another namespace is not found. Because IPAM is DHCP, **pin the MAC** so the DHCP server maps it
to a known IP. Use the JSON form of the annotation with a `mac` field per network:

```yaml
metadata:
    annotations:
        k8s.v1.cni.cncf.io/networks: '[{"name":"kube-system/vlan-20","mac":"aa:bb:cc:00:00:01"}]'
```

Multiple networks: a JSON list, e.g.
`'[{"name":"kube-system/vlan-20","mac":"..."},{"name":"kube-system/vlan-40","mac":"..."}]'`.
Without an explicit name Multus auto-assigns `net1`, `net2`, …; to pin a name add `"interface"`,
e.g. `{"name":"kube-system/vlan-20","interface":"eth1","mac":"..."}`. Verify with:

```bash
kubectl get pod <p> -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/network-status}'
```

**Pinning the MAC per pod:** the MAC is what the DHCP server keys on, so each pod needs a
**unique, stable MAC**. For a Deployment/StatefulSet, set the MAC in the pod template (one MAC
per replica — for a StatefulSet, derive it from the ordinal). For a DaemonSet (one pod per
node), the pod template is identical across nodes, so pin a **per-node MAC** in each node's pod
(see the netshoot example below). The DHCP server is configured with a `MAC → IP` reservation for
each MAC.

## Example: pinning a specific IP to a pod (DHCP + MAC)

To give a particular pod a **known, deterministic IP** on a VLAN, you do **not** reserve the IP in
the NAD (IPAM is DHCP). Instead:

1. **Pick a stable MAC for that pod** and annotate the pod with it (the NAD declares
   `capabilities.mac`):

    ```yaml
    apiVersion: apps/v1
    kind: Deployment
    metadata:
        name: qbittorrent
    spec:
        template:
            metadata:
                annotations:
                    k8s.v1.cni.cncf.io/networks: '[{"name":"kube-system/vlan-20","mac":"aa:bb:cc:00:00:01"}]'
            spec:
                containers:
                    - name: qbittorrent
                      image: ...
    ```

2. **Reserve that MAC → IP on the DHCP server** for VLAN 20 (e.g. in dnsmasq:
   `dhcp-match=aa:bb:cc:00:00:01,tag` + a per-MAC static lease, or a `host={mac,ip}` line). The
   DHCP server hands `172.20.16.x` (whatever you reserved) to that MAC.

The pod then comes up with two interfaces: `eth0` (Cilium, the pod network) and `net1` (the
`bridge` CNI interface on `br-vlan20`, carrying the DHCP-assigned IP with the VLAN 20 netmask
`/24` and gateway `172.20.16.1`).

Because the IP is keyed by the MAC (not by the node), **every pod gets a distinct IP** even when
multiple nodes run the same workload — unlike `host-local`, which is per-node and hands the same
first IP to every node.

Verify the allocation:

```bash
kubectl -n <ns> get pod <pod> -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/network-status}'
# e.g. [{"name":"cilium","interface":"eth0","default":true,...},
#       {"name":"kube-system/vlan-20","interface":"net1","ips":["172.20.16.25"],"mac":"aa:bb:cc:00:00:01",...}]
```

## DHCP CNI binary (Talos SystemExtension)

The `dhcp` CNI binary is **not** in the Multus thick image. It is installed on the nodes via a
Talos **SystemExtension** that bakes the `dhcp` binary into the node image and drops it into
`/opt/cni/bin`. The SystemExtension must be built/published and referenced in the Talos
schematic (`talos/topf.yaml` → `schematicId`) — see `talos/SPECIFICATION.md`. Once the schematic
is updated and `just talos upgrade` is run, every node has `/opt/cni/bin/dhcp`.

Verify on a node:

```bash
talosctl -n <node> files ls /opt/cni/bin/   # should list dhcp
```

The `dhcp-daemon` DaemonSet (`app/dhcp-daemon.yaml`) runs the host's `/opt/cni/bin/dhcp` in
daemon mode, listening on `/run/cni/dhcp.sock` (the socket path the NADs reference).

## netshoot (per-node MAC example)

The `troubleshooting/netshoot` DaemonSet (`kubernetes/apps/troubleshooting/netshoot/app/daemonset.yaml`)
is the test pod: one per node, attached to both VLANs. Because it is a DaemonSet (identical pod
template on every node), a **per-node MAC** is pinned in each node's pod via the annotation.
The MAC placeholders `<MAC-VLAN20>` / `<MAC-VLAN40>` are filled in per node (one MAC per node);
the DHCP server maps each MAC to a fixed IP. This is the reference for how to pin per-pod MACs
on a DaemonSet.

## Image & resources

- Image pinned to the release tag `ghcr.io/k8snetworkplumbingwg/multus-cni:v4.3.1-thick` (both the
  daemon and the `install-multus-binary` init container), not the moving `snapshot-thick` tag —
  Renovate tracks the pinned tag.
- Memory limits raised to `100Mi` requests / `150Mi` limits on the `kube-multus` container. The
  upstream default of `50Mi` can OOM-kill the primary CNI plugin.

## Pitfalls

- **Use the `bridge` CNI, not `macvlan`.** The Multus **thick** image bundles the `bridge` CNI
  plugin (and `host-local`, `passthru`, …) but **not** `macvlan`. A NAD with `"type": "macvlan"`
  fails with `failed to find plugin "macvlan" in path [/opt/cni/bin]` and the pod crash-loops on
  `FailedCreatePodSandBox`. The `bridge` CNI needs a Talos `BridgeConfig` per VLAN (see the Talos
  config above); that is why `br-vlan20`/`br-vlan40` exist.
- **NADs are namespaced — reference them by fully-qualified name.** Multus resolves NADs in the
  pod's own namespace by default, so a pod in `troubleshooting` cannot see `vlan-20` in
  `kube-system` by bare name (`NoNetworkFound`). Use `kube-system/vlan-20` in the annotation.
- **Cilium `cni.exclusive` must be `false`.** If it is not, Cilium silently renames
  `00-multus.conf` to `00-multus.conf.cilium_bak` with no visible Multus error. Confirm it took
  effect (the repo sets it; verify `00-multus.conf` is present and not renamed on a node after
  the DaemonSet is up).
- **`/var/run` → `/run` symlink.** The upstream `host-run-netns` volume mounts `/run/netns/`. On
  this Talos version `/var/run` is a symlink to `/run`, so it works as-is. If a future Talos
  version drops the symlink, change the volume path to `/var/run/netns/`.
- **Reboot race.** After a node reboot, Cilium can start before Multus; a pod scheduled in that
  window gets only `eth0`. Rare; if observed, the documented fallback is a Cilium
  `cni.confPath` + Multus `primaryCniConfigFile` pointing at `05-cilium.conflist`.
- **DHCP IPAM needs a per-node `dhcp` daemon and the `dhcp` binary.** The `dhcp` CNI plugin talks
  to a per-node daemon over a unix socket (`/run/cni/dhcp.sock`). The daemon is the
  `dhcp-daemon` DaemonSet (`app/dhcp-daemon.yaml`); the `dhcp` binary must be in `/opt/cni/bin`
  on every node. The thick Multus image bundles `bridge`, `host-local`, `passthru`, … but **not**
  `dhcp` — the `dhcp` binary is installed separately (Talos SystemExtension, see below). If the
  daemon is not running or the binary is missing, the pod fails with `failed to find plugin
  "dhcp" in path [/opt/cni/bin]` or a socket connection error, and crash-loops on
  `FailedCreatePodSandBox`.
- **The MAC is the DHCP key — pin a unique, stable MAC per pod.** The DHCP server maps each MAC
  to a fixed IP. If two pods share a MAC, the DHCP server hands both the same IP (duplicate).
  For a DaemonSet the pod template is identical across nodes, so pin a **per-node MAC** in each
  node's pod (see the netshoot example). The DHCP server must have a `MAC → IP` reservation for
  every MAC you use.
- **The `host-local` IPAM is per-node and persistent.** (Retained for reference — we switched to
  DHCP.) Each node allocates from its own store, so two nodes sharing a range can hand the same
  IP to two pods. The store is persistent (on `/var`), so a pod's IP survives a reboot, but a
  deleted pod's IP stays allocated until freed — the usable range shrinks as pods churn. This is
  why DHCP (keyed by MAC, central on the DHCP server) is preferred here.
- **The switch port on the trunk NIC must be a trunk** carrying VLAN 20 and 40.
- **Flannel leftover.** A `10-flannel.conflist` and a `kube-flannel` DaemonSet are present on the
  nodes (Talos v1.14 ships Flannel by default; it coexists with Cilium here). It is harmless to
  Multus because Cilium's `05-cilium.conflist` sorts first, so auto-detection picks Cilium.
- **PSA warnings.** A pod with a Multus annotation triggers non-blocking Pod Security Admission
  warnings under a `restricted` policy (unset `allowPrivilegeEscalation`/`capabilities`/
  `runAsNonRoot`/`seccompProfile`). It still runs; add a matching `securityContext` to silence it.
