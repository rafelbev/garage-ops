# Cilium

Cilium is the CNI and kube-proxy replacement for the Talos cluster. It
provides pod networking, eBPF service load-balancing (socket-LB), and L2
announcements for exposing LoadBalancer service IPs on the LAN.

## Load Balancer Configuration

The cluster runs Cilium in **DSR (Direct Server Return) mode** with the
following key settings (see `app/helmrelease.yaml`):

| Setting                    | Value    | Purpose                                                                  |
| -------------------------- | -------- | ------------------------------------------------------------------------ |
| `loadBalancer.mode`        | `dsr`    | Backends reply directly to external clients (preserves client source IP) |
| `loadBalancer.algorithm`   | `maglev` | Consistent-hashing backend selection                                     |
| `loadBalancer.dsrDispatch` | `geneve` | Geneve-encapsulated DSR dispatch (fixes cross-node return path)          |
| `l2announcements.enabled`  | `true`   | Announces LoadBalancer IPs on the LAN via ARP                            |
| `socketLB.enabled`         | `true`   | eBPF socket-level load balancing                                         |
| `routingMode`              | `native` | Native routing (no tunnel for pod-to-pod traffic)                        |
| `tunnelProtocol`           | `geneve` | Required for DSR+Geneve dispatch (LB return path only)                   |

### DSR + L2-Announcer + Cross-Node Backends

**Problem (found Nov 2026):** LoadBalancer services with backends on multiple
nodes (e.g. `envoy-external` with pods on cluster-3 and cluster-4) suffered
**intermittent connectivity failures** — roughly 50% of external requests
timed out (`HTTP 000`).

**Root cause:** The L2-announcer elects a single node as the ARP owner for the
LoadBalancer VIP (via a Kubernetes Lease in `kube-system`). All external
traffic for the VIP arrives at that node. The socket-LB (maglev) then selects
a backend pod per-flow, which can be on a **remote** node. In DSR mode with the
default `opt` dispatch, the backend replies directly to the client using the
VIP as source IP, but the reply's source MAC is the **remote node's** MAC. The
client's ARP cache for the VIP points at the **local** node (the L2-announcer
lease holder), so the reply's MAC is asymmetric and the packet is dropped.

**Fix:** `loadBalancer.dsrDispatch: geneve` **plus** `tunnelProtocol: geneve`.
In Geneve dispatch mode the DSR reply is Geneve-encapsulated and tunneled back
through the original receiving node, which re-egresses it to the client with
the correct source MAC. This makes the return path symmetric and eliminates the
intermittent failures.

> **Note:** `dsrDispatch: geneve` **requires** `tunnelProtocol: geneve` —
> Cilium rejects the agent at startup with _"Node Port 'dsr' mode with
> 'geneve' dispatch requires geneve tunnel protocol"_ if it is missing. With
> `routingMode: native`, the Geneve tunnel is used **only** on the LB DSR
> return path; pod-to-pod routing stays native (no overlay).

**Trade-off:** Geneve adds a 16-byte header, reducing effective MTU by ~16
bytes on encapsulated paths. Negligible on a home LAN, but the main risk.

**Reference:** [Cilium DSR documentation](https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/#direct-server-return-dsr)

### Why not SNAT mode?

SNAT mode (`loadBalancer.mode: snat`) also fixes the asymmetric return path
(reverse-NATs the reply through the receiving node), but it does **not**
preserve the client source IP — the backend sees the node IP instead. DSR +
Geneve preserves the client IP at the cost of a small MTU reduction, which is
the preferred trade-off for this cluster.

## L2 Announcements

L2 announcements expose LoadBalancer service IPs on the LAN. Each service's
VIP is announced by a single node (the Lease holder). Inspect the leases:

```bash
kubectl -n kube-system get leases | grep cilium-l2announce
```

The `HOLDER` column shows which node currently announces each service's VIP.
The lease is first-come, first-served; failover occurs between
`leaseDuration - leaseRenewDeadline` and `leaseDuration + leaseRenewDeadline`
seconds after the holder stops renewing (defaults: 10–20 s).

## Debugging

```bash
# Socket-LB reverse NAT entries (which backend a flow was assigned to)
kubectl -n kube-system exec ds/cilium -- cilium bpf socknat list

# Maglev lookup table (consistent-hash backend distribution)
kubectl -n kube-system exec ds/cilium -- cilium bpf lb maglev list

# All LB service entries (frontends → backends)
kubectl -n kube-system exec ds/cilium -- cilium bpf lb list
```

To confirm the DSR return-path fix is working, check that `socknat list`
shows reverse-NAT entries for the LoadBalancer frontend and that external
requests succeed consistently (no `HTTP 000` timeouts).
