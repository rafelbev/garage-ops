# mosquitto (MQTT broker)

The Eclipse Mosquitto MQTT broker, migrated from the k3s cluster to Talos.
Stateless: configuration is a small ConfigMap plus a sops-encrypted Secret —
no PVC, no state to import.

## Architecture

| Resource             | Kind / API             | Purpose                                                                  |
| -------------------- | ---------------------- | ------------------------------------------------------------------------ |
| `mosquitto`          | Deployment (`apps/v1`) | `eclipse-mosquitto:2.0.11` (same tag as the source k3s deployment)       |
| `mosquitto-config`   | ConfigMap              | `mosquitto.conf` — carried over byte-exact from k3s                      |
| `mosquitto`          | Secret                 | `users.conf` — sops-encrypted; mounted at `/mosquitto/config/users.conf` |
| `mosquitto`          | Service (`v1`)         | `ClusterIP` :1883 — in-cluster consumers use `mosquitto.mosquitto.svc`   |
| `mosquitto-external` | Service (`v1`)         | `LoadBalancer` pinned to `172.20.17.143` — the LAN endpoint              |

## Exposure

- **LAN**: `172.20.17.143:1883` (Cilium LB VIP). This replaces the k3s MetalLB
  endpoint `172.20.0.130:1883`. **Off-cluster MQTT clients (ESP32/ESP8266
  devices, Home Assistant MQTT integrations, etc.) must be re-pointed from
  `172.20.0.130:1883` to `172.20.17.143:1883`** — the broker IP changed, the
  port did not.
- **In-cluster**: `mosquitto.mosquitto.svc.cluster.local:1883` (ClusterIP).
  No in-cluster consumer referenced the broker on k3s at migration time; the
  service is kept for a stable DNS name.

## Authentication

`allow_anonymous false` with a `password_file` (`users.conf`). The file holds
`user:<salted PBKDF2-SHA256 hash>` lines — mosquitto's `$7$<iter>$<salt+hash>`
format, so no plaintext password is stored. The file is carried over
byte-exact from k3s, so existing client credentials keep working unchanged.
The Secret (not a ConfigMap) is the right home for it: it is credential
material, and the repo convention keeps such files sops-encrypted.

## Migration notes

- Source: k3s namespace `mosquitto`, Helm release `mosquitto-1627226326`
  (chart mosquitto-3.3.0), Deployment + ClusterIP Service + LoadBalancer
  Service, no PVC, no hostPort/hostNetwork.
- Target: plain manifests (not the Helm chart) following the repo app
  convention; explicit resource requests/limits added (the source had none);
  same image tag, same TCP probes as the source.
- The k3s deployment is scaled down (not deleted) until the Talos endpoint is
  verified, as the rollback path.
