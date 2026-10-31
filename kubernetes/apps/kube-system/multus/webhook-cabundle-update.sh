#!/bin/sh
# Sets the `caBundle` in the mac-webhook MutatingWebhookConfiguration to the
# CA cert from the `mac-webhook-tls` secret (issued by cert-manager).
#
# Run this after the Certificate is ready (the secret exists). The `caBundle`
# is the base64-encoded CA cert (PEM), which is the same format as the
# secret's `data.ca.crt` (K8s secrets store data as base64).
set -eu

echo "Waiting for mac-webhook-tls secret..."
until kubectl -n kube-system get secret mac-webhook-tls >/dev/null 2>&1; do
  sleep 2
done

# The secret's data.ca.crt is already base64-encoded (PEM) — same format as caBundle.
CABUNDLE=$(kubectl -n kube-system get secret mac-webhook-tls -o jsonpath='{.data.ca\.crt}')
if [ -z "$CABUNDLE" ]; then
  echo "ERROR: mac-webhook-tls secret has no ca.crt" >&2
  exit 1
fi

kubectl patch mutatingwebhookconfiguration mac-webhook \
  --type=json \
  -p="[{\"op\":\"replace\",\"path\":\"/webhooks/0/caBundle\",\"value\":\"${CABUNDLE}\"}]"

echo "Updated caBundle in mac-webhook MutatingWebhookConfiguration"
