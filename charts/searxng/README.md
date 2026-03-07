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
    existingSecret: "my-searxng-secret"
    key: "secret-key"
```

The chart injects the secret as the `SEARXNG_SECRET` environment variable, which
overrides `server.secret_key` in `settings.yml` at runtime.

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
| `extraEnv` | list | `[]` | Extra environment variables |
| `extraEnvFrom` | list | `[]` | Extra envFrom sources |

## Author

Alex Ackerman, @darkhonor
