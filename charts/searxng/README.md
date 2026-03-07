# SearXNG

This is my helm chart for [SearXNG](https://docs.searxng.org/), a free internet
metasearch engine.

## Source Code

* <https://github.com/darkhonor/helm-charts>
* <https://github.com/searxng/searxng>

## Installing

Before you can install, you need to add the `darkhonor` repo to [Helm](https://helm.sh)

```shell
helm repo add darkhonor https://darkhonor.github.io/helm-charts
helm repo update
```

Now you can install the chart:

```shell
helm upgrade --install searxng darkhonor/searxng
```

## Secrets Management

The chart manages the SearXNG `secret_key` (used for cryptographic operations) via a
Kubernetes Secret rather than storing it in a ConfigMap.

### Chart-Generated Secret (default)

By default, the chart creates a Secret with a random 64-character key:

```yaml
secrets:
  searxngSecret:
    create: true
    key: "secret-key"
    # value: ""  # Leave empty to auto-generate
```

To provide your own value:

```yaml
secrets:
  searxngSecret:
    create: true
    key: "secret-key"
    value: "your-secret-value-here"
```

### Existing Secret (Vault Secrets Operator, External Secrets, etc.)

If you manage secrets externally, reference an existing Secret:

```yaml
secrets:
  searxngSecret:
    create: false
    existingSecret: "searxng-secret"
    key: "secret-key"
```

The chart injects the secret as the `SEARXNG_SECRET` environment variable, which
overrides `server.secret_key` in `settings.yml` at runtime.

### Vault Secrets Operator (VSO) Example

For DoD/enterprise environments using HashiCorp Vault with the
[Vault Secrets Operator](https://developer.hashicorp.com/vault/docs/platform/k8s/vso),
the following manifests create the full secret injection pipeline.

**Prerequisites:**
- Vault Secrets Operator installed in the cluster
- A `VaultConnection` resource configured (typically in the `vault` namespace)
- A KV-v2 secrets engine mounted in Vault (e.g., `StaticSecrets`)
- The SearXNG secret stored in Vault (e.g., `StaticSecrets/searxng`)

#### 1. Namespace-Scoped VaultAuth with RBAC

If your cluster uses a global `VaultAuth` in the `vault` namespace, you can skip
this step and reference it directly (e.g., `vaultAuthRef: vault/vault-auth`).

For namespace-scoped authentication:

```yaml
---
# ServiceAccount for Vault authentication
# [NIST IA-5] Authenticator management
# [NIST AC-6] Least privilege
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vault-auth
  namespace: searxng
  labels:
    app.kubernetes.io/name: searxng
    app.kubernetes.io/component: vault-auth
automountServiceAccountToken: true
---
# Long-lived service account token (required for RKE2 1.24+)
# [NIST IA-5] Authenticator management
apiVersion: v1
kind: Secret
metadata:
  name: vault-auth-token
  namespace: searxng
  labels:
    app.kubernetes.io/name: searxng
    app.kubernetes.io/component: vault-auth
  annotations:
    kubernetes.io/service-account.name: vault-auth
type: kubernetes.io/service-account-token
---
# ClusterRoleBinding to allow token review for Vault auth
# [NIST AC-6] Least privilege — scoped to the vault-auth SA only
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: searxng-vault-auth-delegator
  labels:
    app.kubernetes.io/name: searxng
    app.kubernetes.io/component: vault-auth
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
subjects:
  - kind: ServiceAccount
    name: vault-auth
    namespace: searxng
---
# Namespace-scoped VaultAuth
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultAuth
metadata:
  name: searxng-vault-auth
  namespace: searxng
spec:
  kubernetes:
    role: vault-secrets-operator
    serviceAccount: vault-auth
    audiences:
      - vault
  vaultConnectionRef: vault/vault-connection  # Adjust to your VaultConnection name
```

#### 2. VaultStaticSecret

```yaml
---
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  name: searxng-secret
  namespace: searxng
  labels:
    app.kubernetes.io/name: searxng
    app.kubernetes.io/component: secrets
    app.kubernetes.io/managed-by: vault-secrets-operator
spec:
  type: kv-v2
  mount: StaticSecrets
  path: searxng
  destination:
    name: searxng-secret  # Must match secrets.searxngSecret.existingSecret
    create: true
  refreshAfter: 60s
  vaultAuthRef: vault/vault-auth  # Or searxng/searxng-vault-auth for namespace-scoped
  rolloutRestartTargets:
    - kind: Deployment
      name: searxng
```

#### 3. Helm Values

```yaml
secrets:
  searxngSecret:
    create: false
    existingSecret: "searxng-secret"
    key: "secret-key"  # Must match the key name in Vault's KV path
```

#### Vault CLI Setup

Store the secret in Vault before deploying:

```shell
vault kv put StaticSecrets/searxng secret-key="$(openssl rand -hex 32)"
```

## Valkey Configuration

The chart supports three Valkey deployment modes:

### Internal Valkey (Default)

The chart deploys a bundled Valkey instance via subchart. By default, TLS is
enabled via a self-signed cert-manager Certificate.

```yaml
valkey:
  mode: "internal"
  tls:
    enabled: true  # Default — auto-generates certs via cert-manager
```

### Internal Valkey with Authentication

Enable password authentication for the bundled Valkey instance:

```yaml
valkey:
  mode: "internal"
  auth:
    enabled: true
    # usersExistingSecret must match the generated Secret name:
    # <release-name>-searxng-valkey-auth
    usersExistingSecret: "searxng-valkey-auth"
  tls:
    enabled: true
```

The chart generates a random password stored in a Kubernetes Secret and
configures both Valkey (ACL) and SearXNG (`SEARXNG_REDIS_URL` env var)
to use it. The password is preserved across `helm upgrade`.

### External Valkey

Connect to an existing Valkey/Redis server:

```yaml
valkey:
  mode: "external"
  external:
    host: "redis.example.com"
    port: 6379
    db: 0
  auth:
    enabled: true
    existingSecret: "my-redis-password"
    key: "password"
  tls:
    enabled: true
    existingSecret: "my-redis-tls"
```

When using external mode, the bundled Valkey subchart is not deployed.
You must provide:
- An existing Secret with the password (referenced by `auth.existingSecret`)
- An existing Secret with TLS certificates (`ca.crt`, `tls.crt`, `tls.key`)

### Valkey VSO Example

For external Valkey with VSO-managed credentials:

```yaml
valkey:
  mode: "external"
  external:
    host: "redis.prod.internal"
    port: 6379
    db: 0
  auth:
    enabled: true
    existingSecret: "valkey-auth-secret"
    key: "password"
  tls:
    enabled: true
    existingSecret: "valkey-tls-certs"
```

Create the VaultStaticSecret to sync the password:

```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  name: valkey-auth-secret
spec:
  type: kv-v2
  mount: StaticSecrets
  path: valkey
  destination:
    name: valkey-auth-secret
    create: true
  refreshAfter: 60s
  vaultAuthRef: vault/vault-auth
```

## Environment Variables

### Extra Environment Variables

Inject additional environment variables into the SearXNG container:

```yaml
extraEnv:
  - name: MY_VAR
    value: "my-value"
  - name: MY_SECRET_VAR
    valueFrom:
      secretKeyRef:
        name: my-secret
        key: my-key
```

### Bulk Environment Injection

Inject all keys from a Secret or ConfigMap:

```yaml
extraEnvFrom:
  - secretRef:
      name: my-bulk-secret
  - configMapRef:
      name: my-config
```

For the full list of environment variables and settings SearXNG supports, see the
[SearXNG Settings Documentation](https://docs.searxng.org/admin/settings/index.html).

## Values

Here are the values which can be modified in the installation:

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `secrets.searxngSecret.create` | bool | `true` | Create a Kubernetes Secret for the SearXNG secret key |
| `secrets.searxngSecret.existingSecret` | string | `""` | Name of an existing Secret to use |
| `secrets.searxngSecret.key` | string | `"secret-key"` | Key within the Secret |
| `secrets.searxngSecret.value` | string | `""` | Secret value (empty = auto-generate) |
| `valkey.mode` | string | `"internal"` | Valkey mode: `internal` (subchart) or `external` |
| `valkey.external.host` | string | `""` | External Valkey hostname (required when mode: external) |
| `valkey.external.port` | int | `6379` | External Valkey port |
| `valkey.external.db` | int | `0` | External Valkey database number |
| `valkey.auth.enabled` | bool | `false` | Enable Valkey password authentication |
| `valkey.auth.existingSecret` | string | `""` | Existing Secret with Valkey password |
| `valkey.auth.key` | string | `"valkey-password"` | Key within the auth Secret |
| `valkey.tls.enabled` | bool | `true` | Enable TLS for Valkey connections |
| `valkey.tls.existingSecret` | string | `""` | Existing Secret with TLS certs |
| `valkey.tls.certManager.issuerRef.name` | string | `""` | cert-manager Issuer name (empty = self-signed) |
| `extraEnv` | list | `[]` | Extra environment variables |
| `extraEnvFrom` | list | `[]` | Extra envFrom sources |

## Author

Alex Ackerman, @darkhonor
