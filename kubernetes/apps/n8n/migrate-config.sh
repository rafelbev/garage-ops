#!/bin/bash
# n8n Config Migration Script
# Migrates n8n's data dir (SQLite database + config) from the k3s source
# cluster to the Talos target cluster.
#
# The target manifests PR must be merged and Flux-applied FIRST so the n8n
# namespace, PVC and (empty) deployment already exist on Talos.
#
# Prerequisites:
# - kubectl configured for both clusters
# - k3s kubeconfig:    /home/raphael/home.yaml
# - Talos kubeconfig:   /home/raphael/code/garage-ops/kubeconfig
#
# Usage: ./migrate-config.sh

set -euo pipefail

K3S_KUBECONFIG="${K3S_KUBECONFIG:-/home/raphael/home.yaml}"
TALOS_KUBECONFIG="${TALOS_KUBECONFIG:-/home/raphael/code/garage-ops/kubeconfig}"
NAMESPACE="n8n"
DATA_DIR="/home/node/.n8n"
TARBALL="n8n-config.tar.gz"
TMP_DIR="$(mktemp -d /tmp/n8n-migration.XXXXXX)"

echo "=== n8n Config Migration ==="
echo "k3s kubeconfig:    $K3S_KUBECONFIG"
echo "Talos kubeconfig:  $TALOS_KUBECONFIG"
echo "Temp directory:    $TMP_DIR"

trap "rm -rf $TMP_DIR" EXIT

K3S=(kubectl --kubeconfig "$K3S_KUBECONFIG")
TALOS=(kubectl --kubeconfig "$TALOS_KUBECONFIG")

# Step 1: Scale down n8n on the source cluster so the SQLite WAL is
# checkpointed and no writes land mid-tar.
echo ""
echo "Step 1: Scaling down n8n on k3s..."
"${K3S[@]}" -n "$NAMESPACE" scale deployment n8n --replicas=0
"${K3S[@]}" -n "$NAMESPACE" rollout status deployment/n8n --timeout=120s
echo "n8n scaled down."

# Step 2: Export pod on k3s — tar the data dir, then sleep so the tarball
# can be copied out (a Completed pod cannot be exec'd).
echo ""
echo "Step 2: Creating export pod on k3s..."
cat > "$TMP_DIR/export-pod.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: n8n-config-export
  namespace: $NAMESPACE
spec:
  restartPolicy: Never
  containers:
    - name: exporter
      image: alpine:3.20
      command: ["/bin/sh", "-c", "tar czf /export/$TARBALL -C $DATA_DIR . && touch /export/done && sleep 3600"]
      volumeMounts:
        - name: data
          mountPath: $DATA_DIR
        - name: export
          mountPath: /export
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: n8n
    - name: export
      emptyDir: {}
EOF
"${K3S[@]}" apply -f "$TMP_DIR/export-pod.yaml"
"${K3S[@]}" -n "$NAMESPACE" wait --for=condition=Ready pod/n8n-config-export --timeout=120s

# Step 3: Poll for the done marker (no fixed sleeps).
echo ""
echo "Step 3: Waiting for export to finish..."
for _ in $(seq 1 60); do
    if "${K3S[@]}" -n "$NAMESPACE" exec n8n-config-export -- test -f /export/done 2>/dev/null; then
        break
    fi
    sleep 5
done
"${K3S[@]}" -n "$NAMESPACE" exec n8n-config-export -- test -f /export/done
SOURCE_SIZE=$("${K3S[@]}" -n "$NAMESPACE" exec n8n-config-export -- wc -c < "/export/$TARBALL" | tr -d ' ')
echo "Export complete: $SOURCE_SIZE bytes"

# Step 4: Pull the tarball to local and verify integrity.
echo ""
echo "Step 4: Downloading and verifying tarball..."
"${K3S[@]}" -n "$NAMESPACE" cp "n8n-config-export:/export/$TARBALL" "$TMP_DIR/$TARBALL"
LOCAL_SIZE=$(wc -c < "$TMP_DIR/$TARBALL" | tr -d ' ')
if [ "$LOCAL_SIZE" != "$SOURCE_SIZE" ]; then
    echo "ERROR: byte count mismatch (source $SOURCE_SIZE, local $LOCAL_SIZE)" >&2
    exit 1
fi
tar -tzf "$TMP_DIR/$TARBALL" | grep -E 'database\.sqlite$'
echo "Tarball verified: $LOCAL_SIZE bytes, database present."

# Step 5: Import pod on Talos. Its command is ONLY sleep — the write/extract
# is done via an explicit exec so the pod's empty startup stdin cannot
# truncate the stream.
echo ""
echo "Step 5: Creating import pod on Talos..."
cat > "$TMP_DIR/import-pod.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: n8n-config-import
  namespace: $NAMESPACE
spec:
  restartPolicy: Never
  containers:
    - name: importer
      image: alpine:3.20
      command: ["/bin/sh", "-c", "sleep 3600"]
      volumeMounts:
        - name: data
          mountPath: $DATA_DIR
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: n8n
EOF
"${TALOS[@]}" apply -f "$TMP_DIR/import-pod.yaml"
"${TALOS[@]}" -n "$NAMESPACE" wait --for=condition=Ready pod/n8n-config-import --timeout=180s

# Step 6: Copy the tarball in and extract. The data is small (~26M), so
# kubectl cp is fine — no streaming needed.
echo ""
echo "Step 6: Importing config on Talos..."
"${TALOS[@]}" -n "$NAMESPACE" cp "$TMP_DIR/$TARBALL" "n8n-config-import:/tmp/$TARBALL"
LANDED_SIZE=$("${TALOS[@]}" -n "$NAMESPACE" exec n8n-config-import -- wc -c < "/tmp/$TARBALL" | tr -d ' ')
if [ "$LANDED_SIZE" != "$LOCAL_SIZE" ]; then
    echo "ERROR: byte count mismatch (local $LOCAL_SIZE, target $LANDED_SIZE)" >&2
    exit 1
fi
"${TALOS[@]}" -n "$NAMESPACE" exec n8n-config-import -- tar xzf "/tmp/$TARBALL" -C "$DATA_DIR"
"${TALOS[@]}" -n "$NAMESPACE" exec n8n-config-import -- chown -R 1000:1000 "$DATA_DIR"
echo "Config imported. Top-level contents:"
"${TALOS[@]}" -n "$NAMESPACE" exec n8n-config-import -- ls -la "$DATA_DIR"

# Step 7: Clean up helper pods and verify the app.
echo ""
echo "Step 7: Cleaning up helper pods..."
"${TALOS[@]}" delete pod n8n-config-import -n "$NAMESPACE" --wait=true
"${K3S[@]}" delete pod n8n-config-export -n "$NAMESPACE" --wait=true

echo ""
echo "Step 8: Verifying n8n on Talos..."
"${TALOS[@]}" -n "$NAMESPACE" get pods -o wide
"${TALOS[@]}" -n "$NAMESPACE" logs -l app=n8n --tail=20

echo ""
echo "=== Migration complete ==="
echo "n8n should now be serving https://n8n.garage.neo-tix.com/"
echo "The k3s deployment is scaled to 0 — keep it there until the target is"
echo "verified, then delete the n8n namespace on k3s to free the NFS PVC."
