#!/bin/bash
# Radarr Config Migration Script
# Migrates Radarr config from k3s source cluster to Talos target cluster
#
# Prerequisites:
# - kubectl configured for both clusters (use kubeconfig contexts)
# - Old cluster context: radarr-source (k3s)
# - New cluster context: radarr-target (Talos)
#
# Usage: ./migrate-config.sh

set -euo pipefail

OLD_CONTEXT="${OLD_KUBE_CONTEXT:-radarr-source}"
NEW_CONTEXT="${NEW_KUBE_CONTEXT:-radarr-target}"
NAMESPACE="radarr"
TMP_DIR="/tmp/radarr-migration-$$"

echo "=== Radarr Config Migration ==="
echo "Old cluster context: $OLD_CONTEXT"
echo "New cluster context: $NEW_CONTEXT"
echo "Temp directory: $TMP_DIR"

# Create temp directory
mkdir -p "$TMP_DIR"
trap "rm -rf $TMP_DIR" EXIT

# Step 1: Scale down Radarr on old cluster to ensure clean SQLite DB
echo ""
echo "Step 1: Scaling down Radarr on old cluster..."
kubectl --context "$OLD_CONTEXT" -n "$NAMESPACE" scale deployment radarr-1614541747 --replicas=0
sleep 5
echo "Radarr scaled down."

# Step 2: Create export pod on old cluster
echo ""
echo "Step 2: Exporting config from old cluster..."
cat > "$TMP_DIR/export-pod.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: radarr-config-export
  namespace: $NAMESPACE
spec:
  restartPolicy: Never
  containers:
    - name: exporter
      image: alpine:3.20
      command: ["/bin/sh", "-c", "tar czf /export/radarr-config.tar.gz -C /config . && touch /export/done && sleep 3600"]
      volumeMounts:
        - name: config
          mountPath: /config
        - name: export
          mountPath: /export
  volumes:
    - name: config
      persistentVolumeClaim:
        claimName: radarr-1614541747-config
    - name: export
      emptyDir: {}
EOF

kubectl --context "$OLD_CONTEXT" -n "$NAMESPACE" apply -f "$TMP_DIR/export-pod.yaml"
kubectl --context "$OLD_CONTEXT" -n "$NAMESPACE" wait --for=condition=Ready pod/radarr-config-export --timeout=120s

# Wait for tar to complete
echo "Waiting for export to complete..."
for i in $(seq 1 60); do
  if kubectl --context "$OLD_CONTEXT" -n "$NAMESPACE" exec radarr-config-export -- test -f /export/done 2>/dev/null; then
    echo "Export complete."
    break
  fi
  sleep 1
done

# Step 3: Copy the tar file from old cluster
echo ""
echo "Step 3: Downloading config archive..."
kubectl --context "$OLD_CONTEXT" -n "$NAMESPACE" cp radarr-config-export:/export/radarr-config.tar.gz "$TMP_DIR/radarr-config.tar.gz"
echo "Downloaded $(du -h "$TMP_DIR/radarr-config.tar.gz" | cut -f1) archive."

# Step 4: Clean up export pod
echo ""
echo "Step 4: Cleaning up export pod..."
kubectl --context "$OLD_CONTEXT" -n "$NAMESPACE" delete pod radarr-config-export --ignore-not-found=true

# Step 5: Create import pod on new cluster
echo ""
echo "Step 5: Importing config to new cluster..."
cat > "$TMP_DIR/import-pod.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: radarr-config-import
  namespace: $NAMESPACE
spec:
  restartPolicy: Never
  containers:
    - name: importer
      image: alpine:3.20
      command: ["/bin/sh", "-c", "while [ ! -f /import/radarr-config.tar.gz ]; do sleep 1; done; tar xzf /import/radarr-config.tar.gz -C /config && sleep 3600"]
      volumeMounts:
        - name: config
          mountPath: /config
        - name: import
          mountPath: /import
  volumes:
    - name: config
      persistentVolumeClaim:
        claimName: radarr-config
    - name: import
      emptyDir: {}
EOF

kubectl --context "$NEW_CONTEXT" -n "$NAMESPACE" apply -f "$TMP_DIR/import-pod.yaml"
kubectl --context "$NEW_CONTEXT" -n "$NAMESPACE" wait --for=condition=Ready pod/radarr-config-import --timeout=120s

# Step 6: Upload tar to import pod
echo ""
echo "Step 6: Uploading config archive..."
kubectl --context "$NEW_CONTEXT" -n "$NAMESPACE" cp "$TMP_DIR/radarr-config.tar.gz" radarr-config-import:/import/radarr-config.tar.gz
sleep 10  # Give it time to extract

# Step 7: Clean up import pod
echo ""
echo "Step 7: Cleaning up import pod..."
kubectl --context "$NEW_CONTEXT" -n "$NAMESPACE" delete pod radarr-config-import --ignore-not-found=true

echo ""
echo "=== Migration Complete ==="
echo "Config has been migrated to the new cluster."
echo ""
echo "Next steps:"
echo "1. Verify Radarr pod is running: kubectl --context $NEW_CONTEXT -n $NAMESPACE get pods"
echo "2. Access Radarr UI and verify library configuration"
echo "3. Scale up Radarr on old cluster if needed for rollback"
