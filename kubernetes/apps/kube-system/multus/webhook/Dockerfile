# mac-webhook: a minimal mutating admission webhook that injects a random MAC
# into each pod's `k8s.v1.cni.cncf.io/networks` annotation (for Multus + the
# `dhcp` CNI IPAM plugin).
#
# Build:
#   docker build -t mac-webhook:latest .
#   docker push <registry>/mac-webhook:latest
#
# The image is a static Go binary in a minimal alpine base. The TLS cert is
# mounted at /tls/tls.crt and /tls/tls.key (from the cert-manager Certificate).

# --- Build stage ---
FROM golang:1.24-alpine AS build
WORKDIR /app
COPY main.go .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o mac-webhook main.go

# --- Final stage ---
FROM alpine:3.21
COPY --from=build /app/mac-webhook /usr/local/bin/mac-webhook
ENTRYPOINT ["/usr/local/bin/mac-webhook"]
