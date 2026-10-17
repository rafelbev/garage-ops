# ollama-split — k3s → Talos migration runbook

One-shot data migration for the apps split out of the k3s `ollama`
namespace. **This directory is NOT Flux-synced** (it lives outside
`kubernetes/apps/`) — the Jobs are applied manually and run themselves.

## Self-sufficiency

From Phase 1 on, **no AI agent and no interactive input is needed**. The
migration runs unattended:

- The Jobs verify themselves (file count + byte totals) and only report
  success when the target is an exact mirror of the source.
- `backoffLimit: 2` retries a transient failure; `activeDeadlineSeconds`
  caps a hung run; `ttlSecondsAfterFinished` deletes the finished Job
  after 24h (logs are available until then).
- Everything below is copy-paste commands against two kubeconfigs.

The AI chat endpoints go down during Phase 3 (k3s teardown) by design —
nothing in this runbook requires them.

## Phases

### Phase 0 — preconditions (Talos cluster)

```bash
KUBECONFIG=<talos-kubeconfig>

# 4 namespaces + workloads exist and are Ready
kubectl get ns open-webui openterminal hermes-dashboard orca-serve
kubectl -n open-webui  get pods,sts
kubectl -n openterminal get pods,deploy,pvc
# PVCs bound on truenas-iscsi
kubectl -n open-webui  get pvc open-webui
kubectl -n openterminal get pvc open-terminal-pvc
```

### Phase 1 — data import

**1a. Quiesce the k3s sources** (stops writes so verification is
deterministic; this takes the k3s chat UI offline — expected):

```bash
KUBECONFIG=<k3s-kubeconfig>
kubectl -n ollama scale statefulset open-webui   --replicas=0
kubectl -n ollama scale deployment  openterminal --replicas=0
```

**1b. Launch the migration Jobs** (Talos). Each Job mounts the k3s NFS
export read-only-ish at `/src` and the fresh iSCSI PVC at `/dst`, rsyncs
twice (full pass + delta mirror), then verifies file count and byte
totals. Exit 0 only on an exact match.

```bash
KUBECONFIG=<talos-kubeconfig>
kubectl apply -f migration/ollama-split/open-webui/open-webui-job.yaml
kubectl apply -f migration/ollama-split/openterminal/openterminal-job.yaml

# Watch (they finish on their own; open-webui has ~490 vector_db
# subdirectories, expect a few minutes):
kubectl -n open-webui   get job open-webui-migration   -w
kubectl -n openterminal get job openterminal-migration -w
```

**1c. Verify success** — the log must end with `MIGRATION_OK`:

```bash
kubectl -n open-webui   logs job/open-webui-migration
kubectl -n openterminal logs job/openterminal-migration
```

On `FATAL: verification mismatch` (live writes during the run): delete the
Job and re-apply it (the second rsync pass is incremental, so reruns are
fast).

### Phase 2 — smoke test the new endpoints (no DNS change needed)

The `*.garage.neo-tix.com` wildcard already resolves to the Talos
gateway LB (external-dns), so the new subdomains work as soon as the
HTTPRoutes reconcile:

```bash
curl -sSfI https://chat.garage.neo-tix.com
curl -sSfI https://openterminal.garage.neo-tix.com
curl -sSfI https://hermes-dashboard.garage.neo-tix.com
curl -sSfI https://orca.garage.neo-tix.com
```

Confirm open-webui shows the imported data (login / chat history) and
openterminal shows the imported home directory.

### Phase 3 — retire the k3s `ollama` namespace

⚠️ This takes the k3s chat endpoints down. Run unattended; no step below
needs an AI agent.

```bash
KUBECONFIG=<k3s-kubeconfig>
helm -n ollama uninstall open-webui
kubectl -n ollama delete deploy openterminal svc -l app.kubernetes.io/name --ignore-not-found
kubectl -n ollama delete pvc open-webui open-terminal-pvc
kubectl -n ollama delete pv pvc-a17006b7-6d7c-4207-b2a1-48511fee5ca1 \
                            pvc-6e6356d4-e7ab-4e6d-8b29-857c590add33
```

**Do NOT delete the TrueNAS NFS exports**
(`/mnt/storage/cloud/ollama-open-webui-pvc-*`,
`/mnt/storage/cloud/ollama-open-terminal-pvc-*`) — they are the rollback
path. Keep them for at least two weeks.

## Rollback

If a Talos app misbehaves after cutover:

1. Re-point DNS for the affected host back to the old
   `*.cloud.neo-tix.com` name (Cloudflare),
2. Restart the k3s workloads (`scale ... --replicas=1`,
   `helm -n ollama install ...` from the chart with the old values),
3. The NFS exports still hold the pre-migration data.

## Facts baked into the Job manifests

| Item                    | Value                                                                                  |
| ----------------------- | -------------------------------------------------------------------------------------- |
| NFS server (k3s PVs)    | `172.20.0.10`                                                                          |
| open-webui export       | `/mnt/storage/cloud/ollama-open-webui-pvc-a17006b7-6d7c-4207-b2a1-48511fee5ca1`        |
| openterminal export     | `/mnt/storage/cloud/ollama-open-terminal-pvc-pvc-6e6356d4-e7ab-4e6d-8b29-857c590add33` |
| open-webui target PVC   | `open-webui` (chart `volumeClaimTemplate`, 8Gi, `truenas-iscsi`)                       |
| openterminal target PVC | `open-terminal-pvc` (10Gi, `truenas-iscsi`)                                            |
| NFS mount from Talos    | verified working (probe pod, 2026-10-17)                                               |

`hermes-dashboard` and `orca-serve` need no data migration (host
Services + Endpoints only); their migration is the HTTPRoute itself.
