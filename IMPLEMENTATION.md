# iSCSI Implementation Summary

## Completed

### 1. TOPF Configuration Updated

- Added iSCSI kernel modules to all 3 nodes in `talos/topf.yaml`:
    - `iscsi_tcp`
    - `libiscsi`
    - `libiscsi_tcp`
    - `scsi_transport_iscsi`
- Modules are applied via existing `talos/all/61-kernel-modules.yaml.tpl` patch

### 2. Schematic Specification Documented

- Created `talos/SPECIFICATION.md` with complete schematic requirements
- Documents all required kernel modules for future reference
- Provides instructions for creating new schematics

### 3. Documentation Updated

- Updated `kubernetes/apps/truenas-csi/README.md` with Talos-specific iSCSI requirements
- Clarified that default Talos schematic does NOT include iSCSI support

### 4. Flux Configuration Verified

- `truenas-csi` Flux Kustomizations are properly configured
- Cluster-level `cluster-apps` Kustomization will pick up the truenas-csi directory
- Storage classes (`truenas-nfs`, `truenas-iscsi`) are defined
- truenas-csi HelmRelease is configured with TrueNAS endpoint

## Remaining Steps (Require User Action)

### Step 1: Create Custom Talos Schematic

1. Visit [https://factory.talos.dev](https://factory.talos.dev)
2. Select version **v1.14.1** and architecture **amd64**
3. Review the current schematic (`ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515`) to identify existing modules/extensions
4. Add the iSCSI kernel modules:
    - `iscsi_tcp`
    - `libiscsi`
    - `libiscsi_tcp`
    - `scsi_transport_iscsi`
5. Preserve all existing modules and system extensions
6. Build the schematic and copy the new schematic ID

### Step 2: Update Schematic ID

Update `talos/topf.yaml` with the new schematic ID for all nodes:

```yaml
schematicId: "<NEW_SCHEMATIC_ID>"
```

### Step 3: Upgrade Talos Nodes

```bash
just talos upgrade
```

Or per-node:

```bash
just talos upgrade-node cluster-0
just talos upgrade-node cluster-1
just talos upgrade-node cluster-2
```

### Step 4: Verify iSCSI Support

```bash
# Check kernel modules are loaded
talosctl --nodes 172.20.17.193 exec -- lsmod | grep iscsi

# Check iSCSI initiator configuration
talosctl --nodes 172.20.17.193 exec -- cat /etc/iscsi/iscsid.conf
```

### Step 5: Test truenas-csi

```bash
# Check truenas-csi pods are running
kubectl get pods -n truenas-csi

# Check storage classes
kubectl get storageclass

# Test iSCSI volume provisioning
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-iscsi
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: truenas-iscsi
  resources:
    requests:
      storage: 1Gi
EOF

# Verify PVC is bound
kubectl get pvc test-iscsi
```

## Files Modified

| File                                    | Change                                   |
| --------------------------------------- | ---------------------------------------- |
| `talos/topf.yaml`                       | Added iSCSI kernel modules to all nodes  |
| `talos/SPECIFICATION.md`                | New: Schematic specification document    |
| `kubernetes/apps/truenas-csi/README.md` | Updated with Talos-specific requirements |
| `ANALYSIS.md`                           | New: Initial analysis document           |

## Important Notes

- **Schematic ID**: The current schematic ID (`ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515`) does NOT include iSCSI modules. A new schematic must be created.
- **Node Reboot**: Upgrading to the new schematic requires node reboot.
- **Rollback**: Keep the old schematic ID available for rollback if needed.
- **Network**: Ensure ports 443 (API) and 3260 (iSCSI) are reachable from all nodes to the TrueNAS server.
