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

### Key Learnings from Radarr Migration

- **Size iSCSI config PVCs generously**: The Radarr config directory was 1.6GB after compression (including media covers and database). A 1Gi PVC was too small; 2Gi was needed. Always estimate the source config size before creating the target PVC. Check with `du -sh` on the source PVC contents.
- **Verify tar integrity after transfer**: Large tarballs transferred via `kubectl cp` can be corrupted. Verify with `tar -tzf` on both source and destination before attempting extraction.
- **Config import can fail silently**: The import pod may fail due to "No space left on device" without obvious error messages. Check pod logs and PVC capacity.

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

## Renovate and Dependency Management

- Renovate automatically opens PRs for dependency updates
- Renovate is configured in `.renovaterc.json5`
- By default, Renovate is active on weekends
- Merging a Renovate PR typically triggers Flux to apply the update

**Pitfalls**:

- **Major version bumps**: Major version bumps may include breaking changes. Review the PR carefully before merging.
- **Coordinated upgrades**: Some dependencies must be upgraded together (e.g., Talos and Kubernetes versions).

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
