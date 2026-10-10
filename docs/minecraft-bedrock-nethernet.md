# Minecraft Bedrock — NetherNet

The Bedrock Dedicated Server (BDS) on the Talos cluster runs
`itzg/minecraft-bedrock-server`. Since **BDS 1.26.50+** the default transport is
**NetherNet**, a WebRTC-based transport that is fundamentally different from the
old RakNet UDP model. Getting the networking wrong makes the server appear
"unreachable" even though the pod is healthy.

## How NetherNet works

| Port          | Protocol | Purpose                                                                                                                        |
| ------------- | -------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `19132`       | **TCP**  | HTTP signaling handshake (`GET /v1/join`). BDS listens on **TCP**, not UDP.                                                    |
| `19140-19155` | **UDP**  | Per-client gameplay ports. BDS uses one UDP port for **each** concurrent connection, from the range set in `SERVER_UDP_PORTS`. |
| `7551`        | **UDP**  | LAN discovery (broadcast; same subnet only).                                                                                   |

**BDS does NOT listen on UDP 19132.** If a client (or a Service/NodePort) sends
UDP packets to 19132, the server never replies. This is the #1 reason a NetherNet
server "isn't reachable": exposing only `UDP 19132` (the old RakNet port) means
nothing reaches the server.

## What this repo does

- `deployment.yaml` declares:
    - `containerPort: 19132` TCP (name `bedrock`) — the signaling port.
    - `containerPort: 19140-19155` UDP (`bedrock-udp` … `bedrock-udp-15`) — one per
      concurrent player (`max-players` is 10, so 16 ports is ample headroom).
    - `containerPort: 7551` UDP (`lan-discovery`).
    - `SERVER_UDP_PORTS: "172.20.17.140:19140-19155:19140-19155"` — the advertised
      address is the **pinned Cilium LoadBalancer IP** (`172.20.17.140`), because the
      pod IP is behind the LB. The `<advertised>:<external>:<internal>` form maps the
      external port to the internal port and advertises the reachable IP to clients.
- `service.yaml` is a `LoadBalancer` (Cilium, pinned to `172.20.17.140` via
  `lbipam.cilium.io/ips`) that publishes:
    - `19132/TCP` → `bedrock`
    - `19140-19155/UDP` → `bedrock-udp` … `bedrock-udp-15`
    - `7551/UDP` → `lan-discovery`
- Liveness/readiness probes use `tcpSocket` on the `bedrock` port (TCP 19132), which
  is the correct port under NetherNet.

## Allowlist & Permissions

Two separate mechanisms, both driven by env vars in `deployment.yaml`:

- **`ALLOW_LIST_USERS`** → written to `allowlist.json`. Controls **who may
  join**. BDS ships with `allow-list=true`, so if this list is empty the server
  refuses _everyone_ ("You're not invited to play on this server"). It accepts
  `name` (name-only, matched by name) or `name:xuid` (pins the XUID) entries,
  comma- or newline-separated.
- **`OPS` / `MEMBERS` / `VISITORS`** → written to `permissions.json`. Controls
  the **permission rank** of each allowed player. Each accepts XUIDs or
  gamertags (gamertags are resolved to XUIDs at startup via the MCProfile API).
  A player must appear in the allowlist _and_ in a permission group.

Current mapping:

| Player            | Allowlist | Permission |
| ----------------- | --------- | ---------- |
| `Hanks Toes#4861` | ✓         | **OP**     |
| `Max233444`       | ✓         | Member     |
| `Bxnk1325`        | ✓         | Member     |

> **Gamertag format matters.** `Hanks Toes#4861` must keep its `#4861` suffix —
> the bare `hanks toes4861` form does not resolve and the player is left with no
> rank.

## Pitfalls

- **UDP 19132 is dead under NetherNet.** Don't expose it. The server binds TCP
  19132; a UDP probe/Service on 19132 times out.
- **The advertised address must be client-reachable.** Because the pod sits behind
  a Cilium LB, advertise the pinned LB IP (`172.20.17.140`), not the pod IP. For
  internet access you'd use the public IP and forward the whole UDP range.
- **Need one UDP port per concurrent player.** Sizing the `SERVER_UDP_PORTS` range
  below `max-players` means the server can't open a gameplay port for extra
  players.
- **Health ≠ reachability.** The container health check connects over loopback; a
  "healthy" pod does not prove clients can reach the firewall/LB. Test from another
  machine: `curl http://172.20.17.140:19132/v1/join` should return the server name,
  version and player count as JSON.
- **Allowlist is on by default.** Players are pre-registered via `ALLOW_LIST_USERS`
  (XUIDs resolved on first join); an empty allowlist refuses everyone.
- **Cilium LoadBalancer UDP support.** Cilium LoadBalancer Services support UDP
  (as used by `qbittorrent-bittorrent` and the envoy UDP 443 ports), so publishing
  the 16-port UDP range works on this cluster.

## Verifying

```bash
# From a different machine (not the LB IP itself):
curl http://172.20.17.140:19132/v1/join

# In-cluster / cluster state:
kubectl -n minecraft-bedrock get pods,svc -o wide
kubectl -n minecraft-bedrock logs deploy/minecraft-bedrock --tail=50
```
