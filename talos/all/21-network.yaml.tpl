apiVersion: v1alpha1
kind: ResolverConfig
hostDNS:
  enabled: true
  forwardKubeDNSToHost: true
nameservers:
  {{- range .Data.upstreamDNS }}
  - address: {{ . }}
  {{- end }}
searchDomains:
  disableDefault: true
