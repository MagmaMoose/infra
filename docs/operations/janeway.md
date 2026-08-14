# Janeway

[Janeway](https://janeway.systems) is an open-source publishing platform for
journals, preprints, conference proceedings and books. It runs at
[janeway.magmamoose.com](https://janeway.magmamoose.com).

| | |
|---|---|
| Namespace | `janeway` |
| Chart | `oci://ghcr.io/magmamoose/charts/janeway` ([source](https://github.com/MagmaMoose/charts)) |
| Image | `ghcr.io/tengen-systems/janeway` ([source](https://github.com/tengen-systems/janeway)) |
| Database | `janeway` on `postgres-oci` (namespace `database-oci`), owner `app` |
| Cache | shared Valkey, **database index 6** |
| Storage | `longhorn` RWO, 8Gi, at `src/files`, `src/media`, `src/transform/xsl` |
| Placement | native-cloud tier (`ff-oci1` / `ff-oci2`), priority `high` |
| Exposure | Cloudflare Tunnel → `janeway.janeway.svc.cluster.local:8000` |

## Why it sits where it does

**The image is multi-arch, and that was the enabling decision.** Upstream
Janeway vendors `src/transform/cassius/bin/wkhtmltopdf` as an x86-64 ELF — the
only non-portable binary in its tree — which pins upstream to amd64. `ff-vm1` is
the cluster's only amd64 node and the most contended in the fleet (~96 % of
memory allocatable already requested), so an amd64-only Janeway had nowhere to
go. The image installs the architecture-correct wkhtmltopdf build instead, which
frees the workload to run on the OCI tier where there is headroom.

**The database follows the workload, not the other way round.** Janeway issues
dozens of queries per page render — press resolution, database-backed sessions,
and a row per settings lookup — so database round-trip time dominates page
latency. Measured from a pod on `ff-oci1`:

| Target | RTT |
|---|---|
| `ff-vm1` (the `postgres` cluster in `database`) | 5.604 ms |
| `ff-oci1` (`postgres-oci`) | 0.081 ms |

A 50-query page would spend ~280 ms in network wait on the on-prem cluster
versus ~4 ms on `postgres-oci`. Hence `postgres-oci`, whose owner role is `app`
rather than the `neondb_owner` convention used by the `postgres` cluster.

## Operating it

Scheduled work is Kubernetes CronJobs, one per task — **not** Janeway's own
scheduler. Upstream runs its task queue from Django middleware on every HTTP
request, unlocked; the image removes that middleware and patches the queue to
claim rows with `SELECT … FOR UPDATE SKIP LOCKED`. Do not re-enable it.

```bash
kubectl -n janeway get cronjobs
kubectl -n janeway logs -l app.kubernetes.io/component=cron --tail=100
```

Run any management command:

```bash
kubectl -n janeway exec deploy/janeway -- /usr/local/bin/entrypoint.sh manage <command>
```

### Changing the public hostname

`Press.domain` is written **once**, by the bootstrap job, and Janeway resolves
tenancy on the `Host` header alone. Changing `config.siteDomain` in the
HelmRelease is not sufficient — a request whose `Host` matches no press is
redirected to `DEFAULT_HOST` rather than 404ing, so the symptom is visitors
silently bouncing off the site. Update the row as well:

```bash
kubectl -n database-oci exec -it postgres-oci-1 -- \
  psql -U app -d janeway -c "UPDATE press_press SET domain = 'new.example.com';"
```

Keep the hostname **one label deep** under `magmamoose.com`. The zone's
Universal SSL certificate covers `magmamoose.com` and `*.magmamoose.com` only,
so a two-label name fails in the TLS handshake before any HTTP is exchanged.
Journals are served at a `/<code>/` path prefix precisely so no further
hostnames are needed.

### Cloudflare Access

There is deliberately **no** Access application for this hostname, and one must
not be added. A journal has to be anonymously readable or it cannot be indexed
by Google Scholar, Crossref, DOAJ or any OAI-PMH harvester — which is how a
journal is found at all. If a launcher tile is ever wanted it must be
`type = "bookmark"`; a `self_hosted` app would gate every reader.

### Backups

The database is covered by `postgres-oci`'s cluster-level Barman archiving, but
note the retention window is short and restore granularity is the whole cluster,
not one database. The **files volume is the real exposure**: it holds every
uploaded manuscript and published galley, and Longhorn's `weekly-backup`
recurring job has an empty group list, so it covers nothing until a volume is
explicitly labelled. Treat offsite backup of that PVC as outstanding work.

## Gotchas

**The cache index is load-bearing.** Django's `RedisCache.clear()` issues
`FLUSHDB`, and Janeway calls it whenever an editor saves a setting. Pointed at
index 0 it would wipe DefectDojo's Celery broker. Allocation so far: `0`
DefectDojo, `4` authentik, `6` janeway.

**Valkey is a broker first.** It runs `maxmemory-policy noeviction`, so a full
instance returns write errors rather than evicting. It was raised from 200 MB to
1 GB when Janeway started using it. Janeway's cache entries all carry TTLs, so
its footprint is bounded; a future consumer without TTLs should prompt a move to
`volatile-lru` rather than another size bump.

**`SECRET_KEY` cannot be defaulted.** Upstream hardcodes one in
`janeway_global_settings.py`, published in a public repository. An installation
that failed to override it would boot and accept logins while signing session
cookies and password-reset tokens with a publicly known key. It comes from OCI
Vault (`janeway-secret-key`) and the image refuses to start on the upstream
literal.

**One replica, `Recreate` strategy.** The files volume is ReadWriteOnce, which
is per-node, and Longhorn RWX is not available on this cluster. A second replica
would need node pinning to be safe and would buy nothing against node loss.
