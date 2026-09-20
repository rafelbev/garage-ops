# TrueNAS CSI Storage

This directory deploys the [TrueNAS CSI Driver](https://github.com/truenas/truenas-csi) to provide dynamic persistent volume provisioning for the Kubernetes cluster.

## Storage Classes

| StorageClass    | Protocol | Access Mode         | Use Case                                           |
| --------------- | -------- | ------------------- | -------------------------------------------------- |
| `truenas-nfs`   | NFS      | ReadWriteMany (RWX) | Shared volumes, multiple readers, home directories |
| `truenas-iscsi` | iSCSI    | ReadWriteOnce (RWO) | Databases, single-writer workloads, low latency    |

## TrueNAS Pre-Setup

Before deploying, prepare your TrueNAS instance:

### 1. Enable API Access

- Navigate to **Settings → API Access**
- Ensure WebSocket API is enabled (default port 443)
- Note the API URL: `wss://<truenas-ip>/api/current`

### 2. Create API Key

- Click your profile avatar → **API Keys**
- Click **Generate**
- Copy the key (starts with `truenas:`)
- This key needs access to: pools, datasets, NFS shares, iSCSI targets

### 3. Configure ZFS Pool

- Ensure at least one ZFS pool exists (e.g., `tank`)
- Note the pool name for configuration

### 4. Enable NFS Service

- Navigate to **Services → NFS**
- Start the NFS service
- Ensure NFS is enabled to start on boot

### 5. Enable iSCSI Service

- Navigate to **Services → iSCSI**
- Start the iSCSI service
- Ensure iSCSI is enabled to start on boot
- Note the iSCSI portal address (default port 3260)

### 6. Firewall Rules

Ensure the following ports are open from Kubernetes nodes to TrueNAS:

- **443/tcp** - TrueNAS API (WebSocket)
- **2049/tcp** - NFS
- **3260/tcp** - iSCSI

## Kubernetes Node Requirements

### For iSCSI volumes

The `open-iscsi` package must be installed on all worker nodes. On Talos Linux, this is included by default.

### For NFS volumes

No additional packages required.

## Configuration

### Update TrueNAS Connection Details

Edit `truenas-csi/app/helmrelease.yaml` and replace:

- `wss://TRUENAS_IP/api/current` with your TrueNAS API URL

### Set API Key

The API key is stored in a sops-encrypted secret. To update it:

```bash
# Edit the secret (will be encrypted automatically)
sops --in-place kubernetes/apps/truenas-csi/truenas-csi/app/secret.sops.yaml
```

Replace `YOUR_TRUENAS_API_KEY_HERE` with your actual API key.

### Pool Configuration

The default pool is set to `tank` in `helmrelease.yaml`. Change `defaultPool` if your pool has a different name.

## Usage Examples

### NFS (ReadWriteMany)

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
    name: shared-data
spec:
    accessModes:
        - ReadWriteMany
    storageClassName: truenas-nfs
    resources:
        requests:
            storage: 10Gi
```

### iSCSI (ReadWriteOnce)

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
    name: database-data
spec:
    accessModes:
        - ReadWriteOnce
    storageClassName: truenas-iscsi
    resources:
        requests:
            storage: 20Gi
```

## Verification

After deployment, verify the driver is running:

```bash
kubectl get pods -n truenas-csi
kubectl get csidrivers
kubectl get storageclass
```

Expected output:

- `truenas-csi-controller-*` pod running
- `truenas-csi-node-*` pods running on each node
- `truenas-nfs` and `truenas-iscsi` StorageClasses available

## Troubleshooting

### Pods not mounting volumes

- Check that NFS/iSCSI services are running on TrueNAS
- Verify firewall rules allow traffic from K8s nodes
- Check CSI pod logs: `kubectl logs -n truenas-csi -l app.kubernetes.io/name=truenas-csi`

### iSCSI volumes not attaching

- Ensure `open-iscsi` is installed on nodes
- Check iSCSI service is running on TrueNAS
- Verify network connectivity to port 3260

### NFS volumes not mounting

- Check NFS service is running on TrueNAS
- Verify network connectivity to port 2049
- Check TrueNAS NFS export permissions
