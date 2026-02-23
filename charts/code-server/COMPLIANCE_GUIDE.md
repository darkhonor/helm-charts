# code-server Helm Chart Compliance Guide (NIST 800-53 Rev 5 Moderate)

This guide walks you through required changes to move the `code-server` chart toward a defensible `NIST_800_53_R5` Moderate posture.

Scope:
- Chart path: `HomeLab/helm-charts/charts/code-server`
- Primary framework: NIST 800-53 Rev 5 Moderate
- Control focus: `AC-6`, `SC-7`, `SC-8`, `IA-2`, `IA-5`, `SC-28`, `CM-6`, `CM-7`

## 1. Lock down pod and container privileges (Required)

Controls:
- `AC-6` Least Privilege
- `CM-6` Configuration Settings
- `CM-7` Least Functionality

### 1.1 Update `values.yaml` security defaults

Edit `values.yaml` and add hardened defaults under `securityContext`.

Required settings:
- `runAsNonRoot: true`
- `allowPrivilegeEscalation: false`
- `readOnlyRootFilesystem: true` (if compatible with runtime behavior)
- `capabilities.drop: ["ALL"]`
- `seccompProfile.type: RuntimeDefault`

Also pin init-container image by digest and avoid `latest`.

### 1.2 Update `templates/deployment.yaml` to enforce settings

In the main container `securityContext`, template in the fields above.

Add to pod spec:
- `automountServiceAccountToken: false` by default (see Section 2 for configurable flag)

For init container:
- Keep root only if strictly necessary for volume ownership.
- If root is required, keep scope minimal and document exception in chart README.

### 1.3 Restrict or remove privileged extension points

The chart allows arbitrary `extraContainers` and `extraInitContainers`.

Required action:
- Document these as high-risk escape hatches.
- In compliance profile values, keep them empty.
- If used, require explicit security review and exceptions.

## 2. Minimize service account exposure (Required)

Controls:
- `AC-6`
- `CM-6`

### 2.1 Add explicit automount control in `values.yaml`

Add:
- `serviceAccount.automountServiceAccountToken: false`

### 2.2 Apply it in `templates/serviceaccount.yaml`

Set:
- `automountServiceAccountToken: {{ .Values.serviceAccount.automountServiceAccountToken }}`

### 2.3 Apply it in `templates/deployment.yaml`

Set pod-level override too:
- `automountServiceAccountToken: {{ .Values.serviceAccount.automountServiceAccountToken }}`

This prevents accidental API token exposure in pods.

## 3. Enforce network boundaries with NetworkPolicy (Required)

Controls:
- `SC-7` Boundary Protection
- `CM-7`

### 3.1 Add `templates/networkpolicy.yaml`

Create a deny-by-default model with controlled ingress/egress.

Minimum required behavior:
- Ingress:
  - Allow only from ingress controller namespace/pods or approved app labels.
  - Restrict to port `8080`.
- Egress:
  - Allow DNS to kube-dns/CoreDNS.
  - Allow only explicitly required destinations (package mirrors, Git hosts, artifact registries) as policy requires.
  - Deny all other egress.

### 3.2 Add policy toggles in `values.yaml`

Add:
- `networkPolicy.enabled: true`
- allowlists for ingress namespaces/pod labels
- allowlists for required egress CIDRs or selectors

Do not ship compliance profile with `networkPolicy.enabled: false`.

## 4. Require TLS for remote access (Required when exposed)

Controls:
- `SC-8` Transmission Confidentiality and Integrity
- `AC-17` Remote Access

### 4.1 TLS via Gateway API (Implemented)

The chart uses Gateway API `HTTPRoute` instead of Ingress. TLS termination is handled
at the Gateway level (Traefik) rather than in the application chart. This is the
recommended separation of concerns:

- The `Gateway` resource (managed separately) configures TLS listeners, certificates,
  and cipher suites.
- The `HTTPRoute` resource (this chart) attaches to the Gateway via `parentRefs` and
  routes traffic to the code-server Service.

**Compliance requirement**: The referenced Gateway MUST be configured with:
- TLS 1.2 minimum (TLS 1.3 preferred)
- FIPS-approved cipher suites
- Valid certificates from an approved CA or cert-manager
- HSTS headers (configured at the Gateway/middleware level)

### 4.2 Verify Gateway TLS configuration

Since TLS is not managed by this chart, verify at the platform level:
- Gateway listener enforces HTTPS
- HTTP-to-HTTPS redirect is configured
- Certificate rotation is automated (cert-manager or equivalent)

## 5. Strengthen authenticator management (Required)

Controls:
- `IA-2`
- `IA-5`

### 5.1 Disable chart-generated random secret in compliance mode

Current template can auto-generate a password secret.

Required for controlled environments:
- Require `existingSecret` in compliance profile.
- Fail chart render if compliance mode is enabled and `existingSecret` is empty.

### 5.2 Enforce secret handling expectations

Operational requirements:
- Secret must be provisioned through approved secret management workflow (External Secrets, Vault, sealed-secrets, etc.).
- Rotate on defined schedule.
- No plaintext credentials in `values.yaml` committed to Git.

### 5.3 Add SSO/MFA front-door requirement (platform control)

`code-server` password auth alone is generally insufficient for Moderate remote-access posture.

Required platform pattern:
- Put `code-server` behind an authenticated reverse proxy or identity-aware access proxy.
- Enforce MFA at proxy/IdP layer.

## 6. Protect data at rest (Required)

Controls:
- `SC-28`

### 6.1 Enforce encrypted storage class in compliance profile

Set `persistence.storageClass` to an encrypted class backed by KMS/provider-managed encryption.

Required:
- Document approved storage class names per cluster/environment.
- Do not rely on default storage class unless verified encrypted.

### 6.2 Prevent insecure hostPath use in compliance mode

`hostPath` is high risk.

Required:
- In compliance mode, fail if `persistence.hostPath` is set.

## 7. Eliminate mutable or weak image controls (Required)

Controls:
- `CM-6`
- `SI-2`
- `RA-5`

### 7.1 Pin all images

Required:
- Pin `code-server` image by immutable tag or digest.
- Pin init image (`busybox`) to digest; do not use `latest`.

### 7.2 Define pull policy and provenance expectations

Recommended compliance defaults:
- `IfNotPresent` for pinned digests.
- Use approved registries only.
- Sign/verify images (Cosign or platform equivalent).

### 7.3 Integrate scanning and patch SLAs (pipeline controls)

Required outside chart:
- CI image vulnerability scanning gates.
- Policy for remediation timelines by severity.
- Rebuild/redeploy cadence for base image CVEs.

## 8. Add required resource and runtime safeguards (Required)

Controls:
- `CM-6`
- `CM-7`

### 8.1 Set default resource requests/limits

Do not leave `resources: {}` in compliance profile.

Required:
- CPU/memory requests and limits set to approved values.

### 8.2 Ensure writable paths are explicit

If `readOnlyRootFilesystem=true`, mount writable volumes only where required (e.g., `/home/coder`).

Document any additional writable mount paths and why they are needed.

## 9. Add compliance-mode guardrails in templates (Required)

Add a top-level values flag:
- `compliance.mode: false` (default)

When `compliance.mode=true`, template should fail render unless all required conditions are met.

Suggested guard checks:
- `existingSecret` must be set
- `networkPolicy.enabled` must be true
- ingress TLS must be configured when ingress is enabled
- `persistence.hostPath` must be empty
- securityContext hardening fields must be enabled
- images must not use `latest`

Use Helm `fail`/`required` for deterministic enforcement.

## 10. Files to modify/add

Modified:
- `values.yaml` — restructured securityContext, added containerSecurityContext, networkPolicy, resource defaults
- `templates/deployment.yaml` — hardened security contexts, pinned init image, /tmp emptyDir, automountServiceAccountToken
- `templates/serviceaccount.yaml` — automountServiceAccountToken, annotations support
- `templates/httproute.yaml` — replaced ingress.yaml with Gateway API HTTPRoute
- `templates/secrets.yaml` — (pending: compliance mode fail check)

Added:
- `templates/networkpolicy.yaml` — deny-by-default with controlled ingress/egress
- `values-compliance.yaml` — (pending: hardened profile overlay)

Removed:
- `templates/ingress.yaml` — replaced by httproute.yaml

## 11. Validation checklist (Required before deployment)

### 11.1 Render-time checks

Run:

```bash
helm template code-server ./HomeLab/helm-charts/charts/code-server -f ./HomeLab/helm-charts/charts/code-server/values-compliance.yaml
```

Expected:
- Render succeeds only when compliance requirements are met.
- Render fails with clear messages when required settings are missing.

### 11.2 Policy-as-code checks

Run one or more:

```bash
kubeconform -strict rendered.yaml
```

```bash
conftest test rendered.yaml
```

```bash
kyverno apply ./policies --resource rendered.yaml
```

Expected:
- No privileged containers
- No privilege escalation
- No missing NetworkPolicy
- Ingress enforces TLS
- SA token automount disabled

### 11.3 Runtime verification

After deploy, verify:
- Pod security context values are active
- NetworkPolicy effective traffic restrictions
- TLS-only remote access
- Secret sourced from approved workflow
- Storage class is encrypted

## 12. Controls not fully solved in Helm templates

These require platform/process integration:
- `AU-2` Event logging strategy and centralized retention
- `RA-5` Continuous vulnerability monitoring/scanning operations
- `SI-2` Flaw remediation SLAs and patch governance
- `IA-2`/`IA-5` MFA and enterprise identity lifecycle (if externalized)

Track these in your SSP/POA&M as shared controls with the platform/security team.

## 13. Implementation order (recommended)

1. Add compliance mode flag and guardrails.
2. Implement pod/container hardening and SA token controls.
3. Add NetworkPolicy template and enable by default in compliance values.
4. Enforce ingress TLS requirements.
5. Require external secret and storage encryption controls.
6. Pin images and set resource defaults.
7. Add CI policy tests and runtime verification steps.

## 14. Definition of done

The chart is considered compliance-ready when:
- `values-compliance.yaml` deploys successfully without exceptions.
- Required guardrails block unsafe configurations at render time.
- Policy checks pass in CI.
- Runtime checks confirm controls are effective.
- Shared controls are documented with clear ownership.
