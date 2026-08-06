# CloudNativePG PostgreSQL Cluster

This deployment uses CloudNativePG (CNPG) to provide a production-ready, highly available PostgreSQL cluster with an RDS-like experience.

## Features

- **High Availability**: 3-instance cluster with automatic failover
- **Automated Backups**: Daily backups to S3-compatible storage (MinIO)
- **Point-in-Time Recovery**: WAL archiving for PITR
- **Monitoring**: Integrated Prometheus metrics via PodMonitor
- **Resource Management**: Configurable resource profiles via components
- **Node Scheduling**: Deployable to specific node pools

## Configuration

### Secrets

Before deploying, encrypt the secrets in `secret.yaml` using SOPS:

```bash
# Edit the secret values in secret.yaml, then encrypt:
sops -e -i secret.yaml
```

**Required secrets:**
- `postgres-app-user`: Database credentials for the application user
- `postgres-backup-secret`: S3/MinIO credentials for backups

### Cluster Configuration

The cluster is configured in `cluster.yaml`:

- **Instances**: 3 replicas for HA
- **Storage**: 10Gi per instance (adjust as needed)
- **Database**: Creates a database named `app` with user `app`
- **Backups**: Stored in MinIO at `s3://postgres-backups/`

### Backups

Scheduled backups run daily at 3 AM. Configure in `scheduled-backup.yaml`.

## Connecting to the Database

CloudNativePG creates several services:

- **Read-Write**: `postgres-rw.database.svc.cluster.local:5432` (or simply `postgres.database.svc.cluster.local:5432`)
- **Read-Only**: `postgres-ro.database.svc.cluster.local:5432`
- **Read**: `postgres-r.database.svc.cluster.local:5432`

Connection string example:
```
postgresql://app:password@postgres-rw.database.svc.cluster.local:5432/app
```

## Accessing the Database

Get the superuser password:
```bash
kubectl get secret postgres-superuser -n database -o jsonpath='{.data.password}' | base64 -d
```

Port-forward to access locally:
```bash
kubectl port-forward -n database svc/postgres-rw 5432:5432
```

## Monitoring

The cluster exposes Prometheus metrics. If you have Prometheus installed with the `podMonitor` CRD, metrics will be automatically scraped.

## Manual Backup

Trigger a manual backup:
```bash
kubectl cnpg backup postgres -n database
```

## Restore from Backup

To restore from a backup, create a new cluster with a `recovery` section pointing to the backup. See [CNPG documentation](https://cloudnative-pg.io/documentation/current/recovery/) for details.

## Resource Profiles

Available profiles (configured via components):
- `m.small`: Small memory-optimized (512Mi-1Gi RAM, 250m-500m CPU)
- `m.medium`: Medium memory-optimized
- `m.large`: Large memory-optimized

## Node Selectors

Available selectors:
- `pi`: Raspberry Pi nodes
- `gpu`: GPU nodes
- `all`: All nodes

## Troubleshooting

Check cluster status:
```bash
kubectl get cluster -n database
kubectl describe cluster postgres -n database
```

View logs:
```bash
kubectl logs -n database -l cnpg.io/cluster=postgres
```

Check backup status:
```bash
kubectl get backup -n database
```

## References

- [CloudNativePG Documentation](https://cloudnative-pg.io/documentation/)
- [CloudNativePG Architecture](https://cloudnative-pg.io/documentation/current/architecture/)
