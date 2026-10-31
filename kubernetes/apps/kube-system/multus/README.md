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

`app/nads.yaml` defines one NAD per VLAN:

| NAD       | bridge      | subnet             | gateway       |
| --------- | ----------- | ------------------ | ------------- |
| `vlan-20` | `br-vlan20` | `172.20.16.224/28` | `172.20.16.1` |
| `vlan-40` | `br-vlan40` | `172.20.19.224/28` | `172.20.18.1` |

IPAM is `host-local` with a **persistent** store: `dataDir` is `/var/lib/cni/networks/<name>`
(on `/var`, which survives node reboots) — NOT the tmpfs `/run/cni`. So the same pod keeps its
IP across a reboot. A `reserve` block pins specific IPs to specific pods by name for
deterministic allocation; the `*` entry bounds allocation to the usable range, and you add
`"<pod-name>": "<ip>"` entries as you attach pods.

## Attaching a pod to a VLAN

The NADs live in `kube-system`, so reference them by fully-qualified `<namespace>/<name>` —
Multus resolves NADs in the pod's own namespace by default, so an unqualified `vlan-20` from
another namespace is not found:

```yaml
metadata:
    annotations:
        k8s.v1.cni.cncf.io/networks: kube-system/vlan-20
```

Multiple networks: a comma-separated list, e.g. `kube-system/vlan-20,kube-system/vlan-40`.
Without an explicit name Multus auto-assigns `net1`, `net2`, …; to pin a name use the
`<nad>@<ifname>` form, e.g. `kube-system/vlan-20@eth1`. Verify with:

```bash
kubectl get pod <p> -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/network-status}'
```

## Example: pinning a specific IP to a deployment

To give a particular deployment a **known, deterministic IP** on a VLAN (so it keeps that IP
across reboots and is addressable from that LAN), do two things:

1. **Reserve the IP for that pod name** in the NAD's `reserve` block
   (`kubernetes/apps/kube-system/multus/app/nads.yaml`). The key is the pod name (for a
   single-replica Deployment that is the deployment name); the value is the IP you want:

    ```json
    "reserve": {
        "qbittorrent": "172.20.16.225",
        "*": [ "172.20.16.226", "172.20.16.227", ... ]
    }
    ```

    When the `qbittorrent` pod is created, host-local assigns it `172.20.16.225` and never hands
    that address to any other pod. The reserved IP is persisted in the `dataDir` store, so it
    survives a node reboot.

2. **Annotate the deployment** to attach the VLAN network:

    ```yaml
    apiVersion: apps/v1
    kind: Deployment
    metadata:
        name: qbittorrent
    spec:
        template:
            metadata:
                annotations:
                    k8s.v1.cni.cncf.io/networks: kube-system/vlan-20
            spec:
                containers:
                    - name: qbittorrent
                      image: ...
    ```

    The pod then comes up with two interfaces: `eth0` (Cilium, the pod network) and `net1`
    (the `bridge` CNI interface on `br-vlan20`, carrying `172.20.16.225/28` with gateway
    `172.20.16.1`).

Verify the allocation:

```bash
kubectl -n <ns> get pod <pod> -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/network-status}'
# e.g. [{"name":"cilium","interface":"eth0","default":true,...},
#       {"name":"kube-system/vlan-20","interface":"net1","ips":["172.20.16.225"],...}]
```

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
- **`host-local` IPAM is per-node and persistent.** Each node allocates from its own store, so two
  nodes sharing a range can hand the same IP to two pods. The store is persistent (on `/var`), so
  a pod's IP survives a reboot, but a deleted pod's IP stays allocated until freed — the usable
  range shrinks as pods churn. To keep it deterministic, pin pods to IPs via `reserve` in the NAD.
  For cluster-wide (cross-node) allocation, use the `whereabouts` plugin (extra DaemonSet + CRD).
- **The switch port on the trunk NIC must be a trunk** carrying VLAN 20 and 40.
- **Flannel leftover.** A `10-flannel.conflist` and a `kube-flannel` DaemonSet are present on the
  nodes (Talos v1.14 ships Flannel by default; it coexists with Cilium here). It is harmless to
  Multus because Cilium's `05-cilium.conflist` sorts first, so auto-detection picks Cilium.
- **PSA warnings.** A pod with a Multus annotation triggers non-blocking Pod Security Admission
  warnings under a `restricted` policy (unset `allowPrivilegeEscalation`/`capabilities`/
  `runAsNonRoot`/`seccompProfile`). It still runs; add a matching `securityContext` to silence it.
