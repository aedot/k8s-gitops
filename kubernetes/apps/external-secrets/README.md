# Secrets Management

The cluster uses **aKeyless** as the central secrets management platform. Secrets are accessed through three different authentication methods depending on the use case.

## Secret Workflows

### Adding a New Secret for an App

1. **Create secret in aKeyless** (via Web GUI or CLI):

    ```bash
    # Create JSON secret with multiple keys
    akeyless create-secret \
      --name myapp \
      --value '{"API_KEY":"xxx","DATABASE_URL":"yyy"}'
    ```

### Updating an Existing Secret

1. **Update in aKeyless** (Web GUI or CLI):

    ```bash
    akeyless update-secret-value \
      --name authentik \
      --value '{"SECRET_KEY":"new-value"}'
    ```

2. **Force ESO to resync**:

    ```bash
    just kube sync-es default authentik
    ```

3. **Restart app to pick up new secret**:

    ```bash
    kubectl rollout restart deployment/authentik -n default
    ```

---

## CNPG Database Secrets

**IMPORTANT**: The CNPG component does **not** automatically generate database user secrets. You must create them manually in aKeyless (via Web GUI or CLI).

### Creating Database User Secrets

When using the [`cnpg` component](https://github.com/tscibilia/home-ops/tree/main/kubernetes/components/cnpg), you need to manually create secrets for database users in aKeyless.

**Steps:**

1. **Create secret in aKeyless** (Web GUI or CLI):

    ```bash
    # Create JSON secret with database credentials
    akeyless create-secret \
      --name <app-name>-pguser \
      --value '{"username":"<app-name>","password":"<random-password>","dbname":"<app-name>"}'
    ```

    Example for Authentik:

    ```bash
    akeyless create-secret \
      --name authentik-pguser \
      --value '{"username":"authentik","password":"$(openssl rand -base64 32)","dbname":"authentik"}'
    ```

2. **Include CNPG component in app's `ks.yaml`**:

    ```yaml title="kubernetes/apps/default/authentik/ks.yaml"
    spec:
      components:
        - ../../../../components/cnpg
      postBuild:
        substitute:
          APP: authentik
          CNPG_NAME: pgsql-cluster
    ```

3. **CNPG component creates ExternalSecret**:

    The component automatically creates an `ExternalSecret` that syncs `${APP}-pguser` from aKeyless into a Kubernetes Secret named `${APP}-pguser-secret`.

4. **CNPG component CronJob creates database user**:

    The component includes a CronJob ([`kubernetes/components/cnpg/cronjob.yaml`](https://github.com/tscibilia/home-ops/blob/main/kubernetes/components/cnpg/cronjob.yaml)) that runs daily to ensure the database user exists in PostgreSQL using the credentials from aKeyless.

5. **App references the secret**:

    ```yaml title="kubernetes/apps/default/authentik/app/helmrelease.yaml"
    env:
      - name: AUTHENTIK_POSTGRESQL__USER
        valueFrom:
          secretKeyRef:
            name: authentik-pguser-secret
            key: username
      - name: AUTHENTIK_POSTGRESQL__PASSWORD
        valueFrom:
          secretKeyRef:
            name: authentik-pguser-secret
            key: password
    ```

??? warning "Secret Must Exist Before Deployment"
    If the `<app-name>-pguser` secret doesn't exist in aKeyless, the ExternalSecret will fail to sync and the app won't start:

---

## Bootstrap Secrets

During bootstrap, secrets are injected via the CLI method. See [`bootstrap/resources.yaml.j2`](https://github.com/tscibilia/home-ops/blob/main/bootstrap/resources.yaml.j2) for examples of `ak://` references used to create bootstrap-time Secrets.

These include:

- `akeyless-secret`: ESO authentication credentials
- `cloudflared-secret`: Cloudflare tunnel credentials
- `cluster-secrets`: Cluster-wide variables (referenced by apps via `postBuild.substituteFrom`)

---

## Troubleshooting Secrets

### ExternalSecret Not Syncing

**Symptoms**: `SecretSyncedError` status on ExternalSecret

**Diagnosis**:

```bash
kubectl describe externalsecret <name> -n <namespace>
```

**Common causes**:

1. **Secret doesn't exist in aKeyless**:

    ```
    ERROR: secret not found: <secret-name>
    ```

    **Fix**: Create the secret in aKeyless Web GUI or CLI

2. **ClusterSecretStore not ready**:

    ```bash
    kubectl get clustersecretstore
    ```

    **Fix**: Check ESO operator logs:

    ```bash
    kubectl logs -n external-secrets deployment/external-secrets
    ```

3. **Authentication failed**:

    ```
    ERROR: authentication failed
    ```

    **Fix**: Verify `akeyless-secret` contains correct credentials:

    ```bash
    kubectl get secret akeyless-secret -n external-secrets -o yaml
    ```

---

## Best Practices

1. **Use JSON secrets**: Store multiple related values in one secret (e.g., database credentials)
2. **Name consistently**: Use `<app-name>` for app secrets, `<app-name>-pguser` for database credentials
3. **Rotate regularly**: Update secrets in aKeyless and force resync
4. **Limit access**: Use aKeyless access policies to restrict who can view/modify secrets
5. **Never commit secrets**: All secrets live in aKeyless, never in Git (even encrypted)
