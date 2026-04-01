# OpenRMF

A Helm chart for [OpenRMF OSS](https://github.com/Cingulara/openrmf-docs) -- a
DoD Risk Management Framework compliance tool for managing STIGs, Nessus scans,
and NIST RMF compliance. This chart is hardened for STIG'd RKE2 clusters with
Gateway API HTTPS ingress and restricted Pod Security Standard enforcement.

## Source Code

* <https://github.com/darkhonor/helm-charts>
* <https://github.com/Cingulara/openrmf-docs>

## OpenRMF Documentation

| Topic | Link |
|-------|------|
| Installation Guide | <https://cingulara.github.io/openrmf-docs/install.html> |
| HTTPS Configuration | <https://cingulara.github.io/openrmf-docs/https.html> |
| SCAP Scans | <https://cingulara.github.io/openrmf-docs/scapscans.html> |
| Keycloak Setup | <https://cingulara.github.io/openrmf-docs/domainkeycloak.html> |
| GitHub Repository | <https://github.com/Cingulara/openrmf-docs> |

## Prerequisites

- **Kubernetes** 1.28+ (RKE2 1.34+ recommended for STIG compliance)
- **Helm** 3.12+
- **cert-manager** -- TLS certificate lifecycle management for Gateway API
- **Traefik Gateway API controller** -- ships with RKE2 by default; the chart
  creates Gateway and HTTPRoute resources using `gatewayClass: traefik`
- **Vault Secrets Operator** -- syncs secrets from HashiCorp Vault into
  Kubernetes Secrets (OIDC credentials, MongoDB URIs, NATS tokens)
- **MongoDB Community Operator** -- required when `mongodb.operator.enabled=true`
  (operator mode); not needed when using an external MongoDB instance
- An **OIDC provider** (Keycloak) -- either external or deployed as a subchart

## Resource Requirements

### OpenRMF Core

| Component | Replicas | CPU Request | Memory Request | CPU Limit | Memory Limit | Storage |
|-----------|----------|-------------|----------------|-----------|--------------|---------|
| Web Frontend | 1 | 100m | 256Mi | 500m | 400Mi | - |
| API Services (x6) | 1 each | 100m | 256Mi | 500m | 768Mi | - |
| Message Consumers (x8) | 1 each | 50m | 128Mi | 250m | 256Mi | - |
| NATS | 1 | 100m | 128Mi | 250m | 256Mi | - |
| MongoDB (operator) | 1 | 500m | 768Mi | 1000m | 2Gi | 10Gi |

The six API services are: read, scoring, template, controls, audit, and report.
The eight message consumers are: checklist, score, template, controls, audit,
report, system, and compliance.

### Identity Tier (if internal Keycloak)

| Component | Replicas | CPU Request | Memory Request | CPU Limit | Memory Limit | Storage |
|-----------|----------|-------------|----------------|-----------|--------------|---------|
| KeycloakX | 1 | 500m | 512Mi | 1000m | 1Gi | - |
| PostgreSQL (CNPG) | 1 | 250m | 256Mi | 500m | 512Mi | 5Gi |

### Totals

| Configuration | Pods | CPU Request | Memory Request | CPU Limit | Memory Limit | Storage |
|---------------|------|-------------|----------------|-----------|--------------|---------|
| External Keycloak | ~17 | ~1.9 cores | ~5.4Gi | ~6.3 cores | ~12Gi | 10Gi |
| Internal Keycloak | ~19 | ~2.65 cores | ~6.2Gi | ~7.8 cores | ~13.5Gi | 15Gi |

### Recommended Node Sizing

| Topology | vCPU | RAM | Disk |
|----------|------|----|------|
| Single node (lab) | 12 vCPU | 24Gi RAM | 250Gi disk |
| 3-node HA (STIG) | 6 vCPU each | 12Gi RAM each | 150Gi each |

## Installing

Before you can install, add the `darkhonor` repo to Helm:

```shell
helm repo add darkhonor https://darkhonor.github.io/helm-charts
helm repo update
```

## Quick Start (External Keycloak)

The default configuration assumes an external Keycloak instance and an external
MongoDB. You must provide the Keycloak URL and pre-create the Kubernetes Secrets
that hold your OIDC credentials and MongoDB connection strings.

### 1. Create Secrets

Create the OIDC client credential Secret (or use the Vault Secrets Operator --
see the VSO section below):

```shell
kubectl create namespace openrmf

kubectl create secret generic openrmf-oidc \
  --namespace openrmf \
  --from-literal=client-id="openrmf" \
  --from-literal=client-secret="YOUR_CLIENT_SECRET"
```

Create the MongoDB connection URI Secret:

```shell
kubectl create secret generic openrmf-mongodb \
  --namespace openrmf \
  --from-literal=checklist-uri="mongodb://user:pass@mongo:27017/openrmf?authSource=openrmf" \
  --from-literal=score-uri="mongodb://user:pass@mongo:27017/openrmfscore?authSource=openrmfscore" \
  --from-literal=template-uri="mongodb://user:pass@mongo:27017/openrmftemplate?authSource=openrmftemplate" \
  --from-literal=audit-uri="mongodb://user:pass@mongo:27017/openrmfaudit?authSource=openrmfaudit" \
  --from-literal=report-uri="mongodb://user:pass@mongo:27017/openrmfreport?authSource=openrmfreport"
```

### 2. Install the Chart

```shell
helm upgrade --install openrmf darkhonor/openrmf \
  --namespace openrmf \
  --set keycloak.mode=external \
  --set keycloak.external.url="https://keycloak.example.com" \
  --set keycloak.external.realm="openrmf" \
  --set keycloak.external.existingSecret="openrmf-oidc" \
  --set mongodb.mode=external \
  --set mongodb.external.existingSecret="openrmf-mongodb" \
  --set httproute.hostname="openrmf.example.com" \
  --set httproute.tls.issuer="your-cluster-issuer"
```

### 3. Verify

```shell
kubectl -n openrmf get pods
kubectl -n openrmf get httproute
```

Once all pods are running, access OpenRMF at `https://openrmf.example.com`.

## Configuration

### Keycloak (OIDC Identity Provider)

The chart supports two modes for Keycloak:

**External Keycloak** (default, `keycloak.mode: "external"`):
Point the chart at an existing Keycloak instance. You provide the URL, realm
name, and a Kubernetes Secret containing the OIDC client credentials.

```yaml
keycloak:
  mode: "external"
  external:
    url: "https://keycloak.example.com"
    realm: "openrmf"
    existingSecret: "openrmf-oidc"
    clientIdKey: "client-id"
    clientSecretKey: "client-secret"
```

**Internal Keycloak** (`keycloak.mode: "internal"`):
Deploys KeycloakX as a subchart. This is useful for lab environments where you
do not have an existing identity provider.

```yaml
keycloak:
  mode: "internal"
  internal:
    enabled: true
    realm: "openrmf"
  keycloakx:
    # KeycloakX subchart values go here
```

### MongoDB

The chart supports two modes for MongoDB:

**External MongoDB** (default, `mongodb.mode: "external"`):
Use an existing MongoDB instance. Provide a Secret containing connection URIs
for each OpenRMF database (checklist, score, template, audit, report).

```yaml
mongodb:
  mode: "external"
  external:
    existingSecret: "openrmf-mongodb"
    checklistConnectionKey: "checklist-uri"
    scoreConnectionKey: "score-uri"
    templateConnectionKey: "template-uri"
    auditConnectionKey: "audit-uri"
    reportConnectionKey: "report-uri"
```

**Operator Mode** (`mongodb.mode: "operator"`):
Deploys MongoDB via the MongoDB Community Operator subchart. The chart creates
a `MongoDBCommunity` custom resource that provisions a MongoDB instance with
the required databases.

```yaml
mongodb:
  mode: "operator"
  operator:
    enabled: true
    version: "7.0.26"
    storage:
      size: 10Gi
      storageClass: "local-path"
    resources:
      limits:
        cpu: "1000m"
        memory: 2Gi
      requests:
        cpu: 500m
        memory: 768Mi
```

### Gateway API and TLS

The chart creates a Gateway and HTTPRoute for HTTPS access via Traefik. TLS
certificates are generated automatically by cert-manager.

```yaml
httproute:
  enabled: true
  gateway:
    enabled: true
    class: "traefik"
    listener:
      protocol: "HTTPS"
      port: 443
  hostname: "openrmf.example.com"
  tls:
    enabled: true
    mode: "Terminate"
    certificate:
      generate: true
      algorithm: RSA
      keySize: 4096
      duration: "2160h"       # 90 days
      renewBefore: "360h"     # 15 days
    issuer: "vault-issuer"
    issuerKind: ClusterIssuer
```

Key settings:
- `httproute.hostname` -- the FQDN used for the HTTPRoute and TLS certificate
- `httproute.tls.issuer` -- the cert-manager ClusterIssuer or Issuer name
- `httproute.tls.certificate.algorithm` -- `RSA` (4096-bit) or `ECDSA`
- `httproute.gateway.class` -- the GatewayClass name (defaults to `traefik`)

### Network Policy

The chart deploys a NetworkPolicy that restricts traffic to only what OpenRMF
requires. It covers three monitoring patterns:

**Pattern 1: Direct external scrape.**
A centralized Prometheus instance outside the cluster scrapes OpenRMF metrics
directly. Requires an ingress rule allowing the Prometheus CIDR.

```yaml
networkPolicy:
  enabled: true
  externalMonitoring:
    enabled: true
    cidr: "10.0.50.0/24"
```

**Pattern 2: In-cluster Prometheus Agent with remote-write.**
A Prometheus Agent runs inside the cluster, discovers targets via
ServiceMonitors, and remote-writes to an external Prometheus or Thanos. No
additional NetworkPolicy ingress rules are needed because the agent runs
in-cluster. Only configure the agent's egress to reach the remote endpoint.

**Pattern 3: In-cluster Prometheus Operator (full stack).**
Same as Pattern 2. The Prometheus Operator deploys Prometheus inside the
cluster, discovers targets via ServiceMonitors, and handles scraping. No
special NetworkPolicy ingress rules are needed.

Additional network policy settings:

```yaml
networkPolicy:
  gatewayNamespace: "kube-system"     # Namespace where Traefik runs
  gatewaySelector:
    app.kubernetes.io/name: traefik   # Pod selector for the gateway
  allowExternalHTTPS: false           # Allow egress to external HTTPS (443)
  additionalIngressSources: []        # Extra ingress rules
  additionalEgressRules: []           # Extra egress rules
```

### Monitoring

The chart supports Prometheus ServiceMonitor resources for API service metrics
discovery and an optional external metrics Service.

```yaml
monitoring:
  serviceMonitor:
    enabled: true
    interval: "15s"
    matchLabels: {}           # Extra labels for ServiceMonitor selector
  externalMetrics:
    enabled: false
    serviceType: ClusterIP
    annotations: {}
```

When `serviceMonitor.enabled` is `true`, the chart creates a ServiceMonitor
for each API service, allowing Prometheus to auto-discover scrape targets.

When `externalMetrics.enabled` is `true`, the chart creates an additional
Service that exposes a metrics endpoint for external monitoring systems.

### Security Context

The chart enforces the Kubernetes restricted Pod Security Standard by default.
These settings are applied to all pods and containers:

```yaml
podSecurityContext:
  runAsNonRoot: true
  fsGroupChangePolicy: "OnRootMismatch"

containerSecurityContext:
  runAsNonRoot: true
  readOnlyRootFilesystem: true
  allowPrivilegeEscalation: false
  capabilities:
    drop:
      - ALL
  seccompProfile:
    type: RuntimeDefault
```

All containers run as non-root with read-only root filesystems, dropped
capabilities, and the default seccomp profile. These defaults comply with
the Kubernetes STIG and the restricted Pod Security Standard.

## Vault Secrets Operator

In production and DoD environments, secrets should not be stored in Helm values
or created manually with `kubectl`. Instead, use the
[Vault Secrets Operator](https://developer.hashicorp.com/vault/docs/platform/k8s/vso)
(VSO) to sync secrets from HashiCorp Vault into Kubernetes.

### Fleet Manifests Pattern

When deploying with Rancher Fleet (as in the MPE-ES-Lab environment), VSO
manifests live in a `manifests/` directory alongside the Fleet bundle
configuration. This separates secret lifecycle management from the Helm chart
itself:

```
fleet/openrmf/
  manifests/
    fleet.yaml                  # Fleet bundle configuration
    vault-secret-oidc.yaml      # VaultStaticSecret for OIDC credentials
    vault-secret-mongodb.yaml   # VaultStaticSecret for MongoDB URIs
    vault-secret-nats.yaml      # VaultStaticSecret for NATS token
```

Fleet applies these manifests to the target cluster before or alongside the
Helm release, ensuring the Kubernetes Secrets exist when the chart's pods
start.

### OIDC Credentials

Syncs `client-id` and `client-secret` from Vault into the Secret referenced
by `keycloak.external.existingSecret`:

```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  name: openrmf-oidc
  namespace: openrmf
spec:
  type: kv-v2
  mount: secret
  path: openrmf/oidc
  destination:
    name: openrmf-oidc
    create: true
  refreshAfter: 30s
  vaultAuthRef: default
```

### MongoDB Connection URIs

Syncs `checklist-uri`, `score-uri`, `template-uri`, `audit-uri`, and
`report-uri` from Vault into the Secret referenced by
`mongodb.external.existingSecret`:

```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  name: openrmf-mongodb
  namespace: openrmf
spec:
  type: kv-v2
  mount: secret
  path: openrmf/mongodb
  destination:
    name: openrmf-mongodb
    create: true
  refreshAfter: 30s
  vaultAuthRef: default
```

### NATS Authentication Token

Only needed when `nats.auth.enabled=true`. Syncs the `nats-token` key from
Vault into the Secret referenced by `nats.auth.existingSecret`:

```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  name: openrmf-nats
  namespace: openrmf
spec:
  type: kv-v2
  mount: secret
  path: openrmf/nats
  destination:
    name: openrmf-nats
    create: true
  refreshAfter: 30s
  vaultAuthRef: default
```

### Vault CLI Setup

Store the required secrets in Vault before deploying:

```shell
# OIDC credentials
vault kv put secret/openrmf/oidc \
  client-id="openrmf" \
  client-secret="$(openssl rand -hex 32)"

# MongoDB connection URIs
vault kv put secret/openrmf/mongodb \
  checklist-uri="mongodb://openrmf:password@mongo:27017/openrmf?authSource=openrmf" \
  score-uri="mongodb://openrmf:password@mongo:27017/openrmfscore?authSource=openrmfscore" \
  template-uri="mongodb://openrmf:password@mongo:27017/openrmftemplate?authSource=openrmftemplate" \
  audit-uri="mongodb://openrmf:password@mongo:27017/openrmfaudit?authSource=openrmfaudit" \
  report-uri="mongodb://openrmf:password@mongo:27017/openrmfreport?authSource=openrmfreport"

# NATS token (optional)
vault kv put secret/openrmf/nats \
  nats-token="$(openssl rand -hex 32)"
```

### Helm Values for VSO

When using VSO, reference the Secrets it creates by name:

```yaml
keycloak:
  mode: "external"
  external:
    url: "https://keycloak.example.com"
    realm: "openrmf"
    existingSecret: "openrmf-oidc"

mongodb:
  mode: "external"
  external:
    existingSecret: "openrmf-mongodb"

nats:
  auth:
    enabled: true
    existingSecret: "openrmf-nats"
    tokenKey: "nats-token"
```

## Security

This chart is designed for deployment in DoD environments that enforce STIG
compliance. Key security features include:

- **Restricted Pod Security Standard** -- all pods run as non-root with
  read-only root filesystems, dropped capabilities, and seccomp profiles
- **NetworkPolicy** -- default-deny with explicit allow rules for required
  traffic flows only
- **TLS everywhere** -- Gateway API terminates TLS with certificates managed
  by cert-manager
- **No hostPath volumes** -- the chart includes a guard clause that prohibits
  hostPath mounts
- **Secrets externalized** -- credentials are never stored in Helm values;
  they are injected via Kubernetes Secrets managed by VSO or created externally
- **Service account token projection** -- `automountServiceAccountToken: false`
  by default to minimize token exposure

For a complete mapping of chart features to NIST SP 800-53 controls and DISA
STIG findings, see `COMPLIANCE_GUIDE.md` in this chart directory.

## Values Reference

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `replicaCount` | int | `1` | Web frontend replica count |
| `nameOverride` | string | `""` | Override chart name |
| `fullnameOverride` | string | `""` | Override fully qualified app name |
| `serviceAccount.create` | bool | `true` | Create a ServiceAccount |
| `serviceAccount.automountServiceAccountToken` | bool | `false` | Disable auto-mount of SA token |
| `serviceAccount.annotations` | object | `{}` | ServiceAccount annotations |
| `serviceAccount.name` | string | `""` | ServiceAccount name override |
| `podSecurityContext.runAsNonRoot` | bool | `true` | Enforce non-root pods |
| `containerSecurityContext.readOnlyRootFilesystem` | bool | `true` | Read-only root filesystem |
| `containerSecurityContext.allowPrivilegeEscalation` | bool | `false` | Block privilege escalation |
| `images.pullPolicy` | string | `"IfNotPresent"` | Image pull policy |
| `images.pullSecrets` | list | `[]` | Image pull secrets |
| `web.port` | int | `8080` | Web frontend container port |
| `web.resources` | object | see values.yaml | Web frontend resource limits |
| `nats.port` | int | `4222` | NATS client port |
| `nats.auth.enabled` | bool | `false` | Enable NATS authentication |
| `nats.auth.existingSecret` | string | `""` | Existing Secret with NATS token |
| `keycloak.mode` | string | `"external"` | Keycloak mode: `external` or `internal` |
| `keycloak.external.url` | string | `""` | External Keycloak URL |
| `keycloak.external.realm` | string | `"openrmf"` | Keycloak realm name |
| `keycloak.external.existingSecret` | string | `""` | Secret with OIDC credentials |
| `keycloak.internal.enabled` | bool | `false` | Deploy KeycloakX subchart |
| `mongodb.mode` | string | `"external"` | MongoDB mode: `external` or `operator` |
| `mongodb.external.existingSecret` | string | `""` | Secret with MongoDB URIs |
| `mongodb.operator.enabled` | bool | `false` | Deploy MongoDB Community Operator |
| `mongodb.operator.version` | string | `"7.0.26"` | MongoDB version |
| `mongodb.operator.storage.size` | string | `"10Gi"` | MongoDB PVC size |
| `mongodb.operator.storage.storageClass` | string | `""` | StorageClass name |
| `httproute.enabled` | bool | `true` | Create Gateway API resources |
| `httproute.hostname` | string | `""` | FQDN for HTTPRoute and TLS cert |
| `httproute.gateway.enabled` | bool | `true` | Create a Gateway resource |
| `httproute.gateway.class` | string | `"traefik"` | GatewayClass name |
| `httproute.tls.enabled` | bool | `true` | Enable TLS termination |
| `httproute.tls.issuer` | string | `"vault-issuer"` | cert-manager issuer name |
| `httproute.tls.issuerKind` | string | `"ClusterIssuer"` | Issuer or ClusterIssuer |
| `httproute.tls.certificate.generate` | bool | `true` | Auto-generate TLS cert |
| `httproute.tls.certificate.algorithm` | string | `"RSA"` | Certificate key algorithm |
| `httproute.tls.certificate.keySize` | int | `4096` | RSA key size |
| `networkPolicy.enabled` | bool | `true` | Deploy NetworkPolicy |
| `networkPolicy.gatewayNamespace` | string | `"kube-system"` | Gateway controller namespace |
| `networkPolicy.gatewaySelector` | object | `{app.kubernetes.io/name: traefik}` | Gateway pod selector |
| `networkPolicy.allowExternalHTTPS` | bool | `false` | Allow egress to external HTTPS |
| `networkPolicy.externalMonitoring.enabled` | bool | `false` | Allow external Prometheus scrape |
| `networkPolicy.externalMonitoring.cidr` | string | `""` | Prometheus CIDR |
| `monitoring.serviceMonitor.enabled` | bool | `false` | Create ServiceMonitors |
| `monitoring.serviceMonitor.interval` | string | `"15s"` | Scrape interval |
| `monitoring.externalMetrics.enabled` | bool | `false` | Create external metrics Service |
| `extraEnv` | list | `[]` | Extra environment variables |
| `extraEnvFrom` | list | `[]` | Extra envFrom sources |
| `extraVolumeMounts` | list | `[]` | Extra volume mounts |
| `extraVolumes` | list | `[]` | Extra volumes |
| `nodeSelector` | object | `{}` | Node selector constraints |
| `tolerations` | list | `[]` | Pod tolerations |
| `affinity` | object | `{}` | Pod affinity rules |

## Author

Alex Ackerman, @darkhonor
