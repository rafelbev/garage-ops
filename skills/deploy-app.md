# Skill: Deploy a New Application

Use this skill when deploying a new application to the garage-ops cluster using Flux and Helm.

## Prerequisites

- Access to the garage-ops repository
- `kubectl` configured with the cluster kubeconfig
- `flux` CLI available via mise
- Application Helm chart identified and tested

## Procedure

### Step 1: Create Application Directory Structure

```bash
APP_NAME=<app-name>
mkdir -p kubernetes/apps/${APP_NAME}/${APP_NAME}/app
```

### Step 2: Create Namespace and Kustomization

```yaml
# kubernetes/apps/<app-name>/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
    name: <app-name>
```

```yaml
# kubernetes/apps/<app-name>/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: <app-name>
components:
    - ../../components/sops
resources:
    - ./namespace.yaml
    - ./<app-name>/ks.yaml
```

### Step 3: Create Flux Kustomization

```yaml
# kubernetes/apps/<app-name>/<app-name>/ks.yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
    name: <app-name>
spec:
    healthChecks:
        - apiVersion: helm.toolkit.fluxcd.io/v2
          kind: HelmRelease
          name: <app-name>
          namespace: <app-name>
    interval: 1h
    path: ./kubernetes/apps/<app-name>/<app-name>/app
    postBuild:
        substituteFrom:
            - name: cluster-secrets
              kind: Secret
    prune: true
    sourceRef:
        kind: GitRepository
        name: flux-system
        namespace: flux-system
    targetNamespace: <app-name>
```

### Step 4: Create HelmRepository (if needed)

If the chart is not in Flux's built-in repositories:

```yaml
# kubernetes/apps/<app-name>/<app-name>/app/helmrepository.yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
    name: <repo-name>
spec:
    interval: 1h
    url: https://charts.example.com
```

### Step 5: Create HelmRelease

```yaml
# kubernetes/apps/<app-name>/<app-name>/app/helmrelease.yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
    name: <app-name>
spec:
    chart:
        spec:
            chart: <chart-name>
            sourceRef:
                kind: HelmRepository
                name: <repo-name>
            version: "<version>"
    interval: 1h
    values:
        # Chart values here
        # Use {{ .Values.xxx }} for secret substitution
```

### Step 6: Create App Kustomization

```yaml
# kubernetes/apps/<app-name>/<app-name>/app/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
    - helmrelease.yaml
    # - helmrepository.yaml (if created)
```

### Step 7: Add Secrets (if needed)

If the application requires secrets:

1. Edit `kubernetes/components/sops/cluster-secrets.sops.yaml`
2. Add the secret values
3. Ensure the file is encrypted with SOPS

```bash
sops --encrypt --in-place kubernetes/components/sops/cluster-secrets.sops.yaml
```

### Step 8: Commit and Push

```bash
git add kubernetes/apps/<app-name>/
git commit -m "feat: deploy <app-name>"
git push
```

### Step 9: Verify Deployment

```bash
# Check Flux status
flux get ks <app-name>
flux get hr <app-name>

# Check pods
kubectl -n <app-name> get pods

# Check logs
kubectl -n <app-name> logs -l app=<app-name> -f
```

## Pitfalls to Avoid

1. **Secrets must be sops-encrypted**: Never commit plaintext secrets to git. Always use SOPS encryption.

2. **Health checks**: Include health checks in the Kustomization to ensure Flux waits for the app to be ready.

3. **Remediation strategies**: The cluster-level `ks.yaml` adds default remediation strategies. Do not override unless necessary.

4. **Namespace conflicts**: Ensure the namespace doesn't already exist or is managed elsewhere.

5. **Chart version pinning**: Always pin the Helm chart version in the HelmRelease. Use Renovate for updates.

6. **Resource limits**: Always set resource requests and limits for containers.

## References

- [Flux HelmRelease Documentation](https://fluxcd.io/docs/components/helm/helmreleases/)
- [Flux Kustomization Documentation](https://fluxcd.io/docs/components/kustomize/kustomizations/)
- `AGENTS.md` — Main project documentation
