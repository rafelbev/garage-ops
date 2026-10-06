# Remove the default node-role.kubernetes.io/control-plane:NoSchedule taint
# from control-plane nodes so workloads can be scheduled on them.
#
# Multi-doc strategic-merge patch (per topf's talos-v114-migration skill).
# `$patch: delete` on the specific taint key is more precise than
# `taints: {}` and survives if other taints are added later.
apiVersion: v1alpha1
kind: KubeNodeConfig
taints:
  node-role.kubernetes.io/control-plane:
    $patch: delete
