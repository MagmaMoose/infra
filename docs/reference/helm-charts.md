# Helm and Kustomize: 2026 analysis

<!-- sources: kubernetes/components, kubernetes/apps, kubernetes/infrastructure -->

!!! note "This is a decision record, not a how-to"
    Written in May 2026 to weigh adding Helm alongside Kustomize. It's kept for the reasoning.
    Two of its premises have since changed, and the outcome was narrower than the analysis
    proposed. Read this section before acting on anything below it.

## What actually happened

- **Helm is in use, through Flux.** Charts are consumed as `HelmRelease` objects. There's no
  chart source tree in this repository; charts live upstream or in the separate charts repo.
- **The resource-profile components this analysis builds on are gone.** They were deleted on
  2026-08-07 in [#569](https://github.com/CalebSargeant/infra/pull/569). Requests and limits
  are inlined now. See [Resource profiles](resource-profiles.md).
- **`_components/` no longer exists.** The components that remain live in
  `kubernetes/components/`: `gluetun-sidecar`, `helm-release-standards`, `helm-releases`,
  `ingress-standards`, `node-selectors`, `pod-gateway-client`, `vpn-routed-proxy`, and
  `wireguard-sidecar`.
- **A per-chart page was scaffolded for 19 applications and never written.** Those empty
  pages were removed. Ten of the 19 applications no longer exist in the cluster.

!!! warning "Kustomize labels don't reach a chart's workloads"
    The one operational consequence worth carrying forward. A placement label applied to a
    kustomization whose workload is a `HelmRelease` stops at the HelmRelease, so the chart's
    Deployment is never pinned, and nothing reports it. The
    [Placement workflow](github-workflows.md#placement) fails a pull request that does this.

## Original analysis (May 2026)

### Summary as written

Converting to Helm was assessed as a good strategic move, on four grounds:

1. The resource-profile and node-selector component pattern could be kept while eliminating
   folder duplication.
2. Helm charts provide templating that beats individual YAML files for multi-application bases.
3. FluxCD has native Helm support.
4. Kustomize components work on Helm output.

The caveat as written: Helm isn't a replacement for Kustomize. The two complement each other,
with Helm doing templating and Kustomize doing final customisation and components.

## Detailed Pros and Cons

### PROS of Adding Helm

#### 1. **Eliminate Folder Duplication** ✅ **BIGGEST WIN**
**Current state:** Every base app creates multiple files (daemonset.yaml, service.yaml, ingress.yaml, pvc.yaml, pv.yaml) that are nearly identical across services. Homebridge is a good example: 6 files in `_base/automation/homebridge/` with hardcoded values.

**With Helm:** A single `homebridge/Chart.yaml` + `values.yaml` eliminates this duplication. You template once, parameterize everything.

```text
# Current: 6 files, hardcoded values
_base/automation/homebridge/
  ├── daemonset.yaml       (hardcoded image, resources, ports)
  ├── service.yaml         (hardcoded port 8581)
  ├── ingress.yaml         (hardcoded hostnames, cert-manager)
  ├── pvc.yaml             (hardcoded storage 5Gi)
  ├── pv.yaml              (hardcoded /mnt/nvme/homebridge-config)
  └── kustomization.yaml

# With Helm: 2 files, fully parameterized
_base/automation/homebridge/
  ├── Chart.yaml
  ├── values.yaml
  ├── templates/
  │   ├── daemonset.yaml   ({{ .Values.image }}, {{ .Values.resources }}, etc)
  │   ├── service.yaml     ({{ .Values.service.port }})
  │   ├── ingress.yaml     ({{ .Values.ingress.hosts }})
  │   ├── pvc.yaml         ({{ .Values.storage.size }})
  │   └── pv.yaml          ({{ .Values.storage.hostPath }})
  └── kustomization.yaml   (reference chart)
```

#### 2. **Parameterize Everything**
You can override any value per cluster without file duplication:

```yaml
# firefly cluster overlay - just specifies overrides
clusters/firefly/automation/homebridge/values.yaml
  domain: sargeant.co
  image: homebridge/homebridge:beta-2025-10-03
  timezone: Europe/Amsterdam
```

#### 3. **Reduce `_base/` Explosion**
As you add more apps, you get 5-6 files per app multiplied by N apps. Helm keeps this linear: 1 chart per app.

#### 4. **Resource Profiles & Node Selectors Still Work**
Your components layer **on top of Helm outputs**, so you still get:
```yaml
# This still works!
resources:
  - helm-chart-for-homebridge
components:
  - ../../../../_components/resource-profiles/c.pico
  - ../../../../_components/node-selectors/pi
```

The Kustomize components apply patches to whatever Helm generates. **This is the golden combination.**

#### 5. **Package Reusability**
If you ever want to publish charts (internal Helm repo, ArtifactHub, etc), you're ready. If you want to use upstream Helm charts for some services, you can mix in paralleled charts.

#### 6. **Better Documentation**
Helm charts have a standard structure that other engineers recognize. `values.yaml` is self-documenting when properly commented.

#### 7. **Dependency Management**
Helm supports chart dependencies (`Chart.lock`). If multiple apps share config (e.g., cert-manager issuers, Traefik config), you can package those as sub-dependencies.

---

### CONS of Adding Helm

#### 1. **Learning Curve**
Go templating syntax (`{{ .Values }}`, `if/else`, `range`, `$`) adds complexity. Your team needs to understand:
- Helm template functions (`.Values`, `include`, `tpl`, etc)
- Helper templates (`_helpers.tpl`)
- Helm lifecycle (install, upgrade, diff)

**Mitigation:** Start with simple, non-Helm apps to learn before migrating everything.

#### 2. **Helm Templating is Less Powerful Than Kustomize Patching**
Kustomize's JSON6902 patches are more explicit; Helm's Go templates are more implicit. If you need complex multi-layer customization, you might end up fighting Go template syntax.

Example: Helm can't easily do "patch this field only if it exists" without complex conditionals. Kustomize's `merge` strategy is cleaner for some cases.

**Mitigation:** Use both (Helm for the app base, Kustomize components for cross-cutting concerns).

#### 3. **Secret Management Complexity**
Helm has built-in secrets support, but you're already using SOPS + GPG. Mixing them requires careful coordination. You'll need to decide: secrets in Helm values or in Kustomize overlays?

**Mitigation:** Keep using SOPS for secrets, just reference them in Helm values:
```yaml
# values.yaml
existingSecret: homebridge-config  # Created by Kustomize/SOPS
```

#### 4. **Cluster Overlay Duplication (Different Problem)**
While Helm reduces `_base/` duplication, you still need cluster-specific overlays. You'll have:
```text
kubernetes/apps/homebridge/
  ├── kustomization.yaml          (reference Helm chart + components)
  └── values-firefly.yaml          (cluster overrides)
```
This is **less duplication than before** (1 values file vs 6 YAML files), but it's still some duplication if you have many clusters.

#### 5. **Operational Overhead**
Managing Helm chart versions, testing upgrades, maintaining `Chart.lock` files. Minor, but adds process.

---

## Comparison Matrix

| Aspect | Kustomize-Only | Helm + Kustomize |
|--------|---|---|
| **Template files per app** | 5-6 (`daemonset.yaml`, `service.yaml`, etc) | 1-2 (`templates/`, `values.yaml`) |
| **Parameterization** | Limited (strategic merge patches) | Full (Go templates) |
| **Component compatibility** | ✅ Native | ✅ Works on rendered output |
| **Learning curve** | Easier | Steeper (Go templates) |
| **Secrets management** | SOPS directly | SOPS + Helm values |
| **Reusability** | Per-cluster overlays | Charts + values |
| **Dependencies** | Manual (kustomization.yaml) | Automatic (Chart.lock) |

---

## Helm + Kustomize Best Practices

### Architecture Pattern

```text
kubernetes/apps/homebridge/          # Helm chart (NOT raw YAML)
  ├── Chart.yaml
  ├── values.yaml                     # Defaults for all clusters
  ├── templates/
  │   ├── daemonset.yaml
  │   ├── service.yaml
  │   ├── ingress.yaml
  │   ├── pvc.yaml
  │   ├── pv.yaml
  │   └── _helpers.tpl                # Reusable helper templates
  └── kustomization.yaml              # Treat chart as resource

clusters/firefly/automation/homebridge/
  ├── kustomization.yaml              # Use Helm release + components
  └── values-firefly.yaml             # Cluster-specific overrides

_components/resource-profiles/        # Unchanged—patches apply to Helm output
_components/node-selectors/           # Unchanged—patches apply to Helm output
```

### How Kustomization References Helm Chart

**Option A: Direct Helm Release (Recommended)**
```yaml
# clusters/firefly/automation/homebridge/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

helmCharts:
  - name: homebridge
    repo: oci://localhost:5000/charts        # Local or remote
    version: 1.0.0
    releaseName: homebridge
    namespace: homebridge
    valuesInline:
      timezone: Europe/Amsterdam
      domain: sargeant.co
    # OR: valuesFile: values-firefly.yaml

components:
  - ../../../../_components/resource-profiles/c.pico
  - ../../../../_components/node-selectors/pi
```

**Option B: GitOps with Flux HelmChart** (What you likely want)
Let Flux manage the Helm release, Kustomize only adds components:

```yaml
# clusters/firefly/automation/homebridge/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - helmrelease.yaml          # FluxCD HelmRelease CR

components:
  - ../../../../_components/resource-profiles/c.pico
  - ../../../../_components/node-selectors/pi
```

```yaml
# clusters/firefly/automation/homebridge/helmrelease.yaml
apiVersion: helm.fluxcd.io/v2beta1
kind: HelmRelease
metadata:
  name: homebridge
  namespace: homebridge
spec:
  releaseName: homebridge
  chart:
    spec:
      chart: ./homebridge                # Reference local chart path
      sourceRef:
        kind: GitRepository
        name: infra
        namespace: flux-system
  values:
    timezone: Europe/Amsterdam
    domain: sargeant.co
```

---

## Homebridge Case Study: Step-by-Step Conversion

### Current State
- 6 files in `_base/automation/homebridge/`
- Hardcoded values scattered across YAML
- Overlay at `clusters/firefly/automation/homebridge/` just references base + adds components

### New State (Helm-based)

**Step 1: Create Helm Chart Structure**
```bash
mkdir -p kubernetes/apps/homebridge/templates
cat > kubernetes/apps/homebridge/Chart.yaml << 'EOF'
apiVersion: v2
name: homebridge
description: A Helm chart for Homebridge
type: application
version: 1.0.0
appVersion: "2025-10-03"
EOF

cat > kubernetes/apps/homebridge/values.yaml << 'EOF'
# Global values
namespace: homebridge

# Image config
image:
  repository: homebridge/homebridge
  tag: "beta-2025-10-03"
  pullPolicy: IfNotPresent

# Timezone
timezone: "Europe/Amsterdam"

# Daemonset config
daemonset:
  enabled: true
  hostNetwork: true
  dnsPolicy: ClusterFirstWithHostNet

# Resources
resources:
  requests:
    memory: "256Mi"
    cpu: "100m"
  limits:
    memory: "1Gi"
    cpu: "500m"

# Ports
ports:
  homekit: 51826
  webui: 8581

# Service
service:
  type: ClusterIP
  port: 8581
  targetPort: 8581

# Storage
storage:
  size: "5Gi"
  storageClassName: "homebridge"
  hostPath: "/mnt/nvme/homebridge-config"

# Ingress
ingress:
  enabled: true
  className: traefik
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/service.serversscheme: http
    traefik.ingress.kubernetes.io/router.tls: "true"
    cert-manager.io/cluster-issuer: letsencrypt-dns
  hosts:
    - homebridge.sargeant.co
    - homebridge.sargeant.local
  tls:
    enabled: true
    secretName: homebridge-tls
EOF
```

**Step 2: Create Templates**

```bash
# templates/daemonset.yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: {{ include "homebridge.fullname" . }}
  namespace: {{ .Values.namespace }}
spec:
  selector:
    matchLabels:
      {{- include "homebridge.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "homebridge.selectorLabels" . | nindent 8 }}
    spec:
      hostNetwork: {{ .Values.daemonset.hostNetwork }}
      dnsPolicy: {{ .Values.daemonset.dnsPolicy }}
      containers:
        - name: homebridge
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
          ports:
            - containerPort: {{ .Values.ports.homekit }}
              name: homekit
            - containerPort: {{ .Values.ports.webui }}
              name: webui
          env:
            - name: TZ
              value: {{ .Values.timezone | quote }}
          volumeMounts:
            - mountPath: /homebridge
              name: homebridge
      volumes:
        - name: homebridge
          persistentVolumeClaim:
            claimName: {{ include "homebridge.fullname" . }}

# templates/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ include "homebridge.fullname" . }}
  namespace: {{ .Values.namespace }}
spec:
  type: {{ .Values.service.type }}
  selector:
    {{- include "homebridge.selectorLabels" . | nindent 4 }}
  ports:
    - name: web-ui
      port: {{ .Values.service.port }}
      targetPort: {{ .Values.service.targetPort }}

# templates/pvc.yaml, templates/pv.yaml, templates/ingress.yaml (similar pattern)

# templates/_helpers.tpl
{{- define "homebridge.fullname" -}}
homebridge
{{- end }}

{{- define "homebridge.selectorLabels" -}}
app: {{ include "homebridge.fullname" . }}
{{- end }}
```

**Step 3: Update Kustomization Files**

```yaml
# kubernetes/apps/homebridge/kustomization.yaml
# (Just serves as a helm repo reference for local development)
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

helmCharts:
  - name: homebridge
    repo: oci://localhost:5000/charts  # Or just reference chart path
    version: 1.0.0
    releaseName: homebridge
    namespace: homebridge
```

**Step 4: Update Cluster Overlay**

```yaml
# clusters/firefly/automation/homebridge/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - helmrelease.yaml

components:
  - ../../../../_components/resource-profiles/c.pico
  - ../../../../_components/node-selectors/pi
```

```yaml
# clusters/firefly/automation/homebridge/helmrelease.yaml
apiVersion: helm.fluxcd.io/v2beta1
kind: HelmRelease
metadata:
  name: homebridge
  namespace: homebridge
spec:
  releaseName: homebridge
  chart:
    spec:
      chart: ./homebridge  # Path relative to GitRepository
      sourceRef:
        kind: GitRepository
        name: infra
        namespace: flux-system
  values:
    timezone: Europe/Amsterdam  # Override if different
    # Rest uses values.yaml defaults
```

**Result:** Homebridge drops from ~200 lines of raw YAML → ~80 lines (templates + values), **and 100% parameterized**.

---

## Migration Strategy

### Phase 1: Pilot (Start with Homebridge)
1. Create Helm chart as shown above
2. Test with `helm template homebridge kubernetes/apps/homebridge/`
3. Verify it produces identical YAML to current state
4. Update `clusters/firefly/automation/homebridge/` to use Helm
5. Test with Flux: `flux create source git ... && flux create helmrelease ...`

### Phase 2: Low-Risk Apps
Migrate apps with simple, standardized deployments (no custom logic):
- Home Assistant (similar pattern to Homebridge)
- n8n (similar pattern)

### Phase 3: Complex Apps
Migrate services with more complex needs (databases, multiple replicas):
- PostgreSQL (multiple files, complex storage)
- Media stack services (Radarr, Sonarr, Plex)

### Phase 4: Review & Refactor
Once most apps are Helm-based, consider:
- Creating an `_internal/` Helm repo (artifacthub) if you have >5 apps
- Consolidating common patterns (all services share similar ingress, RBAC, etc)
- Extracting a `common` Helm chart as dependency

---

## Recommendations

### ✅ DO
1. **Start with Helm + Kustomize** (not Helm alone): this preserves your component pattern
2. **Keep SOPS for secrets**: don't try to manage secrets in Helm values
3. **Store Helm charts in Git** (`kubernetes/apps/` dir) until you have 10+ charts
4. **Use Kustomize HelmChart support** or Flux HelmRelease CRs for deployment
5. **Document values.yaml extensively** with comments explaining each parameter
6. **Version your charts** even if they're internal (in `Chart.yaml` → Git tags)

### ❌ DON'T
1. **Don't replace all Kustomize with Helm**: Helm is for templating, Kustomize is for final customization
2. **Don't store secrets in `values.yaml`**: reference external Secret CRs instead
3. **Don't create mega-charts**: one chart per application
4. **Don't try to eliminate cluster overlays entirely**: you'll always need some per-cluster config
5. **Don't over-parameterize**: if a value is never overridden, hardcode it

---

## Expected Outcomes

After Helm + Kustomize integration, for Homebridge-like apps:

| Metric | Current | With Helm |
|--------|---------|-----------|
| **Files per app** | 6-7 | 2-3 |
| **Parameterization coverage** | ~30% | ~95% |
| **Lines of code** | 200 | 80 |
| **Code duplication** | High | Minimal |
| **Ease of cluster override** | Patches | Direct values |

Across your entire `_base/` (which likely has 15+ apps), you'd reduce:
- **From:** 90-105 YAML files  
- **To:** 30-45 template files + values

A **60-70% reduction** in boilerplate while **gaining flexibility**.

---

## Next Steps

1. **Review this analysis** with your team
2. **Try the Homebridge conversion** as a proof of concept (1-2 hours)
3. **Run `helm template` and diff** against current manifests to verify
4. **Plan Phase 1-2 migrations** based on comfort level
5. **Document your Helm patterns** for consistency across charts
