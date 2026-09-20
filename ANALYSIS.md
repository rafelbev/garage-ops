# iSCSI Support Analysis for Talos Nodes

## Current State

The cluster is a 3-node Talos Linux (v1.14.1) + Kubernetes (v1.37.0) setup using TOPF for configuration management. The `truenas-csi` Flux Kustomization is already defined with:

- **StorageClasses**: `truenas-nfs` (RWX) and `truenas-iscsi` (RWO)
- **HelmRelease**: truenas-csi v1.3.0 pointing to `wss://fileserver.intranet.neo-tix.com/api/current`
- **API Key**: Stored in sops-encrypted secret `truenas-csi-secret`

However, **Talos nodes currently lack iSCSI initiator support** - the default Talos schematic does not include iSCSI kernel modules or userspace tools.

## What's Required

### 1. Custom Talos Schematic with iSCSI Kernel Modules

The default schematic (`ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515`) does not include iSCSI support. A custom schematic must be created via the [Talos Image Factory](https://factory.talos.dev) or built from source.

**Required kernel modules:**

| Module                 | Purpose                  |
| ---------------------- | ------------------------ |
| `iscsi_tcp`            | iSCSI over TCP transport |
| `libiscsi`             | iSCSI library            |
| `libiscsi_tcp`         | iSCSI TCP library        |
| `scsi_transport_iscsi` | SCSI transport for iSCSI |

**Optional (for multipath):**

| Module         | Purpose                 |
| -------------- | ----------------------- |
| `dm_multipath` | Device mapper multipath |
| `dm_mod`       | Device mapper core      |

### 2. Userspace iSCSI Initiator

Talos needs the `open-iscsi` userspace package. In Talos, this is included via:

- A custom schematic that bundles the `open-iscsi` package, OR
- System extensions (if available for iSCSI)

### 3. Talos Machine Configuration

Add kernel modules to the Talos machine config via `machine.kernel.modules`:

```yaml
machine:
    kernel:
        modules:
            - name: iscsi_tcp
            - name: libiscsi
            - name: libiscsi_tcp
            - name: scsi_transport_iscsi
```

This can be done via:

- The existing `61-kernel-modules.yaml.tpl` patch (populating `kernelModules` in `topf.yaml`)
- A new dedicated patch file

### 4. Network Considerations

Ensure the following ports are reachable from all Talos nodes to the TrueNAS server:

- **443/tcp** - TrueNAS API (WebSocket)
- **3260/tcp** - iSCSI target

The nodes are on `172.20.17.128/25` with gateway `172.20.17.129`.

### 5. CSI Driver Configuration

The `truenas-csi` HelmRelease is already configured. The node plugin pods need:

- Access to `/dev` for block device management
- The iSCSI initiator running on the host

## Implementation Steps

### Step 1: Create Custom Talos Schematic

1. Visit [Talos Image Factory](https://factory.talos.dev)
2. Select version `v1.14.1` (matching current cluster)
3. Add iSCSI kernel modules to the schematic
4. Note the new schematic ID

### Step 2: Update TOPF Configuration

Update `topf.yaml` to:

1. Change `schematicId` to the new custom schematic ID
2. Add iSCSI kernel modules to each node's `data.kernelModules`

### Step 3: Update Talos Machine Config

Either:

- Populate `kernelModules` in `topf.yaml` nodes (uses existing `61-kernel-modules.yaml.tpl`)
- Or create a new patch file `talos/all/62-iscsi-kernel-modules.yaml`

### Step 4: Reinstall/Upgrade Talos Nodes

```bash
just talos upgrade  # or per-node: just talos upgrade-node cluster-0
```

### Step 5: Verify iSCSI Support

```bash
# Check kernel modules are loaded
talosctl --nodes <node-ip> kexec --initramfs ...  # or reboot

# Check iSCSI initiator is available
talosctl --nodes <node-ip> exec -- cat /etc/iscsi/iscsid.conf
```

### Step 6: Deploy truenas-csi via Flux

Ensure the Flux Kustomization for `truenas-csi` is applied:

```bash
flux get kustomizations -A | grep truenas-csi
```

## Risks and Considerations

1. **Custom schematic maintenance**: Custom schematics need to be rebuilt when upgrading Talos versions
2. **Node reboot required**: Kernel module changes require node reboot
3. **Rollback plan**: Keep the old schematic ID available for rollback
4. **Network reliability**: iSCSI is sensitive to network latency and packet loss
5. **TrueNAS configuration**: Ensure iSCSI service is running and target is properly configured

## Alternative Approaches

### Option A: NFS Only (Simpler)

Skip iSCSI entirely and use only the `truenas-nfs` storage class. No kernel module changes needed.

### Option B: Local Storage + Replication

Use local SSDs with Rook-Ceph or Longhorn for replication. More complex but no external dependency.

### Option C: iSCSI via CSI Node Plugin

Some CSI drivers bundle their own iSCSI initiator in the node plugin container. Check if truenas-csi supports this mode.

## Recommended Approach

**Option C first, then Option A (custom schematic) if needed.**

1. First, deploy the truenas-csi driver as-is and test with NFS volumes
2. Test iSCSI volumes - if the CSI node plugin handles iSCSI internally, no kernel changes needed
3. If kernel modules are required, create the custom schematic and update nodes

## Files to Modify

| File                                                | Change                                             |
| --------------------------------------------------- | -------------------------------------------------- |
| `topf.yaml`                                         | Update `schematicId` and add `kernelModules`       |
| `talos/all/61-kernel-modules.yaml.tpl`              | Already exists, will use `kernelModules` from topf |
| (Optional) `talos/all/62-iscsi-kernel-modules.yaml` | New patch file if not using topf approach          |
