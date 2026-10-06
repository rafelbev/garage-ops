machine:
  files:
    - op: create
      path: /etc/iscsi/initiatorname.iscsi
      content: |
        InitiatorName={{ .Data.iscsiInitiatorPrefix }}:{{ .Node.Host }}
      permissions: 0o644
