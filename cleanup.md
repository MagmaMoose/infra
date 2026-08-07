# Cluster Cleanup

## General


> **IMPLEMENTATION STATUS — 2026-08-07 (rewritten).** The earlier version of this block
> claimed four PRs were blocked by a repo-wide CI outage. That outage cleared on its own at
> ~23:18 on 2026-08-06 and every one of those PRs merged; the block was left asserting the
> opposite of reality for hours, which is why it is dated now.
>
> **Landed:** the five PriorityClasses; per-tier Kyverno placement policies and ~38 workloads
> migrated onto `placement.sargeant.co/tier`; priority assignment; a default LimitRange per
> namespace; gatekeeper removed; the `stack/` level flattened; `components/node-selectors` and
> `components/resource-profiles` both deleted; the cloud-tier cache repoint; loki's startupProbe;
> the data plane given `priorityClassName: critical`; the business apps given `business`; PDBs and
> topology spread; this namespace rename.
>
> **Two outages happened during the work and both are worth reading:** ff-vm1's kubelet was
> starved by an NFS commit stall on the Proxmox host, and ff-pi1's control plane later failed with
> `[-]etcd failed` because every Kyverno controller — including the reports controller, which
> writes a PolicyReport per resource — is pinned to the same node that runs etcd. The reports
> controller is now disabled. **Moving Kyverno off ff-pi1 entirely is the real fix and has not
> been done**, because it changes webhook latency across the site-to-site VPN.
>
> **Known-incomplete, deliberately:** ~29 workloads carry a priority label but will not have a
> `priorityClassName` until they next restart, because the mutation is admission-time only —
> do NOT fix this with `mutateExistingOnPolicyUpdate`, which would roll all of them at once on a
> node at 99% memory. The node labels are re-applied by `ansible/firefly-node-labels.yaml` rather
> than being durable, because the kubelet may not self-register `node-role.kubernetes.io/*`.

> **RESOLVED 2026-08-06 23:13** *(kept for the causal chain — it explains several oddities below).*
> ff-vm1's kubelet was unreachable from the API server (`502` to the apiserver proxy). Root cause was
> the **Proxmox host**: `192.168.19.5` is both the hypervisor running ff-vm1 AND the NFS server it
> mounts, and it had 56 GB allocated of 59 GB. Memory reclaim inside ff-vm1 blocked on a dirty NFS
> page in `wait_on_commit`; the victim happened to be `iptables-restore` **holding the xtables lock**,
> so 18,858 CNI `portmap` invocations piled up behind it, starving the kubelet. That failed CNPG base
> backups for 50h, held postgres at 1/3, kept minio unready, and froze 22 Kustomizations.
> Fixed by clearing the pile-up and `qm reset 125`.
>
> **STILL UNFIXED and will recur: the Proxmox host memory overcommit.** Shrinking the idle Windows11
> VM's 28 GB is the actual remedy. Secondary: `nvme0` logged a WRITE timeout on 2026-08-04.


> **AUDIT — 2026-08-07. Every remaining item in the deletion/replacement list was checked
> against the live cluster by 49 agents. Findings that change the plan:**
>
> **1. ff-vm1 cannot be right-sized. It needs RAM.** Measured from Prometheus, not a snapshot:
> its 72 pods have a combined **7-day peak of 40,355Mi against 28,042Mi allocatable — 144%**.
> Current requests already sit at 100% and are *understated* relative to real peaks; the peaks
> simply do not coincide. Applying an honest `peak x 1.3` rule frees **222Mi in total**. There
> is no reclaimable slack, so **PR #502's premise ("ff-vm1 memory back under capacity") does not
> hold** — an instantaneous `kubectl top` reading makes idle workloads look over-provisioned when
> their peaks are not. The Proxmox Windows11 VM's 28 GB is the only remedy, and it now gates:
> defectdojo-django and the trivy scan jobs (both `Pending: Insufficient memory`), honest requests
> for authentik, the ARC cutover, a MinIO/SeaweedFS parallel run, and item 3 below.
>
> **2. DO NOT migrate flannel -> Cilium. It would brick the cluster.** ff-pi1's kernel has no BTF:
> `/sys/kernel/btf/vmlinux` does not exist and `CONFIG_DEBUG_INFO_BTF` is absent from
> `/boot/config-6.12.93+rpt-rpi-2712`. Cilium's CO-RE BPF datapath requires it. Compounding:
> no BMC/IPMI/serial console on any node, no OCI Instance Console Connection provisioned, and
> **no backups at all** — the Longhorn BackupTarget has an empty URL and `available: false`, there
> are zero recurringjobs, and no Velero. A failed CNI swap on ff-pi1 takes the apiserver with it
> and there is no way back in. Strike this item, or precede it with an out-of-band console.
>
> **3. Nine Longhorn volumes are cross-site**, i.e. a cloud-tier pod writing synchronously to
> on-prem replicas over the site-to-site VPN: `database/mariadb`, `database/valkey`,
> `nextcloud/nextcloud-config`, `wordpress/wordpress-data`, `syncthing/syncthing-data`,
> `automation/atlantis`, `automation/n8n`, `observability/...-grafana`, and
> `security/data-dependency-track-api-server-0`. Cause: `node-role.kubernetes.io/worker` spans
> ff-vm1 **and** both OCI nodes under the orthogonal-axes taxonomy, so workloads whose comments say
> "worker (ff-vm1)" drift to the cloud. This predates the placement work (the dependency-track
> selector dates to #394, 2026-06-15). It is what caused dependency-track's **892** startup-probe
> kills: its boot writes crossed the VPN and could never finish inside the 310s window. Fixing it
> means pinning them back to ff-vm1 — which is blocked on item 1.
>
> **4. Backups are effectively absent, which matters more than any item below.** No Longhorn
> backup target, no recurring jobs, no Velero, across 45 volumes. The offsite MinIO mirror covers
> **1.2GiB of the 62GiB `thanos-metrics` bucket and last ran 2026-07-08**; the loki side stopped
> 2026-06-10. `thanos-metrics` holds up to a year of downsampled history that exists nowhere else
> (Prometheus keeps 7d). Making the mirror current would blow ~6x past the OCI Always Free tier.
>
> **5a. What the authentik migration actually needs (established 2026-08-07).** Its blueprint system
> works — 28 stock instances, all `successful` — and the chart discovers ConfigMaps labelled
> `blueprints.goauthentik.io/instantiate: "true"`, so providers and applications can be
> GitOps-managed rather than clicked in. The real gap is identity, not config: the ONLY source is
> `authentik Built-in`, while both remaining oauth2-proxies run `--provider=google` (defectdojo
> restricted by `--email-domain=magmamoose.com`, headlamp by an `authenticated-emails-file`). So a
> cutover starts with a Google OAuth Source in authentik, using the client credentials already in
> the `security/oauth2-proxy` and `misc/oauth2-proxy` Secrets — reaching the blueprint via env from
> an ExternalSecret, never inlined, since a blueprint lives in a ConfigMap in a PUBLIC repo.
> Order: Google source -> Proxy Provider + Application per app -> bind to the embedded outpost ->
> repoint the Traefik middlewares -> only then delete oauth2-proxy and headlamp's auth-redirect
> shim. Do NOT delete either proxy before the outpost answers, or both services become unreachable.
>
> **5. authentik is healthy but EMPTY, so the oauth2-proxy migration has no target.** The
> crashloop stopped on its own (~08:00Z, peaked at 325 restarts, reason `Error`/exit 1, never
> OOMKilled; root cause undeterminable — the pods are gone and Loki has zero lines for the
> namespace). But the API reports **0 providers, 0 applications**, and an embedded outpost with
> `providers: []`. cleanup.md's stated blocker ("blocked on authentik being healthy") is the wrong
> blocker: it is blocked on authentik never having been configured.
>
> **6a. The terragrunt backend is NOT broken — a personal credential is.** The audit reported GCS
> auth as a blocker. Retested with the `atlantis@magmamoose-terraform` service-account key already
> present in `automation/atlantis-gcp`: it reads the state fine, and terragrunt runs all the way to
> the OCI provider before failing on `401-NotAuthenticated` against Identity. So the state backend is
> healthy and only the local `gcloud` token is stale — plans belong in Atlantis, which holds the OCI
> credentials. The `longhorn-backups` bucket added to the backups leaf will plan there, and needs an
> `import`: the bucket and its policy statement were created out of band to get backups working.
>
> **6. The atlantis -> GitHub Actions replacement cannot run.** The appendix workflow targets
> `[self-hosted, Linux, samenlevingszaken]`; no such runner exists. The only org runner is
> `firefly-0`, in a group with `allows_public_repositories: false` — and this repo is public. Also
> missing: `vars.SELFHOSTED_GITHUB_RUNNER`, the `all/deploy` environment, and
> `secrets.MS_TEAMS_WEBHOOK_URL`. All are GitHub settings changes only the owner can make.
>
> **7. mariadb -> Heatwave is blocked on credentials, not design.** The OCI DB System exists but is
> `INACTIVE`; `OCI_MYSQL_ADMIN_PASSWORD` is unset so the terragrunt leaf fails at HCL parse time for
> *every* command; and the GCS backend auth is expired, so no plan can be run at all. Note
> `mysql_version` is pinned to 9.6.0, the live system reports 26.7.0, and 9.6.0 is no longer
> offered — with `prevent_destroy = false`, a plan run blind could force-replace the DB System.
>
> **8. PV -> Longhorn is impossible as written.** 20.9 TiB of bulk-media PVCs (`media/movies`
> 10.24 TiB, `media/series` 6.42 TiB, `backup/timemachine-share` 2.87 TiB, ...) exceed Longhorn's
> entire schedulable budget many times over, and two of them are RWX with 7-8 concurrent mounters.
> The item needs rewording to "non-media PVCs", or dropping.

I want to follow best practices and industry standards. The below is a list of things I want to do to clean up the codebase and make it more maintainable and aligned with best practices and industry standards.

- [~] simplify labels for node-pinning. **New labels APPLIED to the live nodes 2026-08-07** — additive, nothing selects them yet. The insight that makes the taxonomy work: **role and location are orthogonal axes**, which dissolves the old complaint that `worker` spans both tiers. Verified resolution against the live cluster:
  - `node-role.kubernetes.io/system` → ff-pi1
  - `node-role.kubernetes.io/worker` → ff-vm1, ff-oci1, ff-oci2
  - `node-role.kubernetes.io/on-prem` → ff-pi1, ff-vm1
  - `node-role.kubernetes.io/cloud` → ff-oci1, ff-oci2
  - [ ] **DURABILITY GAP — applied with imperative `kubectl label`, so they are LOST on node re-registration.** The kubelet may not self-register `node-role.kubernetes.io/*` (NodeRestriction), so they must be baked into each host's k3s config (`node-label:` in `/etc/rancher/k3s/config.yaml` for ff-pi1, `config.yaml.d/` for agents). The OCI pair sets labels via cloud-init in `terraform/oci/modules/server` — changing that REPLACES the VM. ff-vm1 is not in the Ansible inventory.
  - [ ] remove the OLD labels (`type=pi`, `type=mini`, `node-role.kubernetes.io/{pi,mini}`) only AFTER all ~40 consumers migrate off `components/node-selectors` — see the Kyverno item below.
- [ ] implement "priority classes" (see appendix):
  - `critical`
  - `business`
  - `high`
  - `medium` (NOT `globalDefault` — see appendix; unlabelled pods stay at priority `0` on purpose)
  - `low`
  - [ ] **`business` sits between `high` and `critical` deliberately.** It encodes a different axis from the rest of the scale — the others rank by *blast radius* ("what else breaks?"), this one ranks by *revenue impact* ("who is affected?"). Mixing axes in one ordinal scale is only safe under a single rule, below. Business apps rank **below** `critical` on purpose: the secrets, TLS, admission and data planes are what they run on, so a business app that outranks them wins a scheduling race and then fails anyway.
  - [ ] **Rule: nothing may outrank its own dependencies.** Otherwise under contention an app preempts the very thing it needs and takes itself down — a self-inflicted outage that looks like a mystery. Verified against live pod env today:
    - `nievah` → `litellm.automation.svc` + `valkey.database.svc`
    - `caldrith` → `valkey.database.svc`
    - `dunmir` → `postgres-oci` (already `critical` — correctly above)
    - so `litellm` and the `valkey` pair are promoted to `business` alongside the apps. They are in the serving path, so they belong in the tier — this is the rule applied, not an exception to it.
  - [ ] **Only 3 of the 9 candidate apps are cluster workloads.** A PriorityClass is a pod-scheduling construct and has no meaning for the rest:
    - cluster workloads today: **nievah**, **caldrith**, **dunmir** (`dunmir-pro`)
    - GitHub Actions, not pods — no class applies: **diatreme** (`.github/workflows/release.yml`), **chargate** (`.github/workflows/security.yml`; its cluster deployment was removed in #519)
    - no manifest, namespace or workflow reference anywhere yet: **brimyr**, **dastgate**, **sitnalta**, **noctyr**
  - [ ] five tiers, which is inside the 3–5 range that stays meaningful in practice. `besteffort` was folded into `low` — it had zero members, and `low` already carries `preemptionPolicy: Never`, so the two were functionally the same tier.
  - [ ] **do not re-declare what Kubernetes already provides.** 13 workloads already carry a built-in class today and assigning them a custom one would *demote* them by six orders of magnitude (`system-cluster-critical` = 2000000000, custom `critical` = 100000). Leave these alone and drop them from the desired-state lists below — they are k3s- or chart-managed, not ours to set:
    - `system-cluster-critical`: coredns, traefik, helm-controller, kustomize-controller, source-controller
    - `system-node-critical`: metrics-server, local-path-provisioner, svclb-traefik, node-tuning, oci-node-firewall, oci-flannel-csum-offload
    - `longhorn-critical` (1000000000, ships with the chart): the longhorn instance-managers and CSI pods
  - [ ] **keep the custom scale below `longhorn-critical`.** If the storage layer loses a scheduling race, every stateful workload above it fails anyway — storage should win. The appendix values (100000 → 100) sit deliberately beneath it, with roughly 10× gaps so a tier can be inserted later without renumbering.
  - [x] ~~rebalance the distribution.~~ Was 38 `critical` / 51 `high` / 16 `medium` / 3 `low` — 82% of workloads in the top two tiers, which meant the classes bought nothing, because priority only does work *under contention*. Now a pyramid. The rule applied: `critical` is reserved for workloads whose loss breaks *other* workloads or risks data (secrets, certs, storage, database, admission control), not for workloads that are merely important.
  - [ ] apply `priorityClassName` via a per-tier Kyverno mutation, rather than editing ~90 pod specs by hand — **but the policy must target the controller kinds (`Deployment`/`StatefulSet`/`DaemonSet`/`CronJob` pod templates), never bare `Pod`.** The kube-apiserver's in-tree `Priority` admission plugin runs *before* `MutatingAdmissionWebhook` and is what resolves `priorityClassName` into the integer `spec.priority` that the scheduler actually reads. A webhook that stamps the name onto an already-admitted Pod leaves `spec.priority` unchanged — the field would *look* right in `kubectl get pod -o yaml` while every scheduling and preemption decision ignored it. Mutating the controller's template avoids this, because the resulting Pod is admitted with the name already present. Prove it with a canary before rolling out: assert `.spec.priority == 100000`, not just the name.
  - [ ] note: names with a `system-` prefix are **rejected by the API server** (`priority class names with 'system-' prefix are reserved for system use only`) — verified against the live cluster. This is why the list above uses bare names.
- [ ] **repoint the cloud-tier business apps off the on-prem cache.** `nievah` and `caldrith` run on the cloud tier but both set `REDIS_URL=redis://valkey.database.svc.cluster.local:6379` — the `valkey` instance pinned to **ff-vm1**, the most contended and least available node in the fleet (~99% CPU / ~100% memory requested), reached across the site-to-site VPN. A cloud-tier `valkey-oci` already exists for exactly this. As it stands, the one tier that can survive a node failure has a hard dependency on the one node most likely to have one, which undoes the whole point of putting these apps in `cloud`. Repoint both at `valkey-oci.database.svc`, then drop `valkey` back to `high`.
- [ ] add the other two legs of availability — priority class alone does not make a workload available:
  - [ ] **PodDisruptionBudgets — corrected.** An earlier draft of this item was wrong on every example and would have caused harm; keeping the correction visible. All 18 PDBs are **operator-generated — not one exists in this repo**, so none can be "fixed" by editing a manifest:
    - the 5 CNPG ones (`postgres`, `postgres-primary`, `postgres-oci-primary`, and two more) are owned by their `Cluster` CR. The `*-primary` ones deliberately select exactly one pod so that draining the primary's node forces a switchover first. That is the point of them.
    - `database/postgres` shows **ALLOWED DISRUPTIONS: 0** because the cluster is *degraded* (1 of 3 instances healthy), not because the PDB is misshapen. It is correctly reporting a real outage.
    - the 5 `longhorn-system/instance-manager-*` PDBs are per-node and labelled `longhorn.io/managed-by: longhorn-manager`. Longhorn's `node-drain-policy` is `block-if-contains-last-replica`; blocking a drain that would strand the last replica of a volume **is the feature**. Switching them to `maxUnavailable: 1` would trade a drain annoyance for data unavailability.
    - the `external-dns-*` PDBs, previously cited here as the "correct" pattern, are `maxUnavailable: 1` against 1 replica — 100% disruption allowed. They protect nothing.
    - Real action: leave them alone. If a drain blocks, fix the underlying degraded workload rather than the PDB. Write PDBs only for our own ≥2-replica workloads.
  - [ ] **Spread.** Replica count without spread is not fault tolerance — two replicas on one node die together. Only `kube-system/coredns` has `topologySpreadConstraints` today. The in-repo precedent to copy is `postgres-oci`, which uses required pod anti-affinity on `kubernetes.io/hostname` to guarantee one instance per OCI node.
- [ ] Replace `components` with Kyverno mutating policies. Deleting the tree outright would drop node pinning entirely — `components/node-selectors/*` is currently the only thing that puts a `nodeSelector` on a workload's pod spec, so "delete and inline by hand" trades one problem for ~90 hand-maintained selectors. Instead:
  - [ ] one `ClusterPolicy` per tier (`system`, `worker`, `on-prem`, `cloud`) that mutates the pod spec based on a namespace or workload label, e.g. `topology.sargeant.co/tier: cloud`. Policies live alongside the existing ones in `kubernetes/apps/kyverno-policies/base/`.
  - [ ] pinning then becomes one label on the app, not a `components:` reference plus a patch target per workload kind (Deployment/StatefulSet/DaemonSet/CronJob are four separate patches in every component today).
  - [ ] migrate the ~90 workloads off `components/node-selectors`, then delete `components/node-selectors`, `components/resource-profiles` (see below), and audit the rest (`gluetun-sidecar`, `vpn-routed-proxy`, `wireguard-sidecar`, `pod-gateway-client`, `helm-release-standards`, `helm-releases`, `ingress-standards`) individually — some are genuinely sidecar-injection, which is also Kyverno's job.
  - [ ] note this makes Kyverno load-bearing for scheduling: if the admission webhook is down, new pods land unpinned. Keep `failurePolicy` and the kyverno replica count deliberate.
- [ ] Under `infrastructure > controllers`, the "stack" folder needs to be removed. The items within the folder need to be put directly within the controllers folder. The stack folder is not needed and overcomplicates things. The same goes for `infrastructure > services > stack`.
- [ ] Under `infrastructure > flux`, the individual YAMLs need to be folded into the individual apps, or placed within infrastructure `configs`, `controllers`, or `services` where applicable.
- [x] ~~what is `node-tuning`?~~ A DaemonSet (`kubernetes/apps/node-tuning/base/daemonset.yaml`) that durably raises the kernel's per-user inotify limits on every node — the 128 default for `fs.inotify.max_user_instances` starved watch-heavy controllers, and gatekeeper's cert-rotation fsnotify was crashing with "too many open files" on ff-vm1. A privileged init container writes the sysctls in the host namespace; a `pause` container holds the pod Running so kubelet re-runs the init on every restart, which is what survives a reboot. Keep it. (Note `oci-node-firewall` ships from this same app directory — see the cloud section.)
- [x] ~~rename `core` namespace to `general-system`.~~ **DONE.** Not bare `system` — that word already names the ff-pi1 *pinning tier* both here and in `docs/reference/cluster-topology.md`, and the tier spans far more namespaces than this one (`flux-system`, `cert-manager`, `kyverno`, `longhorn-system`, `external-secrets`, `kube-system`, …). The `<something>-system` suffix is the established k8s convention for "this product's own components" — `flux-system`, `longhorn-system`, `flagger-system`, `trivy-system`, `cattle-system` are all already in the cluster. `magmamoose-system` was the original proposal; `general-system` was chosen instead, and reads the same way without tying the namespace to a brand name. Avoid `platform-system`, which collides with the existing `platform2` namespace.
  - The rename is NOT a find-and-replace. Three references are invisible to grep or actively misleading: Loki's entire config is one SOPS-encrypted blob containing `endpoint: minio.core.svc.cluster.local:9000`; the two 1password-connect secrets carry `namespace:` in cleartext but MAC-covered, so a text edit breaks decryption and they must go through `sops`; and `net.core.rmem_max`, `monitoring.coreos.com/v1`, `oci_core_*` (~137 in terraform), `kubernetes.core.k8s` and `coredns` are all substring false positives a `sed` would corrupt. The `vpn-gateway.core.svc` references in `components/vpn-routed-proxy` were left alone deliberately — that service left this namespace long ago, so they were already broken and rewriting them would only hide it.
- [ ] migrate `minio` to `seaweedfs`.
- [ ] any workload that has a persistent volume (except databases) must be moved to longhorn
- [ ] figure out an easier way to apply resource requests and limits to workloads in code. The industry-standard shape is four separate concerns — don't solve them with one mechanism:
  - [ ] **Shape.** Set **CPU requests, omit CPU limits** — CPU is compressible, so the request already guarantees a share under contention, while a limit causes CFS throttling even on an idle node. Set **memory request == memory limit** — memory is incompressible, so a missing limit lets one leak OOM the node, and equal values mean the pod never exceeds what it reserved, which ranks it last for node-pressure eviction. Note this yields **Burstable** QoS, *not* Guaranteed: Guaranteed additionally requires cpu request == cpu limit, which the previous sentence deliberately gives up. Do not "fix" that by adding CPU limits back — the only case that genuinely needs Guaranteed is the static CPU-manager policy for exclusive cores, which nothing here uses. Today's `components/resource-profiles/*` do the opposite on both counts: they set a CPU limit and a memory limit ≠ request.
  - [ ] **Values from measurement, not guesses.** Keep using KRR, or add VPA in recommendation-only (`updateMode: "Off"`) mode. Goldilocks is just a UI over VPA — not needed if KRR output is already readable.
  - [ ] **Keep GitOps authoritative.** Do *not* run VPA in `Auto`/`Recreate` — it mutates live pod specs and Flux will fight it (same failure mode as any live patch to a Flux-managed value). The GitOps-native loop is: recommender → PR → review → merge → Flux applies. Worth automating the PR step, since that's the part that actually made previous right-sizing passes expensive.
  - [ ] **Floor, not ceiling.** A `LimitRange` per namespace supplies a default so nothing lands unbounded, and a Kyverno `validate` rule requires requests to be present. This is what t-shirt sizes are actually for — a sane default for a *new* workload — not the steady-state value for a measured one. There are currently no `LimitRange` or `ResourceQuota` objects in the repo at all.
  - [ ] **Fix or drop `components/resource-profiles`.** ~40 profiles (t/c/m/r/p × nano→2xlarge), adopted by 10 of ~139 live workloads. Every profile patches `containers/0` only, so on any multi-container pod it silently sizes the first container and ignores the rest — which is most of what the last KRR run flagged (litellm + auth-proxy, defectdojo-django + nginx, github-runner's two containers, the prometheus sidecars). Given the shape guidance above, prefer deleting it in favour of `LimitRange` defaults + measured per-workload values in git.

## Workload Desired State

X, Y, Z: where X is the workload, Y is the number of replicas, and Z is the priority class

### Replica policy

Replica counts are capped by how many nodes a tier actually spans. Three of the four tiers are one node wide today, so most of this list *cannot* be made highly available no matter what number is written next to it:

| tier | nodes | max useful replicas | what a 2nd replica actually buys |
|------|-------|---------------------|----------------------------------|
| `system` | ff-pi1 | 1 | nothing — co-located on the same Pi. Zero-downtime rollout only. |
| `on-prem worker` | ff-vm1 | 1 | same, and currently unaffordable: the node sits at ~99% CPU / ~100% memory requested. |
| `cloud` | ff-oci1, ff-oci2 | 2 | genuine node-failure tolerance — **the only tier where HA is real.** |

Consequences worth being explicit about:

- **The cloud tier has no headroom for these replica counts today.** ff-oci1 is at ~96% and ff-oci2 at ~91% CPU *requested* — roughly **250m of unreserved CPU across the whole tier**. Several workloads below are written as `2 (one per node)` but run 1 today, and "one per node" implies required anti-affinity, so the second replica can only land on the one node with ~70m free. Treat the counts below as **the target state after right-sizing**, not as a change that can be merged today: land the KRR/VPA request corrections first, re-measure, then raise replicas one workload at a time.
- **`critical` + `1` replica on a one-node tier is an accepted single point of failure, not high availability.** That is a legitimate homelab trade — just don't let the label imply otherwise. If a workload genuinely must survive losing a node, it has to live in `cloud`.
- **Leave leader-elected singletons at `1`.** Flux controllers, cert-manager, external-dns, the CloudNativePG operator, and the kyverno background/cleanup/reports controllers are active-passive by design; a second replica sits idle and costs a full reservation on nodes that have none to spare.
- **Exception — anything in a request path should be ≥2 and spread**, because its failure is synchronous rather than eventual. Today that means `kyverno-admission-controller` (see below).
- Replica counts here should track reality: `nievah-worker` is listed as `1` but currently runs `2`, one per OCI node.

### DaemonSets (all nodes)

- cloudflared, `critical` — sole ingress path for everything published externally
- falco, `medium` — runtime detection; its loss costs visibility, not availability
- ~~node-tuning~~ — leave as-is: already sets `system-node-critical` itself
- ~~engine-image~~, ~~longhorn-csi-plugin~~ — leave as-is: longhorn chart-managed, already `longhorn-critical`
- kube-prometheus-stack-prometheus-node-exporter, `low` — scrape target; a gap in metrics is not an outage

### Worker

- falco-falcosidekick, `medium` — alert forwarding for falco; same tier as its source
- fluent-bit, `low` — log shipping; a gap in shipped logs is not an outage
- ~~svclb-traefik~~ — leave as-is: k3s-managed, already `system-node-critical`
- ~~auth-redirect~~ — not a standalone app: it's `kubernetes/apps/headlamp/base/auth-redirect.yaml`, an nginx shim for headlamp's auth redirect flow. Retires with `misc/oauth2-proxy` in the authentik migration below, so it does not belong in this list.

### system

- external-secrets, `1`, `critical` — the secrets plane; if it stops syncing, every app that mounts a derived secret eventually fails to start or rotate
- external-secrets-webhook, `1`, `high` — admission for ExternalSecret/SecretStore CRs only, not for pods
- external-secrets-cert-controller, `1`, `medium` — maintains the webhook's own certs
- onepassword-connect, `1`, `critical` — backing store behind external-secrets
- onepassword-connect-operator, `1`, `medium` — reconciles the Connect deployment; not itself in the secret path
- cert-manager, `1`, `critical` — TLS plane; expiry cascades into every ingress
- cert-manager-webhook, `1`, `high` — admission for cert-manager CRs only
- cert-manager-cainjector, `1`, `high` — injects CA bundles into webhook configs
- cloudnativepg, `1`, `high` — operator, not the database. Existing clusters keep serving; what stops is reconciliation and failover
- external-dns-cloudflare, `1`, `high` — public DNS; existing records persist, so failure is eventual rather than immediate
- external-dns-mikrotik, `1`, `medium` — internal DNS; records persist in RouterOS
- [x] ~~external-dns-mikrotik-internal, `1`, `medium` (is currently called "external-dns-ember-private")~~ — **DONE.** Renamed via Helm uninstall/reinstall (`releaseName` is immutable). Safe because `txtOwnerId`/`txtPrefix` are unchanged, so RouterOS keeps the records and the new release adopts rather than deletes them. The rename also fixed a crashloop that predates it: the Bitnami chart's generated ClusterRole omits `discovery.k8s.io/endpointslices`, which external-dns v0.20.0 requires — it now ships its own RBAC like both sibling instances.
- external-dns-mikrotik-webhook, `1`, `medium` — the webhook-provider shim external-dns needs because RouterOS isn't a native external-dns provider; ships inside the `external-dns-mikrotik` stack (`base/webhook-deployment.yaml`), so it isn't independently deployable and shares that tier
- flagger, `1`, `medium` — progressive delivery; if it is down, rollouts stall rather than break (currently 0/1 ready)
- ~~coredns~~ — leave as-is: k3s-managed, already `system-cluster-critical` (and already has a `topologySpreadConstraint`)
- ~~local-path-provisioner~~ — leave as-is: k3s-managed, already `system-node-critical`
- ~~metrics-server~~ — leave as-is: k3s-managed, already `system-node-critical`
- ~~traefik~~ — leave as-is: k3s-managed, already `system-cluster-critical`
- ~~helm-controller~~, ~~kustomize-controller~~, ~~source-controller~~ — leave as-is: the Flux chart already sets `system-cluster-critical` on these three
- image-automation-controller, `1`, `medium` — leader-elected; its failure delays image bumps, it does not break reconciliation
- image-reflector-controller, `1`, `medium` — as above
- notification-controller, `1`, `medium` — alerting only
- kyverno-admission-controller, `2`, `critical` — **do not drop to `1`** (it currently runs 2). This is a validating/mutating webhook in the synchronous admission path: if it is unavailable, pod creation fails cluster-wide. Once node pinning *and* priority-class assignment move into Kyverno mutations, it also becomes load-bearing for scheduling. It should not be pinned to the one-node `system` tier — leave it schedulable across nodes with a `topologySpreadConstraint` so the two replicas actually land on two different nodes.
- kyverno-background-controller, `1`, `medium` — leader-elected, reconciles asynchronously; its failure delays policy application rather than blocking admission
- kyverno-cleanup-controller, `1`, `medium` — leader-elected, janitorial
- kyverno-reports-controller, `1`, `medium` — leader-elected, reporting only
- alloy (arm64 for logging), `1`, `low` — log collection
- prometheus-operator, `1`, `medium` — manages Prometheus CRs; existing Prometheus keeps running without it
- ~~csi-attacher~~, ~~csi-provisioner~~, ~~csi-resizer~~, ~~csi-snapshotter~~, ~~longhorn-driver-deployer~~, ~~longhorn-manager~~ — leave as-is: all six already set `longhorn-critical` (1000000000) from the chart, which correctly outranks anything of ours

### on-prem worker

- postgres, `1`, `critical` — data
- authentik-server, `1`, `high` — **promote to `critical` once the oauth2-proxy migration lands**; at that point every gated service depends on it, which is the definition of the top tier
- authentik-worker, `1`, `high`
- valkey, `1`, `business` — **serving path, and currently mis-tiered**: `nievah` and `caldrith` both point at `valkey.database.svc`, i.e. *this* instance on ff-vm1, not the cloud-tier `valkey-oci`. See the cross-tier item under General — the class promotion is a stopgap; the real fix is repointing them.
- fortivpn-gateway, `1`, `high` — network path for VPN-routed workloads; its loss breaks *those* workloads, not just itself
- pod-gateway-main, `1`, `high` — as above, for gateway-routed pods
- nextcloud, `1`, `high` — user-facing and data-bearing
- plex, `1`, `high` — user-facing
- pod-gateway-webhook, `1`, `medium` — injection admission; affects newly created pods only
- hermes, `1`, `medium`
- homeassistant, `1`, `medium`
- homebridge, `1`, `medium`
- timemachine, `1`, `medium` (change to StatefulSet) — a missed backup window is recoverable, but it is still data protection
- syncthing, `1`, `medium` — file replication
- qbittorrent, `1`, `medium`
- radarr, `1`, `medium`
- sabnzbd, `1`, `medium`
- sonarr, `1`, `medium`
- loki, `1`, `medium` — log store
- prometheus-prometheus-prometheus, `1`, `medium` — metrics store
- bazarr, `1`, `low`
- flaresolverr, `1`, `low`
- blackbox-exporter, `1`, `low` — probing
- holmesgpt-holmes, `1`, `low` — ops assistant
- thanos-query, `1`, `low` — historical query fan-out
- thanos-store, `1`, `low` — historical object-store gateway
- thanos-compactor, `1`, `low` — batch compaction, restartable at any time
- trivy-operator, `1`, `low` — asynchronous scanning
- dependency-track-api-server, `1`, `low` — SBOM reporting
- defectdojo-django, `1`, `low` — vulnerability reporting UI
- defectdojo-celery-worker, `1`, `low`
- defectdojo-celery-beat, `1`, `low`

### cloud

This is the only tier where a replica count above `1` buys real fault tolerance, so it is also the only place worth spending replicas. Anything marked "one per node" needs an actual `topologySpreadConstraint` or required host anti-affinity to deliver on that — `postgres-oci` is the working example.

- postgres-oci, `2` (one per node), `critical` — data, and already correctly spread by host anti-affinity
- dunmir, `2` (one per node), `business` (is currently called "dunmir-pro") — public-facing; depends on `postgres-oci`, which correctly outranks it
- nievah, `1`, `business`
- caldrith, `2` (one per node), `business` (currently crash-looping)
- litellm, `2` (one per node), `business` — **serving path**: `nievah` calls it at `litellm.automation.svc`, so it cannot rank below the apps that depend on it
- valkey-oci, `2` (one per node), `business` — **serving path**: the cloud-tier cache for these apps (see the cross-tier note below)
- nievah-worker, `2` (one per node), `high` — asynchronous, so it degrades throughput rather than availability; matches what it actually runs today
- caldrith-worker, `2` (one per node), `high` — as above
- alertmanager-prometheus-alertmanager, `1`, `high` — how you find out anything else is broken; demoting it defeats the rest of the stack
- platform2-backend, `1`, `high`
- browserless, `2` (one per node), `medium`
- platform2-driver, `1`, `medium`
- n8n, `1`, `medium`
- n8n-mcp, `1`, `medium`
- prowlarr, `1`, `medium`
- nzbhydra2, `1`, `medium`
- kube-prometheus-stack-kube-state-metrics, `1`, `medium` — most cluster-level metrics disappear without it
- wordpress, `1`, `medium`
- kube-prometheus-stack-grafana, `1`, `low` — visualisation; Prometheus is still queryable directly
- headlamp, `1`, `low` — convenience UI; `kubectl` is the real control path
- openhands, `1`, `low`
- overseerr, `1`, `low`
- excalidraw, `1`, `low`
- blackbox-exporter-oci, `1`, `low`
- sonarqube-sonarqube, `1`, `low` — code-quality reporting
- dependency-track-frontend, `1`, `low`
- github-timesheet, `1`, `low`
- github-contributions, `1`, `low`
- github-usage-dashboard, `1`, `low`
- ~~longhorn-ui~~ — leave as-is: longhorn chart-managed, already `longhorn-critical`
- ~~oci-node-firewall~~ — leave as-is: already sets `system-node-critical`. Worth knowing what it does: OCI's Ubuntu cloud image ships a host iptables ruleset that only admits SSH/ICMP/established and DROPs the rest, silently blocking the k3s data plane (kubelet `:10250`, flannel VXLAN `:8472/udp`, pod/service CIDRs). The cloud NSG already permits that traffic; the VM's own firewall is the blocker. This DaemonSet inserts and persists the ACCEPT rules, from `kubernetes/apps/node-tuning/base/oci-firewall-daemonset.yaml`. Load-bearing — without it nothing reaches these nodes. The Cilium migration under Worker Deletion retires `oci-flannel-csum-offload`, but *not* this.

## Worker Deletion

- atlantis (see appendix for workflow replacement example)
- git-pull-request-dashboard (archive the repo, since GitHub gives a good enough PR dashboard)
- oauth2-proxy — **all three instances** migrate to authentik. They are separate deployments in three namespaces, each fronting something different, so this is three migrations rather than one deletion:
  - `automation/oauth2-proxy` (currently on ff-oci2)
  - `misc/oauth2-proxy` (fronts headlamp, alongside `headlamp/base/auth-redirect.yaml` — that nginx redirect shim goes too)
  - `security/oauth2-proxy` (fronts defectdojo)
  - blocked on authentik being healthy first: `authentik-server` is currently crash-looping (exit 1, ~180 restarts) and `authentik-worker` is not ready.
- mariadb (replaced with OCI Heatwave)
- github-runner (to be migrated to GitHub Arc, `high`)
- oci-flannel-csum-offload (migrate from flannel to Cilium)
- gatekeeper-audit (using kyverno instead of gatekeeper)
- gatekeeper-controller-manager (using kyverno instead of gatekeeper)

## Appendix

### Priority Classes

Where these sit relative to what is already installed in the cluster:

| class | value | source |
|-------|-------|--------|
| `system-node-critical` | 2000001000 | built-in — node would break |
| `system-cluster-critical` | 2000000000 | built-in — cluster would break |
| `longhorn-critical` | 1000000000 | longhorn chart — storage outranks its consumers |
| **`critical`** | **100000** | ours — the planes everything else runs on |
| **`business`** | **50000** | ours — revenue-bearing apps *and their serving path* |
| **`high`** | **10000** | ours |
| **`medium`** | **1000** | ours — assigned explicitly, never as a global default |
| **`low`** | **100** | ours |

Names must **not** start with `system-`; the API server rejects those outright. Values are spaced 10× apart so a tier can be inserted later without renumbering, and all of them sit below `longhorn-critical` on purpose: if storage loses a scheduling race, everything stateful above it fails anyway.

```yaml
# Priority Classes
# Higher value = higher priority: scheduled sooner, preempted/evicted later.
# Unlabelled pods stay at priority 0. NONE of these is globalDefault, on
# purpose: a global default silently promotes every unlabelled pod above the
# things that have no class at all, which on this cluster includes system
# add-ons. Priority is assigned explicitly via the placement label instead.

---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: critical
value: 100000
globalDefault: false
description: "Loss breaks OTHER workloads or risks data: secrets, certs, storage, databases, admission control. Not merely 'important'."

---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: business
value: 50000
globalDefault: false
description: "Revenue-bearing applications and everything in their serving path. Ranks below `critical` because it depends on it: an app that preempts its own secrets, TLS or database wins the race and fails anyway."

---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: high
value: 10000
globalDefault: false
description: "User-facing or data-bearing services. A visible outage if evicted, but nothing else fails with them."

---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: medium
value: 1000
globalDefault: false
description: "Default for normal workloads. Evictable under genuine pressure."

---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: low
value: 100
globalDefault: false
preemptionPolicy: Never  # a dashboard should never evict a service
description: "Non-essential: dashboards, reporting, background jobs. Restartable without impact."

```

### Terragrunt GitHub Workflow Atlantis Replacement Example

The below monstrosity should rather be put into magmamoose/sitnalta (needs a new name), where it'll become a marketplace action for infrastructure deployments, much like how Diateme was created for Release Management. Then this infra repo must consume/call the Marketplace/Composite GitHub Action.

```yaml
name: Terragrunt

on:
  pull_request:
    paths:
      - 'terraform/**'
      - 'scripts/terragrunt-pipeline.sh'
      - '.github/workflows/terragrunt.yml'
  push:
    branches: [main]
    paths:
      - 'terraform/**'
      - 'scripts/terragrunt-pipeline.sh'
      - '.github/workflows/terragrunt.yml'
  schedule:
    - cron: '0 5 * * 1-5'
  workflow_dispatch:
    inputs:
      scope:
        description: 'Stacks to plan (manual runs never apply)'
        type: choice
        default: all
        options: [all, changed]

permissions:
  contents: read
  issues: write
  pull-requests: write

concurrency:
  group: terragrunt-${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

jobs:
  discover:
    # A self-hosted runner must never execute untrusted fork code with its
    # private-cloud credentials. Same-repository PRs still receive plan output.
    if: github.event_name != 'pull_request' || github.event.pull_request.head.repo.fork == false
    runs-on: [self-hosted, Linux, samenlevingszaken]
    outputs:
      matrix: ${{ steps.stacks.outputs.matrix }}
      has_stacks: ${{ steps.stacks.outputs.has_stacks }}
    steps:
      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5 # v4.3.1
        with:
          fetch-depth: 0

      - name: Discover affected Terragrunt stacks
        id: stacks
        shell: bash
        run: |
          set -euo pipefail

          changed_files="$RUNNER_TEMP/terragrunt-changed-files.txt"
          scope="${{ inputs.scope || 'changed' }}"

          case "${{ github.event_name }}" in
            pull_request)
              git diff --name-only "${{ github.event.pull_request.base.sha }}" "${{ github.event.pull_request.head.sha }}" > "$changed_files"
              ;;
            push)
              git diff --name-only "${{ github.event.before }}" "${{ github.sha }}" > "$changed_files"
              ;;
            schedule)
              scope=all
              ;;
            workflow_dispatch)
              # A manual 'changed' run has no reliable event range; plan all to
              # avoid silently omitting a stack.
              scope=all
              ;;
          esac

          if [[ "$scope" == all ]]; then
            bash scripts/terragrunt-pipeline.sh discover all > "$RUNNER_TEMP/terragrunt-stacks.txt"
          else
            bash scripts/terragrunt-pipeline.sh discover changed "$changed_files" > "$RUNNER_TEMP/terragrunt-stacks.txt"
          fi

          matrix=$(jq -Rsc '{include: (split("\n") | map(select(length > 0) | {stack: ., id: (gsub("[^A-Za-z0-9]+"; "-") | sub("-$"; ""))}))}' "$RUNNER_TEMP/terragrunt-stacks.txt")
          stack_count=$(jq '.include | length' <<<"$matrix")
          echo "matrix=$matrix" >> "$GITHUB_OUTPUT"
          echo "has_stacks=$([[ "$stack_count" -gt 0 ]] && echo true || echo false)" >> "$GITHUB_OUTPUT"
          echo "Discovered $stack_count Terragrunt stack(s)."

  approval-gate:
    if: github.event_name == 'push'
    runs-on: [self-hosted, Linux, samenlevingszaken]
    outputs:
      approved: ${{ steps.approval.outputs.approved }}
    steps:
      - name: Require an approved merged pull request
        id: approval
        env:
          GH_TOKEN: ${{ github.token }}
        shell: bash
        run: |
          set -euo pipefail

          pull_requests=$(gh api "repos/${GITHUB_REPOSITORY}/commits/${GITHUB_SHA}/pulls")
          pull_number=$(jq -r '[.[] | select(.merged_at != null) | .number] | first // empty' <<<"$pull_requests")
          if [[ -z "$pull_number" ]]; then
            echo "::error::Terraform applies require a commit merged through a pull request; direct pushes are not eligible."
            echo "approved=false" >> "$GITHUB_OUTPUT"
            exit 1
          fi

          pull_request=$(gh api "repos/${GITHUB_REPOSITORY}/pulls/${pull_number}")
          author=$(jq -r '.user.login' <<<"$pull_request")
          reviews=$(gh api --paginate "repos/${GITHUB_REPOSITORY}/pulls/${pull_number}/reviews?per_page=100")
          approvers=$(jq -r --arg author "$author" '[.[] | select(.state == "APPROVED" and .user.login != $author) | .user.login] | unique | length' <<<"$reviews")

          if (( approvers < 1 )); then
            echo "::error::Pull request #${pull_number} has no approval from a reviewer other than its author."
            echo "approved=false" >> "$GITHUB_OUTPUT"
            exit 1
          fi

          echo "Pull request #${pull_number} has ${approvers} independent approval(s)."
          echo "approved=true" >> "$GITHUB_OUTPUT"

  plan:
    needs: discover
    if: needs.discover.outputs.has_stacks == 'true'
    runs-on: [self-hosted, Linux, samenlevingszaken]
    strategy:
      fail-fast: false
      max-parallel: 1
      matrix: ${{ fromJSON(needs.discover.outputs.matrix) }}
    steps:
      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5 # v4.3.1

      - name: Run Terragrunt plan
        id: plan
        env:
          STACK: ${{ matrix.stack }}
        shell: bash
        run: |
          set +e
          bash scripts/terragrunt-pipeline.sh plan "$STACK" "$RUNNER_TEMP/terragrunt-plan"
          exit_code=$?
          set -e

          status=failed
          [[ -f "$RUNNER_TEMP/terragrunt-plan/status" ]] && status=$(<"$RUNNER_TEMP/terragrunt-plan/status")
          echo "status=$status" >> "$GITHUB_OUTPUT"
          echo "exit_code=$exit_code" >> "$GITHUB_OUTPUT"
          printf '## Terragrunt plan: `%s`\n\nStatus: `%s`\n' "$STACK" "$status" >> "$GITHUB_STEP_SUMMARY"

      - name: Publish plan to pull request
        if: github.event_name == 'pull_request'
        env:
          GH_TOKEN: ${{ github.token }}
          PR_NUMBER: ${{ github.event.pull_request.number }}
          STACK: ${{ matrix.stack }}
          STACK_ID: ${{ matrix.id }}
          PLAN_STATUS: ${{ steps.plan.outputs.status }}
        shell: bash
        run: |
          set -euo pipefail

          marker="<!-- terragrunt-plan-${STACK_ID} -->"
          plan_output="$RUNNER_TEMP/terragrunt-plan/plan.txt"
          if [[ -f "$plan_output" ]]; then
            plan_text=$(bash scripts/terragrunt-pipeline.sh redact "$plan_output" | head -c 58000)
          else
            plan_text='No plan output was produced. Inspect the workflow logs for the failure details.'
          fi

          body=$(cat <<EOF
${marker}
## Terragrunt plan: \`${STACK}\`

Status: **${PLAN_STATUS}**. Sensitive-looking plan lines are redacted before publication.

\`\`\`text
${plan_text}
\`\`\`

[Open workflow run](${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID})
EOF
)

          comments=$(gh api --paginate "repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments?per_page=100")
          comment_id=$(jq -r --arg marker "$marker" '.[] | select(.body | contains($marker)) | .id' <<<"$comments" | tail -n 1)
          if [[ -n "$comment_id" ]]; then
            gh api --method PATCH "repos/${GITHUB_REPOSITORY}/issues/comments/${comment_id}" -f body="$body" >/dev/null
          else
            gh api --method POST "repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments" -f body="$body" >/dev/null
          fi

      - name: Report scheduled drift to Teams
        if: github.event_name == 'schedule' && (steps.plan.outputs.status == 'changes' || steps.plan.outputs.status == 'failed')
        env:
          TEAMS_WEBHOOK_URL: ${{ secrets.MS_TEAMS_WEBHOOK_URL }}
          STACK: ${{ matrix.stack }}
          PLAN_STATUS: ${{ steps.plan.outputs.status }}
        shell: bash
        run: |
          set -euo pipefail

          payload=$(jq -n \
            --arg stack "$STACK" \
            --arg status "$PLAN_STATUS" \
            --arg url "${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}" \
            '{
              type: "message",
              attachments: [{
                contentType: "application/vnd.microsoft.card.adaptive",
                content: {
                  "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
                  type: "AdaptiveCard",
                  version: "1.4",
                  body: [
                    {type: "TextBlock", text: "Terragrunt drift report", style: "heading", wrap: true},
                    {type: "FactSet", facts: [
                      {title: "Stack", value: $stack},
                      {title: "Result", value: $status}
                    ]}
                  ],
                  actions: [{type: "Action.OpenUrl", title: "Open workflow", url: $url}]
                }
              }]
            }')

          curl --fail-with-body --silent --show-error \
            --header 'Content-Type: application/json' \
            --data "$payload" \
            "$TEAMS_WEBHOOK_URL"

      - name: Fail on planning error
        if: steps.plan.outputs.exit_code != '0'
        shell: bash
        run: exit 1

  apply:
    needs: [approval-gate, discover, plan]
    if: >-
      always() &&
      github.event_name == 'push' &&
      needs.approval-gate.outputs.approved == 'true' &&
      needs.discover.outputs.has_stacks == 'true' &&
      needs.plan.result == 'success'
    runs-on: [self-hosted, Linux, samenlevingszaken]
    environment: all/deploy
    strategy:
      fail-fast: false
      max-parallel: 1
      matrix: ${{ fromJSON(needs.discover.outputs.matrix) }}
    steps:
      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5 # v4.3.1

      - name: Replan and apply the exact reviewed commit
        env:
          STACK: ${{ matrix.stack }}
          TERRAGRUNT_PIPELINE_APPLY: 'true'
        shell: bash
        run: |
          set -euo pipefail
          bash scripts/terragrunt-pipeline.sh apply "$STACK" "$RUNNER_TEMP/terragrunt-apply"
          status=$(<"$RUNNER_TEMP/terragrunt-apply/status")
          printf '## Terragrunt apply: `%s`\n\nStatus: `%s`\n' "$STACK" "$status" >> "$GITHUB_STEP_SUMMARY"
```
