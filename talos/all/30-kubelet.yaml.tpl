machine:
  kubelet: null
---
apiVersion: v1alpha1
kind: KubeNodeConfig
nodeIP:
    validSubnets:
        - "{{ .Data.etcdSubnet }}"
---
apiVersion: v1alpha1
kind: KubeletConfig
image: "ghcr.io/siderolabs/kubelet:{{ .KubernetesVersion }}"
defaultRuntimeSeccompProfileEnabled: true
config:
    crashLoopBackOff:
        maxContainerRestartPeriod: 60s
    imageMaximumGCAge: 168h
    maxParallelImagePulls: 3
    serializeImagePulls: false
    shutdownGracePeriod: 90s
    shutdownGracePeriodCriticalPods: 60s
