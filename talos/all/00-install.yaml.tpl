machine:
  install: null
---
apiVersion: v1alpha1
kind: UnattendedInstallConfig
installer:
    image: "factory.talos.dev/metal-installer/{{ .SchematicID }}:{{ .TalosVersion }}"
provisioning:
    diskSelector:
        match: "disk.dev_path == \"{{ .Node.Data.installDisk }}\""
    wipe: false
