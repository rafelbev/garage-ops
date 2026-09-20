# Skill: Debug Cluster Issues

Use this skill when troubleshooting issues with the garage-ops cluster.

## Prerequisites

- Access to the garage-ops repository
- `kubectl` configured with the cluster kubeconfig
- `flux` CLI available via mise
- `talosctl` configured (for Talos-level debugging)

## Debugging Checklist

### Step 1: Check Flux Status

```bash
# Check Git source
flux get sources git -A

# Check Kustomizations
flux get ks -A

# Check HelmReleases
flux get hr -A
```

**What to look for**:

- `Ready` condition should be `True`
- `Last Applied Revision` should match the latest git commit
- Any `Reconciling` status for extended periods indicates a problem

### Step 2: Force Flux Sync (if needed)

```bash
just kube reconcile
```

### Step 3: Check Node Status

```bash
kubectl get nodes -o wide
```

**What to look for**:

- All nodes should be `Ready`
- Check for `NotReady`, `SchedulingDisabled`, or other conditions

### Step 4: Check Pod Status

```bash
# All pods
kubectl get pods --all-namespaces -o wide

# Specific namespace
kubectl -n <namespace> get pods -o wide
```

**What to look for**:

- Pods in `CrashLoopBackOff`, `ImagePullBackOff`, `Pending`, or `Error` states
- Pods with high restart counts

### Step 5: Check Pod Logs

```bash
kubectl -n <namespace> logs <pod-name> -f
```

**What to look for**:

- Error messages
- Stack traces
- Connection failures
- Configuration errors

### Step 6: Describe Resources

```bash
kubectl -n <namespace> describe <resource> <name>
```

**What to look for**:

- Events section with warnings or errors
- Conditions not met
- Resource constraints

### Step 7: Check Namespace Events

```bash
kubectl -n <namespace> get events --sort-by='.metadata.creationTimestamp'
```

**What to look for**:

- Recent warning or error events
- Resource allocation failures
- Network issues

### Step 8: Check Cilium Status

```bash
kubectl -n kube-system exec ds/cilium --container cilium-agent -- cilium status
```

**What to look for**:

- `KVStore` should be `Ok`
- `Node monitoring` should be `Enabled`
- `Cluster mesh` should be `Disabled` (unless using mesh)

### Step 9: Check Talos Status (if needed)

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

## Common Issues and Solutions

### Pods Stuck in `Pending`

**Possible causes**:

- Insufficient resources
- Node affinity issues
- Storage class not available

**Diagnosis**:

```bash
kubectl -n <namespace> describe pod <pod-name>
kubectl get nodes -o wide
kubectl get storageclass
```

### Pods in `CrashLoopBackOff`

**Possible causes**:

- Application crash
- Configuration error
- Missing secrets or configmaps

**Diagnosis**:

```bash
kubectl -n <namespace> logs <pod-name> -f
kubectl -n <namespace> describe pod <pod-name>
```

### Flux Not Reconciling

**Possible causes**:

- Git repository unreachable
- SOPS decryption failure
- Invalid manifests

**Diagnosis**:

```bash
flux get sources git flux-system -A
flux get ks -A
flux logs -f
```

### iSCSI Volume Issues

**Possible causes**:

- iSCSI kernel modules not loaded
- Network connectivity to TrueNAS
- TrueNAS iSCSI service not running

**Diagnosis**:

```bash
# Check kernel modules
talosctl --nodes <node-ip> exec -- lsmod | grep iscsi

# Check network connectivity
kubectl -n troubleshooting exec -it <netshoot-pod> -- ping <truenas-ip>
kubectl -n troubleshooting exec -it <netshoot-pod> -- nc -zv <truenas-ip> 3260
```

### DNS Resolution Issues

**Possible causes**:

- CoreDNS not running
- Upstream DNS misconfigured
- Split DNS not working

**Diagnosis**:

```bash
# Check CoreDNS
kubectl -n kube-system get pods -l k8s-app=kube-dns

# Test DNS resolution
kubectl -n troubleshooting exec -it <netshoot-pod> -- dig <hostname>
```

## References

- [Kubernetes Troubleshooting Guide](https://kubernetes.io/docs/tasks/debug-application-cluster/troubleshooting/)
- [Flux Troubleshooting Guide](https://fluxcd.io/docs/guides/troubleshooting/)
- [Talos Troubleshooting Guide](https://www.talos.dev/latest/talos-guides/troubleshooting/)
- `AGENTS.md` — Main project documentation
