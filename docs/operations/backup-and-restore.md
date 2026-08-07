# Backup and Restore

Until 2026-08-07 the cluster had **no backups at all** — the Longhorn backup target
was empty, there were no recurring jobs, and no Velero. This page describes what
exists now and how to get data back.

## What is backed up

| layer | mechanism | where | retention |
|---|---|---|---|
| Longhorn volumes (local) | `daily-snapshot` recurring job | on the Longhorn disks | 7 snapshots |
| Longhorn volumes (offsite) | `weekly-backup` recurring job | OCI `longhorn-backups` | 4 backups |
| Postgres (CNPG) | Barman continuous archiving | OCI `postgres-backups` | per cluster spec |
| MinIO buckets | `minio-backup` CronJob (`mc mirror`) | OCI `minio-backups` | additive |

Local snapshots cover **every** volume, including newly created ones — the job is
attached to Longhorn's `default` group. They cost nothing offsite and handle the
common case: an app corrupting its own config, a bad upgrade, an accidental delete.

## Offsite backups are opt-in

Only volumes carrying a label get pushed to OCI:

```bash
kubectl -n longhorn-system label volumes.longhorn.io <volume> \
  recurring-job.longhorn.io/weekly-backup=enabled
```

Find the volume behind a PVC:

```bash
kubectl -n <namespace> get pvc <pvc-name> -o jsonpath='{.spec.volumeName}'
```

This is deliberate. Backing up all 45 volumes would push ~41 GiB offsite, and most
of it regenerates itself — `dependency-track` alone is 9.4 GiB of NVD mirror it
re-downloads, and `atlantis` is 6 GiB of Terraform plan cache. Paying to store that
is how a backup bill becomes a reason to switch backups off.

Backups are incremental after the first full, so adding a volume later is cheap.

## Restoring a volume

1. In the Longhorn UI (`longhorn-ui`), open **Backup**, pick the volume and a
   backup, then **Restore Latest Backup**.
2. Give the restored volume a new name — restoring over a volume that is still
   attached will fail.
3. Create a PV/PVC pointing at it, then repoint the workload.

From the CLI, the backups themselves are listable:

```bash
kubectl -n longhorn-system get backups.longhorn.io
kubectl -n longhorn-system get backuptarget default \
  -o jsonpath='{.status.available}'   # must be true
```

## Verifying the target actually works

`available: true` only means the manager can reach the bucket. The honest check is
to take a real backup and confirm objects land:

```bash
oci os object list --bucket-name longhorn-backups --all --query 'length(data)'
```

## Gotchas

**OCI IAM grants take minutes to reach the data plane.** After adding a bucket to
the policy, `longhorn-manager` can report `available: true` while instance-manager
pods still fail with `NoSuchBucket`. The first backup fails and an identical retry
succeeds — don't chase it as a config error.

**A new bucket is invisible until Terraform knows about it.** The IAM policy is an
explicit bucket-name allow-list generated from `bucket_names` in
`terraform/oci/prod/eu-amsterdam-1/backups/terragrunt.hcl`. Adding a bucket
anywhere else grants nothing.

**Lifecycle rules need their own grant.** The Object Storage *service principal*
must be allowed to manage objects, or every lifecycle policy fails with
`400-InsufficientServicePermissions`. This was missing until 2026-08-07, which
meant non-current versions were never purged on any bucket — with versioning
enabled, every "deleted" object stayed billable.

## What is NOT covered

- **The 20.9 TiB of bulk media** (`media/movies`, `media/series`,
  `backup/timemachine-share`, …) lives on NFS, not Longhorn, and is far beyond any
  offsite budget here.
- **`thanos-metrics`** (~62 GiB in MinIO) holds up to a year of downsampled history
  that exists nowhere else, since Prometheus keeps only 7 days. The `mc mirror`
  CronJob covers a fraction of it. Treat long-range metrics as best-effort.
