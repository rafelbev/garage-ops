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

1. **Export the application manifests** from the source cluster:

```bash
kubectl get all,cm,secret,pvc,ingress -n <namespace> -o yaml > app-export.yaml
```

2. **Review and adapt the manifests**:
    - Remove cluster-specific fields (UIDs, resource versions, status)
    - Update image pull secrets if needed
    - Update storage classes to match this cluster's StorageClasses
    - Update ingress annotations to use this cluster's ingress controller

3. **Templating with GitOps**:
    - Move hardcoded values to `cluster-secrets.sops.yaml` or Helm values
    - Use Flux's `postBuild.substituteFrom` for secret substitution
    - Parameterize environment-specific settings

4. **Deploy using Use Case 3 pattern**

**Pitfalls**:

- **Storage classes**: The source cluster's StorageClasses may not exist here. Map to `truenas-nfs` or `truenas-iscsi`.
- **Ingress controller**: This cluster uses Envoy Gateway. Adapt ingress resources accordingly.
- **Secrets**: Do not copy secrets directly. Re-create them using SOPS encryption.
- **Network policies**: Cilium network policies may differ between clusters.
- **RBAC**: Service accounts and RBAC may need adjustment.

## SOPS and Secrets Management

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
