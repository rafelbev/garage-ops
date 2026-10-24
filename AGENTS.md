# AGENTS.md — garage-ops

This document provides guidance for AI agents (Goose, Opencode, etc.) working on the garage-ops repository. It captures operational knowledge, common pitfalls, and best practices derived from real incidents and upgrades.

## How to Use This Document

### Goose AI Agent

When working on this repository with Goose, reference this AGENTS.md file for:

- Understanding the project structure and tooling
- Following the correct procedures for Talos and Kubernetes operations
- Avoiding common pitfalls documented from past incidents
- Understanding the Flux GitOps workflow

Goose will automatically load this file when working in the repository root.

### Opencode

For Opencode, reference this AGENTS.md file as the primary context document. Include it in your system prompt or context when working on garage-ops tasks.

### General Guidelines

- **Always check Flux status** before and after making changes
- **Never commit unencrypted secrets** to git
- **Preview changes** before applying to the cluster
- **Test in a non-production environment** when possible
- **Document changes** in commit messages and PR descriptions
- **Worktree files**: Uncommitted files (age key, talosconfig, etc.) live in the main worktree, not in task-specific worktrees. Check there first when files are missing.

## Agent Division of Labor

This project uses two AI agents with distinct responsibilities. Use the right agent for the right task.

### Use Hermes (linus) for:

| Task                             | Example                                             |
| -------------------------------- | --------------------------------------------------- |
| Cluster inspection               | `kubectl get pods -n <app> -o wide` on k3s or Talos |
| Planning and task breakdown      | Assessing a migration, identifying gaps             |
| Communication with both clusters | kubectl, talosctl, just commands                    |
| Migration execution              | Running migration scripts, transferring config      |
| Flux status and debugging        | `flux get ks -A`, checking pod logs, events         |
| PR management                    | Creating PRs, updating descriptions, merging        |
| Architectural decisions          | Storage class choices, domain patterns              |
| Reviewing Goose's work           | Inspecting git diff, verifying constraints          |
| Documentation updates            | Amending AGENTS.md with learnings                   |

### Use Goose for:

| Task                     | Example                                                |
| ------------------------ | ------------------------------------------------------ |
| Writing manifests        | Creating deployment.yaml, service.yaml, httproute.yaml |
| Editing existing files   | Patching values, updating configurations               |
| Running pre-commit hooks | format-yaml, format-markdown, etc.                     |
| Local commits            | `git add` and `git commit` on the feature branch       |
| Code implementation      | Translating a clear spec into working code             |

### Workflow: Hermes Orchestrates, Goose Codes

For tasks like cluster migrations:

1. **Hermes inspects** the source deployment on k3s
2. **Hermes plans** the migration and identifies constraints
3. **Hermes delegates** to Goose with specific instructions
4. **Goose writes** the manifests and commits locally
5. **Hermes reviews** the changes (git diff, file inspection)
6. **Hermes pushes** and manages the PR
7. **Hermes executes** the migration (config transfer)
8. **Hermes verifies** the result on Talos

### Communication with Goose

```bash
# Find the Goose terminal
orca terminal list --json
# Look for agentIdentity: "goose", note the handle

# Send a task
orca terminal send --terminal <handle> --text "Your task" --enter

# Wait for completion
orca terminal wait --terminal <handle> --for tui-idle --timeout-ms 300000

# Read the result
orca terminal read --terminal <handle> --screen --limit 50
```

**Note:** Avoid backticks in messages to Goose — they are interpreted as shell commands.

## Agent Division of Labor

This project uses two AI agents with distinct responsibilities. Use the right agent for the right task.

### Use Hermes (linus) for:

| Task                             | Example                                             |
| -------------------------------- | --------------------------------------------------- |
| Cluster inspection               | `kubectl get pods -n <app> -o wide` on k3s or Talos |
| Planning and task breakdown      | Assessing a migration, identifying gaps             |
| Communication with both clusters | kubectl, talosctl, just commands                    |
| Migration execution              | Running migration scripts, transferring config      |
| Flux status and debugging        | `flux get ks -A`, checking pod logs, events         |
| PR management                    | Creating PRs, updating descriptions, merging        |
| Architectural decisions          | Storage class choices, domain patterns              |
| Reviewing Goose's work           | Inspecting git diff, verifying constraints          |
| Documentation updates            | Amending AGENTS.md with learnings                   |

### Use Goose for:

| Task                     | Example                                                |
| ------------------------ | ------------------------------------------------------ |
| Writing manifests        | Creating deployment.yaml, service.yaml, httproute.yaml |
| Editing existing files   | Patching values, updating configurations               |
| Running pre-commit hooks | format-yaml, format-markdown, etc.                     |
| Local commits            | `git add` and `git commit` on the feature branch       |
| Code implementation      | Translating a clear spec into working code             |

### Workflow: Hermes Orchestrates, Goose Codes

For tasks like cluster migrations:

1. **Hermes inspects** the source deployment on k3s
2. **Hermes plans** the migration and identifies constraints
3. **Hermes delegates** to Goose with specific instructions
4. **Goose writes** the manifests and commits locally
5. **Hermes reviews** the changes (git diff, file inspection)
6. **Hermes pushes** and manages the PR
7. **Hermes executes** the migration (config transfer)
8. **Hermes verifies** the result on Talos

### Communication with Goose

```bash
# Find the Goose terminal
orca terminal list --json
# Look for agentIdentity: "goose", note the handle

# Send a task
orca terminal send --terminal <handle> --text "Your task" --enter

# Wait for completion
orca terminal wait --terminal <handle> --for tui-idle --timeout-ms 300000

# Read the result
orca terminal read --terminal <handle> --screen --limit 50
```

**Note:** Avoid backticks in messages to Goose — they are interpreted as shell commands.

## Pull Request Guidelines

### Branching

- **Never create or push changes directly to `main`**
- Always work on a feature/fix branch: `git checkout -b <type>/<description>`
    - Examples: `fix/upgrade-k8s-1.37.0`, `feat/add-storage-support`, `chore/update-dns`
- Push your branch and create a PR against `main`
- **Squash merge awareness**: When a PR is squash-merged, the original branch is no longer a valid base for follow-up PRs (it will have merge conflicts). Before pushing follow-up changes, check if the previous PR was squash-merged. If so, create a new branch from `main` for the new PR instead of reusing the old branch.

### Documentation Requirements

Before opening a PR, you **must** include documentation with your findings so that future agents and humans don't have to rediscover the architecture, requirements, configuration, and pitfalls.

**For fixes:**

- Amend existing documentation to reflect the fix
- Update any outdated procedures or warnings
- Document the root cause and the solution

**For features:**

- Add new documentation sections as needed
- Update existing documentation to reference the new feature
- Include configuration examples and usage instructions

**Consolidation over duplication:**

- If documentation already exists for the area you're working on, **consolidate** rather than creating new conflicting documents
- Fix: amend the existing doc
- Feature: add to the existing doc
- Avoid creating multiple docs that cover the same topic

### PR Checklist

- [ ] Changes are on a feature/fix branch (not `main`)
- [ ] Existing documentation has been reviewed and consolidated
- [ ] New documentation includes architecture, requirements, configuration, and pitfalls
- [ ] Documentation is consistent with existing docs (no contradictions)
- [ ] Flux status checked before and after changes
- [ ] Changes tested in non-production environment when possible

## Project Overview

A single Kubernetes cluster running on **Talos Linux** (v1.14.1) with **Kubernetes** (v1.37.0), managed via:

- **topf** — Talos configuration management (templates + patches)
- **Flux** — GitOps sync from this repository
- **SOPS + age** — Secret encryption
- **just** — Task runner (`justfile`)
- **mise** — Tool version management (`.mise/config.toml`)

Cluster: 3 control-plane nodes (also run workloads), no dedicated workers.

## Repository Structure

```
talos/
  topf.yaml           # Node inventory, versions, kernel modules
  secrets.sops.yaml   # Talos cluster secrets (encrypted)
  all/                # Patches applied to every node
  control-plane/      # Control-plane-only patches
  node/<hostname>/    # Per-node patches
kubernetes/
  apps/<app>/         # One directory per application
    kustomization.yaml
    namespace.yaml
    <app>/ks.yaml     # Flux Kustomization
    <app>/app/        # HelmRelease or manifests
  components/sops/    # Shared sops-encrypted secrets
  flux/cluster/ks.yaml # Top-level Flux Kustomization
bootstrap/
  mod.just            # Bootstrap recipes
  helmfile/           # Initial Flux bootstrap via helmfile
```

## Tooling Quick Reference

| Task                             | Command                          |
| -------------------------------- | -------------------------------- |
| List all just recipes            | `just`                           |
| Apply Talos config (all nodes)   | `just talos apply`               |
| Apply Talos config (single node) | `just talos apply-node <node>`   |
| Preview Talos config changes     | `just talos diff`                |
| Render Talos configs             | `just talos render`              |
| Upgrade Talos (all nodes)        | `just talos upgrade`             |
| Upgrade Talos (single node)      | `just talos upgrade-node <node>` |
| Upgrade Kubernetes               | `just talos upgrade-k8s`         |
| Reset cluster (destructive)      | `just talos reset`               |
| Force Flux sync                  | `just kube reconcile`            |
| Bootstrap Talos                  | `just bootstrap talos`           |
| Bootstrap apps                   | `just bootstrap apps`            |

## Use Case 1: Talos Operations (Updates, Upgrades, Modules)

### Updating Talos Node Configuration

1. **Modify patches** in `talos/all/`, `talos/control-plane/`, or `talos/node/<hostname>/`
2. **Preview** changes: `just talos diff`
3. **Apply** to nodes: `just talos apply` (all) or `just talos apply-node <node>`
4. Push changes to git — Flux will reconcile

**Pitfall**: Some configuration changes require both `apply` AND `upgrade` (e.g., kernel modules). The `apply` command updates the config stored on the node, but the node must reboot or be upgraded for the changes to take effect.

### Upgrading Talos Version

1. Update `talosVersion` in `talos/topf.yaml`
2. Update `talosctl` and installer versions in `.mise/config.toml` to match
3. Run `mise install` to update local tooling
4. Run `just talos upgrade` (upgrades all nodes one at a time)
5. Push changes to git

**Pitfalls**:

- **Version compatibility**: Talos and Kubernetes versions must be compatible. Check the [Talos versioning docs](https://www.talos.dev/latest/versioning/).
- **Deprecated patches**: When upgrading Talos, check release notes for deprecated configuration options. Example: `admissionControl` patch was removed in Talos 1.14.1 (PR #40).
- **Schematic changes**: If the upgrade changes the default schematic, you may need to create a new schematic at [factory.talos.dev](https://factory.talos.dev) and update the `schematicId` in `topf.yaml`.

### Adding Kernel Modules

1. Add module names to each node's `data.kernelModules` array in `talos/topf.yaml`
2. The `talos/all/61-kernel-modules.yaml.tpl` patch automatically generates the machine config
3. **Create a new schematic** at [factory.talos.dev](https://factory.talos.dev) that includes the required kernel modules
4. Update `schematicId` in `topf.yaml` for all nodes
5. Run `just talos upgrade` to apply the new schematic

**Pitfalls**:

- **Default schematic lacks modules**: The default Talos schematic does NOT include iSCSI modules (iscsi_tcp, libiscsi, libiscsi_tcp, scsi_transport_iscsi). A custom schematic is required.
- **Never omit existing modules**: When creating a new schematic, include ALL previously required modules. See `talos/SPECIFICATION.md` for the complete list.
- **Node reboot required**: Kernel module changes require node reboot.
- **Rollback plan**: Keep the old schematic ID available for rollback.

### Adding System Extensions

1. Create a new schematic at [factory.talos.dev](https://factory.talos.dev) with the required system extensions
2. Update `schematicId` in `topf.yaml` for all nodes
3. Run `just talos upgrade`

## Use Case 1b: Rejoining a Reset Control-Plane Node

A CP node that was reset (especially a full/PERSISTENT reset) comes back with a
**regenerated machine identity and CA**. The stale etcd member must be removed
first, then the node re-applies its config and rejoins the raft group. Recovered
from the cluster-1 reset incident (2026-10).

### Procedure

1. **Remove the stale etcd member** from a healthy node (never from the broken one):
    ```bash
    talosctl etcd remove-member <stale-member-id> -n <healthy-node>
    ```
    Confirm the raft group has N-1 live members: `talosctl etcd members -n <healthy-node>`.
2. **Take a safety etcd snapshot** before any join work (rollback path).
3. **Render the node config** with `just talos render` (v1.14 document-based schema).
4. **Apply + reboot** (NOT another reset):
    ```bash
    talosctl apply-config --talosconfig <cfg> --nodes <ip> -f <rendered>
    talosctl reboot --nodes <ip>
    ```
    On a configured node, mTLS with the existing talosconfig works even after a full
    reset (the rejoining node presents the cluster CA) — `--insecure` is only for
    maintenance-mode nodes.
5. **Watch the boot** — a fresh boot takes a few minutes; kubelet/etcd/trustd not
   running yet is normal. Check forward progress:
    ```bash
    talosctl get machinestatus --nodes <ip> -o yaml   # stage, ready, created/updated
    ```
    `updated` frozen for many minutes at `stage: booting` = stuck, not "still booting".
6. **Verify the join**:
    ```bash
    kubectl get nodes                        # node Ready
    talosctl etcd members -n <healthy-node>  # 3 members, new ID for the rejoined node
    ```

### Pitfalls

- **`machine.files` can only write to `/var` in v1.14.** A `files` entry targeting
  `/etc/...` (PERSISTENT partition) fails the `writeUserFiles` boot task with
  `create operation not allowed outside of /var`. That failure blocks the entire
  boot: `unattended install` never finishes → CRI/sandboxd never register →
  kubelet/etcd/trustd never start → node stuck at `stage: booting` with
  `Kubelet: Unhealthy` while `apid` is healthy. Fix: drop the `/etc` file entries
  and re-apply + reboot. (The `/etc/iscsi/initiatorname.iscsi` file is created by
  the iSCSI system extension at boot, not by `files`.)
- **Don't pile on resets.** A second full reset regenerates the CA again and you
  lose observability. Only EPHEMERAL wipes if truly needed.

## Use Case 1c: GPU Worker Node (cluster-4) and DRA DeviceClass

The GPU-capable worker `cluster-4` (172.20.17.197, Proxmox VM, nocloud image,
RTX 2080Ti PCI passthrough) exposes its NVIDIA GPU through
[Dynamic Resource Allocation](https://kubernetes.io/docs/concepts/resource-management/dynamic-resource-allocation/)
— **no device plugin, no NVIDIA GPU Operator**.

### Architecture

- **Driver + toolkit come from Talos system extensions**, baked into a custom
  schematic (see `talos/SPECIFICATION.md`):
    - `siderolabs/nonfree-kmod-nvidia-lts` — kernel modules (nvidia, nvidia_uvm,
      nvidia_drm, nvidia_modeset)
    - `siderolabs/nvidia-container-toolkit-lts` — userspace driver/toolkit
    - plus `iscsi-tools` and `qemu-guest-agent`, matching the other schematics
- The NVIDIA driver registers with the kubelet as a DRA driver and publishes
  the GPU in a `ResourceSlice` (apiGroup `resource.k8s.io`).
- **`DeviceClass` `gpu`** (`kubernetes/apps/gpu-deviceclass/`) selects the
  device by its driver (`device.driver == "nvidia.com/gpu"`) and sets
  `extendedResourceName: nvidia.com/gpu`, so pods can keep the classic
  `resources.limits: {nvidia.com/gpu: 1}` syntax while allocation is
  handled by DRA (Kubernetes >= 1.36).
- **Node label `gpu-capable: "true"`** is set via
  `KubeNodeConfig.labels` in `talos/node/cluster-4/50-gpu-label.yaml`, so
  workloads can also select the node plainly.

### Requesting a GPU

```yaml
resources:
    limits:
        nvidia.com/gpu: 1
```

or an explicit DRA claim (`resourceClaims` + `resources.resources` on the
container) — see `kubernetes/apps/gpu-deviceclass/README.md`.

### Verification

```bash
kubectl get deviceslices          # driver, pool, device name, labels
kubectl get deviceclass gpu -o yaml
kubectl get resourceclaim -A
# on the node: nvidia-smi
```

### Pitfalls

- **The DeviceClass v1 selector is CEL-only, and CEL only sees
  `device.driver` and `device.name`.** `spec.selectors[].label` existed in
  v1beta1 but was removed in `resource.k8s.io/v1`, and device _labels_
  (e.g. `nvidia.com/gpu.product`) are **not** exposed to v1 CEL — a selector
  like `device.labels[...]` fails server-side validation. Select by driver:
  `device.driver == "nvidia.com/gpu"`.
- **If a second GPU type is added later**, the driver-wide selector will
  match both; add a separate DeviceClass per type and select by
  `device.name` (the driver publishes per-device names).
- **Don't add the GPU Operator for this node.** Its driver and toolkit
  components would conflict with the Sidero extensions. Only add it if the
  legacy device-plugin path is ever needed.
- **Schematic must carry all modules**: when re-creating the schematic,
  include the iSCSI modules too — see `talos/SPECIFICATION.md`.

## Use Case 2: Upgrading Kubernetes

1. Update `kubernetesVersion` in `talos/topf.yaml`
2. Verify Talos version supports the target Kubernetes version
3. Run `just talos upgrade-k8s`
4. Push changes to git

**Pitfalls**:

- **Talos version first**: If the target Kubernetes version requires a newer Talos version, upgrade Talos first (Use Case 1), then upgrade Kubernetes.
- **Helm chart compatibility**: After Kubernetes upgrade, verify all Helm charts are compatible. Renovate may have already opened PRs for chart updates.
- **CRD changes**: Some Kubernetes upgrades introduce CRD changes. Check for breaking changes in Flux, Cilium, and other operators.
- **Rolling upgrade**: `talosctl upgrade-k8s` performs a rolling upgrade. Monitor with `kubectl get pods --all-namespaces --watch`.

## Use Case 3: Installing a New Application (Helm Chart)

### Standard Pattern

Create a directory structure for the application:

```
kubernetes/apps/<app-name>/
  kustomization.yaml
  namespace.yaml
  <app-name>/
    ks.yaml
    app/
      kustomization.yaml
      helmrelease.yaml
      helmrepository.yaml  (if not using Flux's built-in)
```

### Example: Adding a New App

1. **Create namespace and kustomization**:

```yaml
# kubernetes/apps/<app-name>/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
    name: <app-name>
```

```yaml
# kubernetes/apps/<app-name>/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: <app-name>
components:
    - ../../components/sops
resources:
    - ./namespace.yaml
    - ./<app-name>/ks.yaml
```

2. **Create Flux Kustomization**:

```yaml
# kubernetes/apps/<app-name>/<app-name>/ks.yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
    name: <app-name>
spec:
    healthChecks:
        - apiVersion: helm.toolkit.fluxcd.io/v2
          kind: HelmRelease
          name: <app-name>
          namespace: <app-name>
    interval: 1h
    path: ./kubernetes/apps/<app-name>/<app-name>/app
    postBuild:
        substituteFrom:
            - name: cluster-secrets
              kind: Secret
    prune: true
    sourceRef:
        kind: GitRepository
        name: flux-system
        namespace: flux-system
    targetNamespace: <app-name>
```

3. **Create HelmRepository** (if chart is not in Flux's built-in repositories):

```yaml
# kubernetes/apps/<app-name>/<app-name>/app/helmrepository.yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
    name: <repo-name>
spec:
    interval: 1h
    url: https://charts.example.com
```

4. **Create HelmRelease**:

```yaml
# kubernetes/apps/<app-name>/<app-name>/app/helmrelease.yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
    name: <app-name>
spec:
    chart:
        spec:
            chart: <chart-name>
            sourceRef:
                kind: HelmRepository
                name: <repo-name>
            version: "<version>"
    interval: 1h
    values:
        # Chart values here
```

5. **Push to git** — Flux will automatically detect and apply the new resources.

**Pitfalls**:

- **Secrets must be sops-encrypted**: Any secrets must be stored in `.sops.yaml` files and added to the `components/sops` component.
- **Health checks**: Include health checks in the Kustomization to ensure Flux waits for the app to be ready before proceeding.
- **Remediation**: The cluster-level `ks.yaml` (`kubernetes/flux/cluster/ks.yaml`) adds default remediation strategies to all HelmReleases. Do not override unless necessary.
- **Namespace conflicts**: Ensure the namespace doesn't already exist or is managed elsewhere.
- **Chart-hardcoded fields need `spec.postRenderers`**: If a Helm chart hardcodes a
  field you must override (e.g. `truenas-csi` hardcodes the `iscsi-dir` hostPath as
  `type: Directory`, which fails on Talos because `/etc/iscsi` is created late by
  the iSCSI system container — the CSI node pod gets stuck in ContainerCreating),
  add a Kustomize strategic-merge patch to the HelmRelease. A live
  `kubectl patch` is reverted by Flux on the next reconciliation (1h); a
  `postRenderers` patch is durable:

    ```yaml
    spec:
        postRenderers:
            - kustomize:
                  patches:
                      - target:
                            kind: DaemonSet
                            name: truenas-csi-node
                        patch: |
                            apiVersion: apps/v1
                            kind: DaemonSet
                            metadata:
                              name: truenas-csi-node
                            spec:
                              template:
                                spec:
                                  volumes:
                                    - name: iscsi-dir
                                      hostPath:
                                        path: /etc/iscsi
                                        type: DirectoryOrCreate
    ```

    Verify locally before committing: `helm template` the chart, then run the
    patch through `kustomize build` and confirm the rendered field changed
    (see `kubernetes/apps/truenas-csi` for the working example).

## Use Case 4: Installing an Application from Docker Compose

When migrating from Docker Compose to Kubernetes/Helm:

1. **Identify the service components** in the compose file
2. **Find an existing Helm chart** or create a custom one
3. **Map compose environment variables** to Helm values or Kubernetes ConfigMaps/Secrets
4. **Map compose volumes** to PersistentVolumeClaims (using the appropriate StorageClass)
5. **Map compose ports** to Kubernetes Services and (if needed) HTTPRoutes
6. **Follow Use Case 3** to deploy

**Pitfalls**:

- **Network differences**: Docker Compose services communicate via a bridge network. In Kubernetes, use Services for inter-pod communication.
- **Volume persistence**: Docker volumes are host-local. In Kubernetes, use PersistentVolumeClaims with the appropriate StorageClass (`truenas-nfs` for shared, `truenas-iscsi` for single-writer).
- **DNS**: Docker Compose uses service names for DNS. In Kubernetes, use service names within the same namespace, or `service.namespace.svc.cluster.local` for cross-namespace.
- **Resource limits**: Docker Compose has no default resource limits. Always set requests and limits in Kubernetes.
- **Health checks**: Docker Compose restart policies are simple. Kubernetes health checks (liveness, readiness, startup) provide more control.

## Use Case 5: Migrating an Application from Another Kubernetes Cluster

This use case covers migrating an application from an existing cluster (e.g., k3s) to the Talos cluster. The process was refined through the Sonarr migration (PR #50, #51).

### Migration Process (k3s → Talos)

1. **Assess the source deployment**:

    ```bash
    # Identify the app's pod, namespace, and resources
    kubectl get pods -n <namespace> -o wide
    kubectl get pvc -n <namespace>
    kubectl get ingress -n <namespace> -o yaml
    ```

2. **Create the target deployment manifests** following Use Case 3 pattern:
    - Use `truenas-iscsi` StorageClass for single-writer config PVCs
    - Use `truenas-nfs` StorageClass or static NFS PV for shared/read-many data
    - Set explicit resource requests and limits
    - Set PUID=0, PGID=0 for linuxserver images
    - Set TZ=Europe/Malta
    - Do NOT pin to specific nodes (unlike k3s which may have been pinned)
    - Use the same image tag as the source for compatibility

3. **Create a migration script** for config transfer:
    - Scale down the new deployment (0 replicas)
    - Export config from old PVC via tar in a pod
    - Download tar to local machine
    - Upload tar to new PVC via import pod
    - Scale up the new deployment
    - Verify the app is working
    - Scale down the old deployment (keep for rollback)

4. **Handle race conditions in migration scripts**:
    - Export pod should create a done marker file when finished
    - Script should poll for the done marker before proceeding
    - Import pod should wait for the tar file to exist before extracting

5. **Create Gateway API HTTPRoute** (not Ingress):

    ```yaml
    apiVersion: gateway.networking.k8s.io/v1
    kind: HTTPRoute
    metadata:
        name: <app-name>
        namespace: <app-name>
    spec:
        hostnames:
            - <app-name>.garage.neo-tix.com
        parentRefs:
            - group: gateway.networking.k8s.io
              kind: Gateway
              name: envoy-external
              namespace: network
        rules:
            - backendRefs:
                  - group: ""
                    kind: Service
                    name: <app-name>
                    namespace: <app-name>
                    port: 80
                    weight: 1
              matches:
                  - path:
                        type: PathPrefix
                        value: /
    ```

6. **Push to git** — Flux will deploy everything automatically

7. **Verify**:
    - Check pod is running on Talos
    - Check HTTPRoute is accepted by gateway
    - Test the URL in a browser
    - Verify data migrated correctly

8. **Verify all services are present**:
    - Compare services on source and target: `kubectl get svc -n <namespace>` on both clusters
    - If the source had a LoadBalancer service (for direct peer connections, port forwarding, or external access), recreate it on Talos
    - For LoadBalancer services, allocate a static IP via Cilium's `lbipam.cilium.io/ips` annotation — verify the IP is not already in use before allocating
    - Example: qBittorrent requires a LoadBalancer service for the bittorrent port (6881) in addition to the ClusterIP service for the web UI

### Key Learnings from Sonarr Migration

- **NFS server IP**: Talos cluster uses `172.20.17.150` for TrueNAS NFS (not `172.20.0.10` used by k3s). Verify port 2049 is open.
- **Media data**: If media is on TrueNAS NFS, no data migration needed — just point the new PVC/PV to the same NFS export.
- **Config data**: Must be migrated via tar export/import. Use `truenas-iscsi` PVC for config.
- **Domain change**: k3s used `cloud.neo-tix.com`, Talos uses `garage.neo-tix.com`.
- **Ingress → HTTPRoute**: k3s used Ingress resources, Talos uses Gateway API HTTPRoute.
- **Node pinning**: k3s deployments were pinned to specific nodes (e.g., `coreos-vm3`). Talos deployments should not be pinned.
- **Flux reconciliation**: If Flux doesn't pick up changes, force reconcile:
    ```bash
    kubectl annotate kustomization <name> -n <namespace> reconcile.fluxcd.io/requestedat="$(date +%s)" --overwrite
    ```
- **Rollback**: Keep the old deployment scaled down (not deleted) until the new one is verified working.

### Key Learnings from Jackett Migration

- **Strict image tags for dependabot**: Use specific version tags (e.g., `linuxserver/jackett:amd64-0.24.2663`) instead of `latest` or `amd64-latest`. This allows dependabot/renovate to track and propose upgrades. Check Docker Hub or the upstream GitHub releases for the latest stable version.
- **Storage class mapping**: k3s used `truenas-nfs-dynamic` for dynamic PVCs. On Talos, use `truenas-iscsi` for single-writer config PVCs (better performance) or `truenas-nfs` for shared/read-many data.
- **Authelia not used on Talos**: Do not add auth annotations (e.g., `http-auth` or similar) to HTTPRoute or Ingress resources. Authentication is handled differently on the Talos cluster.
- **No node pinning**: Talos deployments should not use `nodeSelector` to pin to specific nodes. Let the scheduler place pods optimally.

### Key Learnings from Radarr Migration

- **Size iSCSI config PVCs generously**: The Radarr config directory was 1.6GB after compression (including media covers and database). A 1Gi PVC was too small; 2Gi was needed. Always estimate the source config size before creating the target PVC. Check with `du -sh` on the source PVC contents.
- **Verify tar integrity after transfer**: Large tarballs transferred via `kubectl cp` can be corrupted. Verify with `tar -tzf` on both source and destination before attempting extraction.
- **Config import can fail silently**: The import pod may fail due to "No space left on device" without obvious error messages. Check pod logs and PVC capacity.
- **Squash merge awareness**: When a PR is squash-merged, subsequent PRs based on the original branch will have merge conflicts. Always check if the previous PR was squash-merged before pushing follow-up changes. If so, create a new branch from `main` for a new PR.

### Key Learnings from LiteLLM Migration

- **Stateless proxies keep their DB external**: litellm stores all state (API keys, models, spend logs — a 4 GB database) in Postgres. Per the no-in-cluster-databases rule, the database stays on k3s and is exposed to the LAN via a LoadBalancer service created there (`postgres16-external` in the `postgresql16` namespace, MetalLB-assigned `172.20.0.138:5432`). This creates a **cross-cluster dependency**: the k3s `postgresql16` namespace must not be deleted until the database is migrated separately.
- **Verify cross-cluster DB reachability from a pod on the new cluster**, not from the workstation — the workstation and the cluster may be on different networks. Run a probe pod on the new cluster using the app's own image (it already has the DB driver), authenticated as the app user, and confirm a real query succeeds.
- **Reuse existing keys when a dependent service already holds them**: litellm's master key was already in open-webui's sops secret (open-webui points at litellm), so the key was reused without rotation — no client-side changes needed.
- **k3s ingress IP allowlists do not carry over**: the k3s ingress used a `whitelist-source-range` annotation; there is no equivalent mechanism for HTTPRoutes in this repo. Note the difference in the PR.
- **Add probes to proxy workloads**: the k3s source had none. The Talos manifests add a startup probe with a 10-minute budget (litellm's first boot runs the DB schema sync and is slow), plus liveness and readiness.

### Key Learnings from Headscale Migration

- **Host-endpoint apps migrate as exposure, not workload**: headscale runs as a host process on `172.20.17.17` (not in a container). The k3s side was selectorless ClusterIP Services + manual `Endpoints` objects + an Nginx Ingress. On Talos this maps directly to the hermes-dashboard / k8s-api pattern: `Service` (no selector) + `Endpoints` + `HTTPRoute`. No PVC or config migration is involved — only the cluster-side exposure moves.
- **headplane (the headscale web UI) serves under `/admin/`**: headplane on port 3000 returns 404 at `/` and serves the login page under `/admin/`. The HTTPRoute must keep the `/admin/` → `headplane:3000` rule ahead of the `/` → `headscale:8085` rule (Gateway API evaluates rules in order).
- **Verify host endpoints from a pod on the new cluster before merging**: a curl probe pod on Talos confirmed `172.20.17.17:8085/health` → `{"status":"pass"}` and `172.20.17.17:3000/admin/` → 302 → `/admin/login` — the same checks a merge+Flux deploy will rely on.
- **Gateway API handles WebSocket upgrades natively**: the k3s Ingress needed a `configuration-snippet` for `Upgrade`/`Connection` headers; the Talos HTTPRoute needs no equivalent annotation.

### Key Learnings from Authelia Migration

- **Authelia's state is three components, not just a PVC.** The k3s
  DaemonSet ran with a ConfigMap (`configuration.yaml`), a Secret
  (three keys referenced via `AUTHELIA_*_SECRET_FILE` env vars), and a
  PVC holding the local storage database (`db.sqlite3`), the users
  file (`users_database.yml`) and `notification.txt`. A migration that
  only carries the PVC leaves the pod crash-looping on fatal config
  errors (`authentication_backend not configured`, `storage not
  configured`, `notifier not configured`).
- **`STORAGE_ENCRYPTION_KEY` is bound to the database file — carry it
  over unchanged.** Authelia's local storage encrypts `db.sqlite3` at
  rest with this key; rotating it orphans the migrated database
  (it can no longer be decrypted). `JWT_TOKEN` and
  `SESSION_ENCRYPTION_KEY` are safe to regenerate — only active
  sessions/JWTs are invalidated, users just re-login on cutover.
- **Authelia's health endpoint is `/api/health`, not `/health`.**
  Probes on `/health` 404 forever; the pod never becomes ready even
  when the app is healthy.
- **Domain re-pointing in `configuration.yaml`**: `session.domain`,
  `totp.issuer` and the `access_control` `domain_regex` entries all
  carry the old base domain (`cloud.neo-tix.com` → `garage.neo-tix.com`).
  `default_redirection_url` pointed at `www.cloud.neo-tix.com`, which is
  not hosted on Talos — it now lands on `auth.garage.neo-tix.com`.

### Key Learnings from the File Browser Fix

- **The new `filebrowser/filebrowser` image (v2.63.x) hardcodes its paths**: the
  `/init.sh` entrypoint injects `--config=/config/settings.json` when no `-c`
  argument is given, and the baked-in config points at
  `database: /database/filebrowser.db`. `workingDir` is ignored entirely — a
  `workingDir: /db` fix that worked on the old `filebrowser/file-browser`
  image silently stopped working after a Renovate image bump, and filebrowser
  re-initialized a fresh ephemeral DB with a random admin password on every
  restart (crash loop). To customize, mount a ConfigMap at `/config` with your
  own `settings.json` — `init.sh` only copies `/defaults/settings.json` when
  `/config/settings.json` is absent.
- **The database file must be named `filebrowser.db`**: the k3s deployment ran
  with an explicit `-d /db/database.db`, so the PVC held `database.db`. The
  new image would never find it even after remounting. Renamed it to
  `filebrowser.db` in the PVC (one-shot probe pod, deployment scaled to 0 —
  the PVC is RWO).
- **Tar migrations can drop file ownership**: the k3s→Talos transfer left
  `filebrowser.db` as `root:root 600`, while the image runs as uid 1000 →
  `open /database/filebrowser.db: permission denied`. A one-shot
  `chown -R 1000:1000` in a probe pod fixed it. When migrating state, check
  ownership in the PVC, not just contents.
- **Check the listening port across image bumps**: the new image listens on
  80 (the old k3s config used 8080). containerPort, probes, and the Service
  `targetPort` all had to move to 80.

### Key Learnings from the llama-cpp (GPU Inference) Deployment

- **GPU workloads on this cluster use the GPU Operator's device-plugin
  path**: `nvidia.com/gpu` in `resources` (time-sliced, exposed by the
  operator's device plugin on `cluster-4`) plus `runtimeClassName: nvidia`
  (the RuntimeClass is created by the operator). The DRA `DeviceClass
  gpu` exists but is not the active path — the driver is not publishing
  `ResourceSlice`s, so no `resourceClaims` are used. See
  `kubernetes/apps/gpu-operator/README.md` and
  `kubernetes/apps/gpu-deviceclass/README.md`.
- **Envoy response compression breaks llama.cpp's web UI:** the global
  `BackendTrafficPolicy/envoy` (in `network`) sets Zstd/Brotli/Gzip
  compressors on every route; Envoy's compression filter strips the
  client's `Accept-Encoding` from upstream requests, and llama-server
  (full-cuda image) requires `Accept-Encoding: gzip` to serve its
  built-in web UI — web UI assets then respond
  `415 "Error: gzip is not supported by this browser"` while `/health`
  and `/models` keep working (they don't check). A route-scoped
  `BackendTrafficPolicy` fully replaces the global one, so it must
  repeat the global retry/keepalive/timeout settings (disabled
  `requestTimeout` is required for long generations) and omit the
  `compressor` field — see
  `kubernetes/apps/llama-cpp/README.md`.
- **A crash-looping `envoy-gateway` controller makes new HTTPRoutes look
  broken even when the manifests are correct.** The controller stops
  writing route status and new routes are never attached to a listener,
  while the data plane keeps serving the routes it already has. Symptom:
  `kubectl -n <ns> get httproute -o yaml` shows **no `status` field at
  all**. Check `kubectl -n network get pods` — if `envoy-gateway` is in
  `CrashLoopBackOff` (here: a stale pod whose network namespace could no
  longer reach the API server —
  `Get "https://<svc-ip>:443/api": dial tcp ... i/o timeout`), delete the
  pod; the replacement reconciles every route within seconds.
- **Live-tuned values must be encoded in the manifest.** A live
  `kubectl patch` of the Deployment (the 8Gi request / 22Gi limit memory
  tuning for the ~27B GGUF + 256k KV cache) is reverted by Flux on the
  next reconciliation; the working values now live in
  `deployment.yaml`.
- **Branch testing sources must not leak into production manifests:** the
  Kustomization was pointed at a test `GitRepository/llama-cpp` applied
  directly to the cluster (no manifest in this repo). Production
  manifests must use the standard `flux-system` source; the test
  GitRepository is deleted after the PR merges.
- **HF model downloads persist in the NFS cache PVC:** llama-server
  downloads GGUF repos into `/root/.cache/huggingface` (the 4Ti RWX NFS
  PVC) on first boot; models survive pod restarts. Keep PVC headroom in
  mind before adding large models, and give the startup probe a
  10-minute budget for the first NFS load.

### Migration Script Template

See `kubernetes/apps/sonarr/migrate-config.sh` for a working example. Key patterns:

```bash
# Scale down new deployment
kubectl --context <new> scale deployment/<app> -n <ns> --replicas=0

# Export from old cluster
kubectl --context <old> run <app>-config-export -n <ns> --rm -i \
  --image=alpine:3.20 --restart=Never -- \
  sh -c "cd /config && tar czf /export/sonarr-config.tar.gz . && touch /export/done" \
  --volume=pvc:<app>-config:/config:ro --volume=tmp:/export

# Wait for export to complete
kubectl --context <old> wait --for=jsonpath='{.metadata.name}' --timeout=300s pod/<app>-config-export -n <ns>

# Download tar
kubectl --context <old> cp <ns>/<app>-config-export:/export/sonarr-config.tar.gz /tmp/sonarr-config.tar.gz

# Upload to new cluster
kubectl --context <new> cp /tmp/sonarr-config.tar.gz <ns>/<app>-config-import:/config/sonarr-config.tar.gz

# Import on new cluster
kubectl --context <new> exec <app>-config-import -n <ns> -- \
  sh -c "cd /config && tar xzf sonarr-config.tar.gz && rm sonarr-config.tar.gz"

# Scale up new deployment
kubectl --context <new> scale deployment/<app> -n <ns> --replicas=1
```

### Post-Migration Documentation

After each migration, update this document with:

- New learnings or pitfalls discovered
- Any deviations from the standard process
- Updated storage class or network configurations
- New domain patterns or ingress changes

This ensures future migrations benefit from the experience gained.

## Use Case 6: Self-Hosted GitHub Runners (ARC Scale Sets)

Self-hosted GitHub Actions runners for all repos are deployed via the
`gha-runner-scale-set` model of the Actions Runner Controller (ARC), managed
entirely through Flux + SOPS in `kubernetes/apps/github-runners/`.

### Architecture

- **One controller** (`gha-runner-scale-set-controller` HelmRelease) in the
  `github-runners` namespace. It watches `AutoscalingRunnerSet` CRs in all
  namespaces and also creates/manages one **listener** Deployment per scale
  set.
- One `AutoscalingRunnerSet` per repo, each created by a
  `gha-runner-scale-set` HelmRelease (`kubernetes/apps/github-runners/github-runners/app/scale-set-<repo>.yaml`).
  The runner label equals `runnerScaleSetName` (the repo name, lowercased).

**No webhook and no Cloudflare Tunnel are required.** The scale-set listener
holds a persistent _outbound_ message session (WebSocket) to the GitHub
Actions backend — scaling events flow over that connection, so a NATed
homelab cluster needs no public ingress. (This differs from the legacy
`actions.summerwind.net` ARC model, which needed a webhook server reachable
from GitHub.)

### Authentication

- A single sops-encrypted Secret `gha-credentials` (key `github_token`) in
  `github-runners` feeds both the controller (`GITHUB_TOKEN` env) and every
  scale set (`githubConfigSecret`).
- The token must belong to the **repo owner**: on user-owned repos,
  collaborator accounts (even with `write`) cannot create runner registration
  tokens (`POST /repos/{owner}/{repo}/actions/runners/registration-token`
  requires admin, and user repos have no admin role for collaborators). The
  bot account `rafelbev-linus-bot` is therefore a `write` collaborator on all
  repos for PR/CI work, but runner registration uses the owner's PAT.
- **Secret rotation**: requires the age key (see Encryption Rules). Encrypt
  the new value with `sops --encrypt --in-place`, commit, push — Flux
  reconciles.

### Adding a Repo

1. Create `kubernetes/apps/github-runners/github-runners/app/scale-set-<name>.yaml`
   (copy an existing one; set `runnerScaleSetName` = repo name lowercased,
   `githubConfigUrl` = `https://github.com/rafelbev/<Repo>`).
2. Add the file to `github-runners/app/kustomization.yaml`.
3. Push — Flux deploys the scale set.
4. In workflows: `runs-on: <name>` (lowercased repo name).

### Operations

```bash
# Scale sets (one row per repo)
kubectl -n github-runners get ars

# Runners (ephemeral pods scale with pending jobs)
kubectl -n github-runners get pods -l actions.github.com/scale-set

# Controller / listener health
kubectl -n github-runners get deploy
flux get hr -n github-runners
```

### Pitfalls

- `minRunners: 0` / `maxRunners: 2` per repo — idle cost is only the
  listener pods; concurrent job capacity is bounded by cluster resources.
- `runnerScaleSetName` must be a valid K8s object name: repo names with
  uppercase letters are lowercased (e.g. `Chocolatey-Packages` →
  `chocolatey-packages`), which is also the `runs-on` label.
- The scale-set chart fails offline rendering without
  `controllerServiceAccount` set — it is set explicitly in every HR
  (`gha-runner-scale-set-controller-gha-rs-controller` in `github-runners`).
- The controller chart and scale-set chart versions are released in lockstep
  (`0.15.0`); bump both together.
- The `gha-credentials` Secret must exist in the cluster before runners can
  register — until it is present, the scale sets stay in a failed/degraded
  state and retry on each reconciliation.

## GitHub Actions CI (Workflows)

Workflows live in `.github/workflows/` and are linted by **zizmor** in two
places: locally as a lefthook pre-commit (`.lefthook.toml` → `zizmor --offline
{staged_files}`) and in CI (`.github/workflows/zizmor.yaml`), so PRs that
bypass local hooks (force-push, external contributors, bot PRs) are still
audited.

### Workflows

- **Flate** (`.github/workflows/flate.yaml`) — runs `flate test all` on PRs to
  `main`, only when `kubernetes/**` changes. GitOps sanity check.
- **Label Sync** (`.github/workflows/label-sync.yaml`) — syncs repo labels from
  `.github/labels.yaml` on push to `main` / `workflow_dispatch`.
- **Zizmor** (`.github/workflows/zizmor.yaml`) — CI security lint of all
  workflow files. Runs on PRs + push to `main`.

### Best-practice conventions

- **SHA-pin every action** (with a `# vX.Y.Z` comment); Renovate keeps them
  current via the `github-actions` manager group.
- **Least-privilege permissions**: `contents: read` by default; grant write
  only at the job level that needs it (workflow-level `permissions: {}`).
- **`actions/checkout` with `persist-credentials: false`** everywhere.
- **Concurrency** groups keyed on workflow + PR/ref with
  `cancel-in-progress: true` for re-runnable jobs.

### Pitfalls

- **Never commit secrets.** A plaintext `github-push-token.txt` was found
  tracked in git and has been removed from tracking + gitignored. Any
  token/credential file must be gitignored; cluster-bound secrets go in
  SOPS-encrypted `.sops.yaml` files only. A secret that has already been
  pushed to git history must be **rotated**, not just removed.
- The **zizmor CI** job uses `runs-on: ubuntu-latest` (the `zizmor-action`
  release in use is incompatible with `ubuntu-slim`) and sets
  `advanced-security: false` (private repo, no GitHub Advanced Security).

## Testing and Previewing Changes

Before merging a PR, preview the changes that will be applied to the cluster.

### Preview Flux Kustomization Changes

Use `flux diff kustomization` to preview local changes as they would be applied:

```bash
# Preview changes for a specific kustomization
flux diff kustomization <name> --path ./kubernetes/apps/<app>/<app>/app

# Preview with local sources (for testing branch changes)
flux diff kustomization <name> \
  --path ./kubernetes/apps/<app>/<app>/app \
  --local-sources GitRepository/flux-system/flux-system=.

# Recursive diff for all kustomizations
flux diff kustomization <name> --path ./kubernetes/apps --recursive
```

### Preview Helm Chart Changes

```bash
# Render Helm chart templates locally
helm template <release-name> <chart-path> -f values.yaml

# Compare rendered manifests with cluster state
helm template <release-name> <chart-path> -f values.yaml | kubectl diff -f -
```

### Preview Talos Configuration Changes

```bash
# Show pending Talos config changes without applying
just talos diff

# Render Talos configs to inspect
just talos render
```

### Testing Workflow for PRs

1. **Check out the PR branch**:

    ```bash
    git checkout <pr-branch>
    ```

2. **Preview the changes**:

    ```bash
    # For application changes
    flux diff kustomization <app-name> --path ./kubernetes/apps/<app>/<app>/app

    # For Talos changes
    just talos diff
    ```

3. **Review the diff output**:
    - Check for unexpected resource changes
    - Verify no resources are being deleted unintentionally
    - Confirm configuration values are correct

4. **Apply to staging** (if available) or merge with caution

### PR Review Checklist Addition

- [ ] Changes previewed with `flux diff kustomization` or `just talos diff`
- [ ] Diff output reviewed for unexpected changes
- [ ] No unintended resource deletions

### Encryption Rules

- All secrets are encrypted with SOPS using the age key defined in `.sops.yaml`
- **Never change the age key recipient** without re-encrypting ALL sops files with the new key
- SOPS files must be encrypted before committing to git

### Common Commands

```bash
# Encrypt a file
sops --encrypt --in-place file.yaml

# Decrypt a file (for inspection)
sops --decrypt file.yaml

# Edit a sops-encrypted file (opens in editor, re-encrypts on save)
sops --edit file.sops.yaml
```

**Pitfalls**:

- **Wrong age key**: If you re-encrypt files with a different age key than the one in `.sops.yaml`, decryption will fail for everyone. This happened in PR #37 — all sops files were re-encrypted with a different recipient, causing cluster-wide decryption failures.
- **Unencrypted secrets in git**: Always verify sops files are encrypted before committing. Run `sops --decrypt` on each file to verify it decrypts correctly.
- **Secret rotation**: When rotating secrets, update the sops file and push. Flux will automatically reconcile.

## Debugging Checklist

When something isn't working:

1. **Check Flux status**:

    ```bash
    flux get sources git -A
    flux get ks -A
    flux get hr -A
    ```

2. **Force Flux sync** (if needed):

    ```bash
    just kube reconcile
    ```

3. **Check pods**:

    ```bash
    kubectl -n <namespace> get pods -o wide
    ```

4. **Check pod logs**:

    ```bash
    kubectl -n <namespace> logs <pod-name> -f
    ```

5. **Describe resources**:

    ```bash
    kubectl -n <namespace> describe <resource> <name>
    ```

6. **Check namespace events**:

    ```bash
    kubectl -n <namespace> get events --sort-by='.metadata.creationTimestamp'
    ```

7. **Check Cilium status**:
    ```bash
    kubectl -n kube-system exec ds/cilium --container cilium-agent -- cilium status
    ```

## Talos-Specific Debugging

```bash
# Check node status
talosctl nodes

# Check node events
talosctl get events

# Check kubelet logs
talosctl kubelet logs

# Check system services
talosctl get services
```

### Diagnosing a stuck boot (the dependency chain)

When a node is stuck at `stage: booting` with `Kubelet: Unhealthy`, read the
**kernel boot log** — it shows the full service dependency chain and the exact
failing task:

```bash
talosctl logs kernel --nodes <ip> --tail 200
```

The boot gates everything on a chain: `writeUserFiles` / `unattended install` →
`cri` (waiting for `sandboxd` to register) → `kubelet` / `etcd` / `trustd`. If
`writeUserFiles` fails, the whole chain stalls while `apid` stays healthy
(port 5000 open). The kernel log names the failing task verbatim, e.g.
`task writeUserFiles (1/1): writeUserFiles failed ... create operation not
allowed outside of /var`.

### v1.14 resource names (for `talosctl get`)

The v1.14 API uses resource types that differ from older versions. The full list
is `talosctl get rd --nodes <ip>`. Commonly used:

| Resource                  | What it tells you                                                  |
| ------------------------- | ------------------------------------------------------------------ |
| `machinestatus`           | `stage` (booting/running), `ready`, `created`/`updated` timestamps |
| `containerinstancestatus` | Which system containers (kubelet/etcd/trustd) are actually running |
| `containerspec`           | Which containers machined is _supposed_ to create                  |
| `machineconfig`           | The exact config stored on the node (compare to rendered)          |
| `etcdmember`              | The node's etcd member ID (changes after rejoin)                   |

`containerinstancestatus` empty + `machinestatus` stuck = machined isn't
spawning system containers; read the kernel log to find why.

### Log access

```bash
# List available log sources
talosctl logs --nodes <ip>

# Read a specific service log
talosctl logs <service> --nodes <ip> --tail 100
# services: kernel, apid, machined, containerd, kubelet, etcd, trustd, ...
```

## Renovate and Dependency Management

- Renovate automatically opens PRs for dependency updates
- Renovate is configured in `.renovaterc.json5`
- This repo runs Renovate **every day** (`schedule: ["at any time"]`)
- Merging a Renovate PR typically triggers Flux to apply the update

### Low-risk auto-merge

Renovate **auto-merges only low-risk updates** and leaves everything else for a
human. An update is "low risk" when **both** of these hold:

1. **Not a breaking major change** — the update type is `minor`, `patch`,
   `digest`, or `pin` (never `major`), and it is not a pre-1.0 (`0.x`) package,
   which may break at any time under SemVer.
2. **No manual intervention required** — Renovate has not flagged the update as
   breaking (`isBreaking != true`) based on the upstream changelog / release
   notes.

These are encoded in `.renovaterc.json5`:

```json5
{
  matchUpdateTypes: ["minor", "patch", "digest", "pin"],
  matchJsonata: ["isBreaking != true"],
  matchCurrentVersion: "!/^0/",
  automerge: true,
},
{
  matchIsBreaking: true,
  automerge: false,
}
```

- The inherited `:automergeBranch` preset supplies `automergeType: "branch"`, so
  a low-risk update is **pushed straight to the base branch** (no PR to click)
  once CI is green. `config:recommended` / `config:base` do **not** enable
  `automerge`, so nothing auto-merges unless a rule explicitly sets it.
- `isBreaking` is decided independently of the update type from release-notes /
  changelog analysis, so a `minor` bump whose notes describe a breaking change is
  held for a human (the second `packageRule` re-asserts `automerge: false` to stay
  safe even if a future default changes).
- **Majors, `0.x` bumps, rollbacks, replacements, and breaking updates are never
  auto-merged** — they always get a PR for review. CI staying green is the
  backstop for everything that does auto-merge.

**Validating a config change** (the `renovate` CLI needs a GitHub token and a
Node v24; the validator binary is the clean path):

```bash
npx -y renovate@44.158.2-config-validator .renovaterc.json5 --strict
```

**Pitfalls**:

- **Major version bumps**: Major version bumps may include breaking changes. Review the PR carefully before merging.
- **Coordinated upgrades**: Some dependencies must be upgraded together (e.g., Talos and Kubernetes versions).
- **Schedule syntax**: `"every day"` is NOT a valid schedule — Renovate parses
  schedules with cron syntax (or the deprecated `@breejs/later` text syntax), and
  an unparseable string makes the **whole config invalid** (Renovate stops
  creating PRs). Use `"at any time"` for a daily schedule (the explicit default),
  or a cron expression such as `* * * * *`. Validate with the config validator
  after any change (above).

## Important Files Reference

| File                                                   | Purpose                                  |
| ------------------------------------------------------ | ---------------------------------------- |
| `talos/topf.yaml`                                      | Node inventory, versions, kernel modules |
| `talos/secrets.sops.yaml`                              | Talos cluster secrets                    |
| `.sops.yaml`                                           | SOPS encryption configuration            |
| `.mise/config.toml`                                    | Tool versions                            |
| `justfile`                                             | Task runner recipes                      |
| `kubernetes/flux/cluster/ks.yaml`                      | Top-level Flux Kustomization             |
| `kubernetes/components/sops/cluster-secrets.sops.yaml` | Shared cluster secrets                   |
| `talos/SPECIFICATION.md`                               | Talos schematic specification            |

## When in Doubt

1. Check the Flux status first — most issues are Flux sync problems
2. Check the pod logs and events
3. Review the relevant just recipes
4. Consult the Talos and Flux documentation
5. If all else fails, check the GitHub repository's Discussions and Issues
