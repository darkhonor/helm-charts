# OpenRMF Helm Chart Compliance Guide (NIST 800-53 Rev 5 Moderate)

This guide maps the OpenRMF Helm chart's security features to NIST SP 800-53 Rev 5
controls at the Moderate baseline. Each section identifies the control, describes how
the chart implements or supports it, and references the specific template or values
file where enforcement occurs.

Scope:
- Chart path: `HomeLab/helm-charts/charts/openrmf`
- Primary framework: NIST 800-53 Rev 5 Moderate
- Control focus: `AC-6`, `SC-7`, `SC-8`, `SC-28`, `CM-6`, `IA-2`, `IA-5`, `AU-2`, `AU-3`

---

## 1. AC-6 -- Least Privilege

### 1.1 Non-root containers

All deployments enforce non-root execution at both the pod and container level.

**Pod security context** (`values.yaml` -> `podSecurityContext`):
- `runAsNonRoot: true` -- kernel-level rejection of UID 0
- `fsGroupChangePolicy: "OnRootMismatch"` -- avoids recursive chown on every mount

**Explicit UIDs per component** (set in each deployment template):
- Web frontend: UID/GID 101 (`web-deployment.yaml`, sourced from `web.runAsUser`)
- API services: UID/GID 1000 (`api-deployment.yaml`, hardcoded in pod spec)
- Message consumers: UID/GID 1000 (`msg-deployment.yaml`, hardcoded in pod spec)
- NATS: UID/GID 1000 (`nats-deployment.yaml`, sourced from `nats.runAsUser`)

### 1.2 Drop ALL capabilities

The shared `containerSecurityContext` in `values.yaml` applies to every container:

```yaml
containerSecurityContext:
  capabilities:
    drop:
      - ALL
```

No capabilities are added back. This is enforced via `toYaml $.Values.containerSecurityContext`
in every deployment template.

### 1.3 Privilege escalation disabled

```yaml
containerSecurityContext:
  allowPrivilegeEscalation: false
```

This prevents child processes from gaining more privileges than their parent,
blocking SUID/SGID exploitation. Applied uniformly across all containers.

### 1.4 Service account token not mounted

The `automountServiceAccountToken: false` setting is enforced at three levels:

1. **ServiceAccount resource** (`templates/serviceaccount.yaml`):
   `automountServiceAccountToken: {{ .Values.serviceAccount.automountServiceAccountToken }}`
2. **Pod spec** in every deployment template (web, API, msg, NATS):
   `automountServiceAccountToken: false` (hardcoded)
3. **values.yaml default**: `serviceAccount.automountServiceAccountToken: false`

This prevents the Kubernetes API token from being projected into any pod, eliminating
a common lateral movement vector.

### 1.5 Read-only root filesystem

```yaml
containerSecurityContext:
  readOnlyRootFilesystem: true
```

Writable paths are explicitly provisioned as `emptyDir` volumes:

| Component | Writable Mounts | Template |
|-----------|----------------|----------|
| Web | `/tmp`, `/var/cache/nginx`, `/var/run` | `web-deployment.yaml` |
| API (all) | `/tmp` | `api-deployment.yaml` |
| Msg (all) | `/tmp` | `msg-deployment.yaml` |
| NATS | `/tmp` | `nats-deployment.yaml` |

No persistent writable storage is mounted to application containers. The web
frontend additionally mounts ConfigMap volumes as `readOnly: true`.

### 1.6 Resource limits enforced

Every container has explicit CPU and memory requests and limits. There are no
`resources: {}` entries in the default values:

- API services: 100m-500m CPU, 256Mi-768Mi memory
- Message consumers: 50m-250m CPU, 128Mi-256Mi memory
- Web frontend: 100m-500m CPU, 256Mi-400Mi memory
- NATS: 100m-250m CPU, 128Mi-256Mi memory

This prevents resource exhaustion attacks and ensures fair scheduling.

### 1.7 Seccomp profile

```yaml
containerSecurityContext:
  seccompProfile:
    type: RuntimeDefault
```

The RuntimeDefault seccomp profile restricts the set of syscalls available to
containers, reducing kernel attack surface. This is required by the Kubernetes
restricted Pod Security Standard (PSS).

---

## 2. SC-7 -- Boundary Protection

### 2.1 NetworkPolicy deny-all baseline

When `networkPolicy.enabled: true` (the default), `templates/networkpolicy.yaml`
creates a NetworkPolicy that selects all pods in the release via
`openrmf.selectorLabels` and declares both `Ingress` and `Egress` policy types.
By Kubernetes semantics, declaring a policy type with no matching rule for a given
source/destination results in implicit deny.

### 2.2 Gateway-only ingress

External traffic reaches pods only through the Traefik Gateway controller. The
ingress rule restricts source to pods matching `networkPolicy.gatewaySelector`
in the `networkPolicy.gatewayNamespace` (default: `kube-system`):

```yaml
ingress:
  - from:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: kube-system
        podSelector:
          matchLabels:
            app.kubernetes.io/name: traefik
```

Direct pod access from outside the cluster is not permitted.

### 2.3 Intra-namespace communication restricted by selector

Internal pod-to-pod communication (NATS client port 4222, MongoDB port 27017 when
operator mode is active) is restricted to pods carrying the release's own selector
labels. Pods from other releases or namespaces cannot reach these internal services.

### 2.4 Controlled egress

Egress is limited to:
- DNS resolution to `kube-system` on ports 53/TCP and 53/UDP
- Intra-release communication (pods with matching selector labels)
- External Keycloak on port 443 (only when `keycloak.mode=external` and
  `networkPolicy.allowExternalHTTPS=true`)
- External MongoDB on port 27017 (only when `mongodb.mode=external`)

All other egress is denied by default.

### 2.5 Three monitoring patterns for external access

The NetworkPolicy documents three patterns for monitoring access, each with
different network implications:

1. **Direct external scrape**: Set `networkPolicy.externalMonitoring.enabled=true`
   with a CIDR to allow inbound scraping from an external Prometheus instance.
2. **In-cluster Prometheus Agent with remote-write**: No additional ingress rules
   needed; the agent uses ServiceMonitors within the cluster.
3. **In-cluster Prometheus Operator**: Same as pattern 2; ServiceMonitors handle
   pod discovery without additional NetworkPolicy rules.

---

## 3. SC-8 -- Transmission Security

### 3.1 TLS 1.2+ via Traefik Gateway

The chart deploys a Gateway API `Gateway` resource (`templates/gateway.yaml`)
configured with an HTTPS listener:

```yaml
listeners:
  - name: https
    protocol: HTTPS
    port: 443
    tls:
      mode: Terminate
      certificateRefs:
        - name: <release>-tls
```

TLS termination occurs at the Traefik Gateway. The `gatewayClassName: traefik`
references a GatewayClass that must be configured to enforce TLS 1.2 as a minimum
protocol version. Traefik's default TLS configuration supports TLS 1.2 and 1.3.

### 3.2 RSA 4096 certificates from Vault PKI

The `templates/tls-certificate.yaml` creates a cert-manager `Certificate` resource
with the following defaults from `values.yaml`:

```yaml
httproute.tls.certificate:
  algorithm: RSA
  keySize: 4096
  duration: "2160h"      # 90 days
  renewBefore: "360h"    # 15 days before expiry
```

The issuer is configured as `vault-issuer` of kind `ClusterIssuer`, pointing to
a HashiCorp Vault PKI secrets engine. This provides automated certificate lifecycle
management backed by an enterprise-grade CA.

### 3.3 Automatic certificate rotation

With a 90-day duration and 15-day renewal window, cert-manager will request a new
certificate 75 days into the lifecycle. The Gateway references the certificate
Secret by name, and Traefik watches for Secret updates to perform zero-downtime
rotation.

### 3.4 HSTS enforcement

HTTP Strict Transport Security headers must be configured at the Gateway level via
Traefik middleware or entrypoint configuration. This is a platform-level control
that works in conjunction with the chart's HTTPS-only Gateway listener. The chart
ensures no HTTP listener is created -- the Gateway only declares an HTTPS listener
on port 443.

---

## 4. SC-28 -- Protection of Information at Rest

### 4.1 No hostPath volumes (guard clause)

The `templates/secrets.yaml` file contains a hard `fail()` guard that prevents
chart rendering if `persistence.hostPath` is set:

```yaml
{{- if .Values.persistence.hostPath }}
{{- fail "persistence.hostPath is prohibited - violates PSS restricted and NIST SP800-53 SC-28. Use a PVC with an encrypted StorageClass instead." }}
{{- end }}
```

This is a render-time enforcement that cannot be bypassed through values overrides
alone -- the chart will not produce manifests.

### 4.2 Encrypted StorageClass for MongoDB PVCs

When `mongodb.mode=operator`, the MongoDB Community Operator creates PVCs using
`mongodb.operator.storage.storageClass`. Operators must set this to an encrypted
StorageClass (e.g., one backed by LUKS-encrypted volumes or a CSI driver with
at-rest encryption). The default is empty, which defers to the cluster default
StorageClass -- this must be verified as encrypted before deployment.

### 4.3 No plaintext secrets in values.yaml

The chart's `values.yaml` contains zero plaintext credentials. All sensitive
configuration uses the `existingSecret` pattern:

- `keycloak.external.existingSecret` -- OIDC client credentials
- `mongodb.external.existingSecret` -- database connection strings
- `nats.auth.existingSecret` -- NATS authentication token

Guard clauses in `templates/secrets.yaml` enforce that these are set when the
corresponding external mode is active, failing the render with an actionable
error message directing the operator to Vault Secrets Operator.

### 4.4 Vault Secrets Operator integration

The chart is designed to work with HashiCorp Vault Secrets Operator (VSO) for
secret lifecycle management. VSO manifests are maintained separately in the Fleet
repo (`openrmf/manifests/`) and create Kubernetes Secrets that the chart references
via `existingSecret` fields. This ensures secrets are never stored in Git and are
rotated according to Vault policy.

---

## 5. CM-6 -- Configuration Settings

### 5.1 Explicit security context defaults

Security contexts are defined explicitly in `values.yaml` rather than relying on
cluster-level defaults or Pod Security Admission inheritance:

- `podSecurityContext` -- pod-level settings applied via `toYaml` in every template
- `containerSecurityContext` -- container-level settings applied via `toYaml`

This makes the chart's security posture self-documenting and portable across
clusters regardless of their admission controller configuration.

### 5.2 Pinned image tags

All images use explicit version tags. The `values.yaml` defaults pin every image:

```yaml
images:
  web:
    repository: docker.io/cingulara/openrmf-web
    tag: "1.14.00"
  nats:
    repository: docker.io/nats
    tag: "2.11.11-alpine3.22"
  api:
    read:
      tag: "1.14.00"
    # ... all API images pinned to 1.14.00
  msg:
    checklist:
      tag: "1.14.00"
    # ... all msg images pinned to 1.14.00
```

No image uses `:latest`. The `imagePullPolicy: IfNotPresent` default is appropriate
for pinned tags and avoids unnecessary registry pulls.

### 5.3 Resource limits and requests on all containers

As documented in Section 1.6, every container specifies both `requests` and `limits`
for CPU and memory. There are no containers with unbounded resource consumption.

### 5.4 Restricted PSS compliance

The chart's default security contexts comply with the Kubernetes restricted Pod
Security Standard. The combination of `runAsNonRoot`, `drop ALL capabilities`,
`allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, and
`seccompProfile: RuntimeDefault` satisfies all restricted PSS requirements.
Namespaces can safely enforce `pod-security.kubernetes.io/enforce: restricted`.

---

## 6. IA-2 / IA-5 -- Identification and Authentication / Authenticator Management

### 6.1 External secret management via Vault Secrets Operator

All credentials are managed externally through HashiCorp Vault. The chart never
generates, stores, or templates secret values. The expected workflow:

1. Vault stores the credential (OIDC client secret, MongoDB connection URI, etc.)
2. VSO `VaultStaticSecret` or `VaultDynamicSecret` syncs the value to a Kubernetes Secret
3. The chart references that Secret via `existingSecret` fields
4. Pods consume the Secret via `secretKeyRef` environment variables

### 6.2 existingSecret pattern with guard clauses

The `_helpers.tpl` template defines secret name resolution helpers that enforce
the `existingSecret` requirement:

- `openrmf.oidcSecretName`: Calls `required` when `keycloak.mode=external` and
  `keycloak.external.existingSecret` is empty
- `openrmf.mongodbSecretName`: Calls `required` when `mongodb.mode=external` and
  `mongodb.external.existingSecret` is empty

Additional `fail()` guards in `templates/secrets.yaml` provide user-friendly
error messages directing operators to create secrets via VSO.

### 6.3 OIDC credentials in Kubernetes Secrets

OIDC client credentials (`client-id`, `client-secret`) are consumed from a
Kubernetes Secret, not from `values.yaml`. The API deployment templates reference
these via `secretKeyRef`:

```yaml
- name: JWTCLIENT
  valueFrom:
    secretKeyRef:
      name: {{ include "openrmf.oidcSecretName" $ }}
      key: {{ $.Values.keycloak.external.clientIdKey | default "client-id" }}
```

This ensures OIDC credentials never appear in Helm release metadata, ConfigMaps,
or version-controlled values files.

### 6.4 lookup() preservation prevents credential regeneration

The chart does not use Helm's `lookup()` function to auto-generate secrets. All
secrets are externally provisioned. This means `helm upgrade` operations never
regenerate credentials, preventing service disruption and ensuring credential
lifecycle is governed entirely by Vault policy.

---

## 7. AU-2 / AU-3 -- Audit Events / Content of Audit Records

### 7.1 ServiceMonitor support for Prometheus metrics

When `monitoring.serviceMonitor.enabled=true`, the chart creates ServiceMonitor
resources (`templates/api-servicemonitor.yaml`) for:

- Each API service (read, scoring, template, controls, audit, report) on their
  respective HTTP ports at `/metrics`
- NATS on the monitor port (8222) at `/`

These enable Prometheus-based metrics collection for operational auditing,
performance monitoring, and anomaly detection.

### 7.2 NATS monitoring endpoint

The NATS deployment exposes a dedicated monitoring port (8222) that provides
real-time metrics about message throughput, subscriptions, and connection state.
This port is declared in `nats-deployment.yaml` and exposed via the NATS Service.
The NATS ServiceMonitor scrapes this endpoint for centralized observability.

### 7.3 Three monitoring patterns

The chart supports three documented monitoring architectures, described in the
NetworkPolicy template comments:

1. **Direct external scrape**: External Prometheus scrapes pod metrics directly.
   Requires `networkPolicy.externalMonitoring.enabled=true` with appropriate CIDR.
2. **In-cluster Prometheus Agent**: Agent runs in the cluster, discovers targets
   via ServiceMonitors, and remote-writes to a central Prometheus/Thanos.
3. **In-cluster Prometheus Operator**: Full Prometheus stack in-cluster with
   ServiceMonitor-based discovery.

### 7.4 Pod labels for audit trail and traceability

Every pod carries structured labels that support audit trail requirements:

- `app.kubernetes.io/name` -- chart name for application identification
- `app.kubernetes.io/instance` -- release name for environment correlation
- `app.kubernetes.io/version` -- application version from Chart.appVersion
- `app.kubernetes.io/managed-by` -- confirms Helm-managed lifecycle
- `app.kubernetes.io/component` -- identifies the specific microservice
  (e.g., `api-read`, `msg-checklist`, `web`, `nats`)
- `helm.sh/chart` -- chart name and version for provenance tracking

These labels enable Kubernetes audit logs, network flow logs, and monitoring
systems to correlate events to specific application components and releases.

---

## 8. Security Exceptions

### 8.1 FIPS 140-3 Container Images

**Control/Requirement**: FIPS 140-3 (Cryptographic Module Validation)

**Status**: EXCEPTION GRANTED

**Justification**:
The `cingulara/*` container images used by OpenRMF are community-maintained and do
not include FIPS 140-3 validated cryptographic modules. These images are built on
standard Alpine/Debian base images with OpenSSL, which has not undergone FIPS
validation in these builds. The upstream project (Cingulara/openrmf-web,
Cingulara/openrmf-api-read, etc.) does not publish FIPS-validated variants.

**Impact Assessment**:
- Risk Level: Medium
- Compensating Controls:
  - TLS termination is handled at the platform layer (Traefik Gateway) using
    certificates from Vault PKI, not within the application containers
  - MongoDB connections are internal-only when using the operator mode, or use
    TLS when connecting to external instances
  - NATS communication is restricted to intra-namespace traffic by NetworkPolicy
  - All external-facing cryptographic operations occur outside the application
    containers at infrastructure components that can be FIPS-validated independently

**Remediation Path**:
- Condition: Upstream cingulara project publishes FIPS-validated container images,
  or the organization builds custom images using a FIPS-validated base (e.g.,
  Iron Bank UBI base images with FIPS OpenSSL)
- Timeline: Unknown; upstream does not currently have FIPS on their roadmap
- Action Required: Monitor upstream releases; if FIPS support is required before
  upstream provides it, fork the container builds using a FIPS-validated base image
  and rebuild all 15 microservice images

**References**:
- https://github.com/Cingulara?tab=repositories (upstream repositories)
- NIST FIPS 140-3: https://csrc.nist.gov/publications/detail/fips/140/3/final

---

### 8.2 Container Image UID Validation

**Control/Requirement**: AC-6 (Least Privilege) -- Non-root container execution

**Status**: PENDING VALIDATION

**Justification**:
The chart enforces `runAsNonRoot: true` in `podSecurityContext` and sets explicit
UIDs (101 for web, 1000 for API/msg/NATS) in each deployment template. However,
the actual user configuration inside the `cingulara/*` container images has not
been independently validated. If an image's Dockerfile sets `USER root` or does
not create the expected UID, the pod will fail to start with a security context
violation -- or worse, if the image expects root for file ownership, the
application may not function correctly.

The NATS image (`docker.io/nats:2.11.11-alpine3.22`) is a well-known official
image that runs as UID 1000 by default and is considered validated.

**Impact Assessment**:
- Risk Level: Low (Kubernetes will reject pods that attempt to run as root when
  `runAsNonRoot: true` is set; the control fails safe)
- Compensating Controls:
  - `runAsNonRoot: true` provides kernel-level enforcement regardless of image contents
  - `readOnlyRootFilesystem: true` limits damage even if a container runs with
    unexpected permissions
  - `capabilities.drop: ["ALL"]` removes all Linux capabilities
  - `allowPrivilegeEscalation: false` prevents SUID exploitation

**Remediation Path**:
- Condition: Validate UIDs in all `cingulara/*` images by inspecting Dockerfiles
  or running `id` in a test deployment
- Timeline: Must be completed during initial deployment validation
- Action Required:
  1. For each `cingulara/*` image, run:
     `docker run --rm <image>:<tag> id` to confirm the default UID
  2. If any image requires root, build a custom image with a non-root user
  3. Update the corresponding `runAsUser` value if the image uses a UID other
     than the chart default
  4. Document validated UIDs in deployment records

**References**:
- Kubernetes Pod Security Standards: https://kubernetes.io/docs/concepts/security/pod-security-standards/
- CIS Kubernetes Benchmark 5.2.6: Minimize the admission of root containers

---

## 9. Validation Checklist

### 9.1 Render-time verification

Render the chart and verify guard clauses fire correctly:

```bash
# Should succeed with valid values
helm template openrmf ./charts/openrmf \
  --set keycloak.external.existingSecret=oidc-secret \
  --set keycloak.external.url=https://keycloak.example.com \
  --set mongodb.external.existingSecret=mongodb-secret

# Should FAIL: hostPath is prohibited
helm template openrmf ./charts/openrmf \
  --set persistence.hostPath=/data \
  --set keycloak.external.existingSecret=oidc-secret \
  --set keycloak.external.url=https://keycloak.example.com \
  --set mongodb.external.existingSecret=mongodb-secret

# Should FAIL: missing existingSecret for external Keycloak
helm template openrmf ./charts/openrmf \
  --set mongodb.external.existingSecret=mongodb-secret
```

### 9.2 Policy-as-code checks

Run rendered manifests through policy engines:

```bash
helm template openrmf ./charts/openrmf \
  --set keycloak.external.existingSecret=oidc-secret \
  --set keycloak.external.url=https://keycloak.example.com \
  --set mongodb.external.existingSecret=mongodb-secret \
  > rendered.yaml

# Schema validation
kubeconform -strict rendered.yaml

# OPA/Conftest policy checks
conftest test rendered.yaml

# Kyverno policy checks
kyverno apply ./policies --resource rendered.yaml
```

Expected results:
- No privileged containers
- No privilege escalation
- No missing resource limits
- NetworkPolicy present
- SA token automount disabled
- No hostPath volumes

### 9.3 Runtime verification

After deploying to a cluster, verify:

1. **Security contexts active**: `kubectl get pods -n <ns> -o jsonpath='{.items[*].spec.securityContext}'`
2. **NetworkPolicy effective**: Attempt connections from unauthorized pods and verify rejection
3. **TLS-only access**: `curl -I https://<hostname>` returns valid TLS; `curl http://<hostname>` is refused
4. **Secrets sourced from Vault**: `kubectl get secret <secret-name> -o jsonpath='{.metadata.annotations}'` shows VSO provenance
5. **Container UIDs**: `kubectl exec <pod> -- id` confirms non-root UID

---

## 10. Controls Not Fully Solved in Helm Templates

These controls require platform-level or process-level integration beyond what a
Helm chart can enforce:

| Control | Description | Owner |
|---------|-------------|-------|
| AU-2/AU-3 | Centralized log retention and audit event selection | Platform / SIEM team |
| RA-5 | Continuous vulnerability scanning of container images | CI/CD pipeline |
| SI-2 | Flaw remediation SLAs and patch governance | Security / DevSecOps |
| IA-2(12) | Multi-factor authentication for remote access | Identity provider (Keycloak + MFA) |
| SC-8(1) | Cryptographic protection of transmission (FIPS ciphers) | Gateway / Traefik configuration |
| SC-28(1) | Cryptographic protection of data at rest | Storage / CSI driver configuration |

Track these in your SSP/POA&M as shared controls with the platform and security teams.

---

## 11. Implementation Summary

| Control | Chart Enforcement | Template/Values Reference |
|---------|------------------|--------------------------|
| AC-6 | runAsNonRoot, explicit UIDs, drop ALL, no privilege escalation, no SA token, read-only root, resource limits | `values.yaml`, all deployment templates |
| SC-7 | Deny-all NetworkPolicy, gateway-only ingress, label-scoped intra-namespace rules | `templates/networkpolicy.yaml`, `values.yaml` |
| SC-8 | HTTPS Gateway, RSA 4096 certs, 90-day rotation, cert-manager + Vault PKI | `templates/gateway.yaml`, `templates/tls-certificate.yaml` |
| SC-28 | hostPath fail() guard, encrypted StorageClass recommendation, no plaintext secrets | `templates/secrets.yaml`, `values.yaml` |
| CM-6 | Explicit security contexts, pinned image tags, resource limits, restricted PSS | `values.yaml`, all deployment templates |
| IA-2/IA-5 | existingSecret pattern, guard clauses, VSO integration, no credential generation | `templates/secrets.yaml`, `templates/_helpers.tpl` |
| AU-2/AU-3 | ServiceMonitor resources, NATS monitoring, structured pod labels | `templates/api-servicemonitor.yaml`, all deployment templates |
