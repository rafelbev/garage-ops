# Skill: Talos and Kubernetes Upgrade

Use this skill when upgrading Talos or Kubernetes versions in the garage-ops cluster.

## Prerequisites

- Access to the garage-ops repository
- `mise` installed and configured
- `just` installed and configured
- `talosctl` and `flux` available via mise

## Procedure

### Step 1: Check Current Versions

```bash
# Check current Talos version
talosctl version

# Check current Kubernetes version
kubectl version

# Check versions in topf.yaml
grep -E "talosVersion|kubernetesVersion" talos/topf.yaml
```

### Step 2: Determine Target Versions

- Check the [Talos release notes](https://www.talos.dev/latest/releases/) for the latest stable version
- Verify Kubernetes version compatibility with the target Talos version
- Check Helm chart compatibility for all deployed applications

### Step 3: Update Configuration

1. Update `talosVersion` in `talos/topf.yaml`
2. Update `kubernetesVersion` in `talos/topf.yaml` (if upgrading Kubernetes)
3. Update `talosctl` version in `.mise/config.toml` to match `talosVersion`
4. Update `kubectl` version in `.mise/config.toml` to match `kubernetesVersion`

### Step 4: Check for Deprecated Configuration

Review the Talos release notes for deprecated or removed configuration options. Common changes:

- Removed kernel module options
- Changed API endpoints
- Renamed configuration fields

### Step 5: Apply Changes

```bash
# Update local tooling
mise install

# Preview Talos config changes
just talos diff

# Upgrade Talos (all nodes, one at a time)
just talos upgrade

# Upgrade Kubernetes (if applicable)
just talos upgrade-k8s
```

### Step 6: Verify

```bash
# Check Talos version
talosctl version

# Check Kubernetes version
kubectl version

# Check cluster health
kubectl get nodes
kubectl get pods --all-namespaces

# Check Flux status
flux get sources git -A
flux get ks -A
flux get hr -A
```

### Step 7: Commit and Push

```bash
git add talos/topf.yaml .mise/config.toml .mise/mise.lock
git commit -m "chore: upgrade Talos to X.Y.Z and Kubernetes to A.B.C"
git push
```

## Pitfalls to Avoid

1. **Version incompatibility**: Talos and Kubernetes versions must be compatible. Check the [Talos versioning docs](https://www.talos.dev/latest/versioning/).

2. **Deprecated patches**: Some configuration patches may be deprecated in newer Talos versions. Example: `admissionControl` patch was removed in Talos 1.14.1.

3. **Schematic changes**: If the upgrade changes the default schematic, create a new schematic at [factory.talos.dev](https://factory.talos.dev) and update the `schematicId` in `topf.yaml`.

4. **Kernel modules**: If custom kernel modules are required, they must be included in the new schematic. See `talos/SPECIFICATION.md` for the complete list.

5. **Helm chart compatibility**: After upgrading, verify all Helm charts are compatible. Renovate may have already opened PRs for chart updates.

6. **Rolling upgrade**: `talosctl upgrade-k8s` performs a rolling upgrade. Monitor with `kubectl get pods --all-namespaces --watch`.

## Rollback Plan

If the upgrade fails:

1. Revert `talosVersion` and `kubernetesVersion` in `talos/topf.yaml`
2. Revert `talosctl` and `kubectl` versions in `.mise/config.toml`
3. Run `mise install`
4. Run `just talos upgrade` to downgrade Talos
5. Run `just talos upgrade-k8s` to downgrade Kubernetes (if applicable)

## References

- [Talos Upgrade Guide](https://www.talos.dev/latest/talos-guides/upgrading/)
- [Kubernetes Upgrade Guide](https://kubernetes.io/docs/tasks/administer-cluster/upgrade-cluster-manually/)
- `AGENTS.md` — Main project documentation
