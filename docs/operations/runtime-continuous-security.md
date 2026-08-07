# Runtime & Continuous Security (Trivy Operator + Falco)

Two `worker`-scoped security additions that complement the gate-time scanners
(Chargate/MegaLinter, SonarQube) with **continuous** and **runtime** coverage.

## Trivy Operator — continuous workload scanning

`kubernetes/apps/trivy-operator` (ns `trivy-system`) continuously scans the images,
configs, and secrets of **what's actually running** (not just what passed CI),
writing `VulnerabilityReport` / `ConfigAuditReport` / `ExposedSecretReport` CRDs and
exposing Prometheus metrics (ServiceMonitor enabled — the kube-prometheus-stack
scrapes it). `kube-system`/`flux-system`/etc. are excluded; scanner Jobs run on the
worker.

```bash
kubectl get vulnerabilityreports -A
kubectl get configauditreports -A
```

**Follow-up — feed DefectDojo**: a CronJob (like `sonarqube-defectdojo-sync`) that
reads the `VulnerabilityReport` CRDs and import-scans them into DefectDojo
("Trivy Operator Scan" parser) so they dedupe alongside SonarQube / Dependency-Track.
Deferred from this PR because it needs cluster-read RBAC + a DefectDojo API token.

## Falco — runtime threat detection

`kubernetes/apps/falco` (ns `falco`) runs the Falco eBPF runtime-detection DaemonSet,
catching the syscall-level activity that posture/scan tools (Trivy) cannot —
shells in containers, unexpected outbound connections, package installs at runtime, etc.

- **Worker-only.** The control-plane Pi runs a **16KB-page arm64 kernel** where Falco's
  eBPF probe is unreliable, so Falco is pinned off it via `nodeSelector` (it still covers
  where the workloads run).
- Alerts go through **falcosidekick → Loki** (forwarded best-effort; Falco also logs to
  stdout and exposes Prometheus metrics regardless), with a bundled Grafana dashboard.
  **Verify the Loki push endpoint** (`loki-gateway.observability`) for your install.
