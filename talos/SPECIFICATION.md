# Talos Schematic Specification

This document defines the custom Talos schematic required for this cluster.
Use this specification when creating or rebuilding the schematic at [factory.talos.dev](https://factory.talos.dev).

## Schematic ID

Current schematic ID: `ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515`

> **Note**: After creating a new schematic with additional modules, update the `schematicId` field in `topf.yaml` for all nodes.

## Talos Version

- **Version**: v1.14.1 (must match `talosVersion` in `topf.yaml`)
- **Architecture**: amd64

## Kernel Modules

The following kernel modules must be included in the schematic:

### iSCSI Support (Required)

| Module                 | Purpose                  |
| ---------------------- | ------------------------ |
| `iscsi_tcp`            | iSCSI over TCP transport |
| `libiscsi`             | iSCSI library            |
| `libiscsi_tcp`         | iSCSI TCP library        |
| `scsi_transport_iscsi` | SCSI transport for iSCSI |

### Existing Modules (Preserve)

Review the current schematic at factory.talos.dev using the schematic ID above to identify any existing modules or system extensions. Preserve all existing modules when creating the new schematic.

## System Extensions

Review the current schematic for any system extensions. Preserve all existing extensions when creating the new schematic.

## Build Instructions

1. Visit [https://factory.talos.dev](https://factory.talos.dev)
2. Select version **v1.14.1**
3. Select architecture **amd64**
4. Add the iSCSI kernel modules listed above
5. Preserve any existing modules and system extensions from the current schematic
6. Build the schematic
7. Copy the new schematic ID
8. Update `topf.yaml` with the new schematic ID

## Kernel Modules Configuration

The Talos machine config must load the iSCSI modules at boot. This is configured in `topf.yaml` under each node's `data.kernelModules` array:

```yaml
data:
    kernelModules:
        - iscsi_tcp
        - libiscsi
        - libiscsi_tcp
        - scsi_transport_iscsi
```

This is applied via the `talos/all/61-kernel-modules.yaml.tpl` patch file.

## Verification

After deploying the new schematic, verify iSCSI support:

```bash
# Check kernel modules are loaded
talosctl --nodes <node-ip> kexec --initramfs ...  # or reboot
talosctl --nodes <node-ip> exec -- lsmod | grep iscsi

# Check iSCSI initiator is available
talosctl --nodes <node-ip> exec -- cat /etc/iscsi/iscsid.conf
```

## Future Module Additions

When adding new kernel modules in the future:

1. Add the module to this specification document
2. Create a new schematic at factory.talos.dev including ALL modules listed here
3. Update the schematic ID in `topf.yaml`
4. Add the module name to each node's `data.kernelModules` array in `topf.yaml`
5. Upgrade the Talos nodes

**Never omit existing modules when creating a new schematic.** Always review this document and include all listed modules.
