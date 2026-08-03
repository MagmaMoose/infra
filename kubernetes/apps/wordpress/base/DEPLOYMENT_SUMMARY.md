# WordPress Deployment Summary

## What Was Created

A complete WordPress deployment for the Firefly cluster with the following features:

### Core Features
1. **WordPress 6.7** - Latest stable version with Apache
2. **Elementor Support** - Ready to install Elementor page builder
3. **Static Site Export** - Configured for exporting static HTML sites
4. **Multiple Websites** - Can create multiple sites using WordPress Multisite or separate pages

### Components Created

#### Kubernetes Manifests (`kubernetes/_base/miscellaneous/wordpress/`)
- `deployment.yaml` - WordPress container
- `statefulset.yaml` - MariaDB StatefulSet
- `service.yaml` - ClusterIP service for WordPress
- `mariadb-service.yaml` - Headless service for MariaDB
- `ingress.yaml` - HTTPS access via wordpress.sargeant.co
- `pv.yaml` - 10Gi for WordPress files, 5Gi for database
- `pvc.yaml` - Persistent volume claims
- `namespace.yaml` - Dedicated wordpress namespace
- `configmap.yaml` - PHP configuration and usage instructions
- `secret.enc.yaml` - Database credentials (needs SOPS encryption)
- `kustomization.yaml` - Kustomize configuration

#### Documentation
- `README.md` - Main deployment documentation
- `POSTGRESQL.md` - Alternative PostgreSQL setup guide

#### Docker Image (`dockerfiles/wordpress-postgres/`)
- `Dockerfile` - Custom WordPress image with PostgreSQL support (optional)

### Database Decision

**Current Implementation:** MariaDB 11.2 as StatefulSet

**Rationale:**
- WordPress and Elementor are designed for MySQL/MariaDB
- Better plugin compatibility
- More reliable for static site export
- StatefulSet provides stable network identity and persistent storage

**PostgreSQL Alternative:** 
A Dockerfile and documentation are provided for using the existing PostgreSQL StatefulSet if needed.

### Integration

The WordPress deployment has been added to:
```
kubernetes/clusters/firefly/miscellaneous/kustomization.yaml
```

## How to Use

### 1. Update Secret
Before deploying, encrypt the database password:
```bash
# Edit the secret with a strong password
vim kubernetes/_base/miscellaneous/wordpress/secret.enc.yaml

# Encrypt with SOPS (if configured)
sops -e -i kubernetes/_base/miscellaneous/wordpress/secret.enc.yaml
```

### 2. Deploy to Cluster
The deployment will be included when the firefly/miscellaneous kustomization is applied:
```bash
kubectl apply -k kubernetes/clusters/firefly/miscellaneous
```

Or use Flux/GitOps if configured.

### 3. Access WordPress
1. Navigate to https://wordpress.sargeant.co
2. Complete WordPress installation
3. Install Elementor plugin
4. Create pages with Elementor

### 4. Export Static Sites
1. Install "Simply Static" plugin
2. Design your site
3. Export as static HTML
4. Host anywhere (GitHub Pages, Netlify, S3, etc.)

## Storage

### Persistent Volumes
- **WordPress Files:** `/mnt/nvme/wordpress` (10Gi)
- **Database:** `/mnt/nvme/wordpress-db` (5Gi)

Make sure these directories exist on the host or adjust the hostPath in `pv.yaml`.

## Resource Usage

### WordPress Container
- Requests: 250m CPU, 256Mi RAM
- Limits: 1000m CPU, 1Gi RAM

### MariaDB StatefulSet
- Requests: 100m CPU, 128Mi RAM
- Limits: 500m CPU, 512Mi RAM

## Next Steps

1. **Encrypt Secret:** Use SOPS to encrypt the database credentials
2. **Verify Hostpath:** Ensure `/mnt/nvme/wordpress` and `/mnt/nvme/wordpress-db` exist
3. **Deploy:** Apply the kustomization
4. **Configure DNS:** Point wordpress.sargeant.co to your cluster
5. **Complete Setup:** Access WordPress and complete installation
6. **Install Elementor:** From WordPress admin > Plugins > Add New
7. **Create Sites:** Build your websites with Elementor
8. **Export:** Use Simply Static to export static HTML

## PostgreSQL Alternative

If you need to use the existing PostgreSQL StatefulSet instead of MariaDB:

1. Build and push the custom Docker image from `dockerfiles/wordpress-postgres/`
2. Follow instructions in `POSTGRESQL.md`
3. Test thoroughly with Elementor before production use

## Support

- [WordPress Documentation](https://wordpress.org/support/)
- [Elementor Documentation](https://elementor.com/help/)
- [Simply Static Documentation](https://wordpress.org/plugins/simply-static/)

## Security Notes

- Change default database password before deployment
- Use SOPS to encrypt sensitive data
- Keep WordPress and plugins updated
- Use strong admin passwords
- Enable HTTPS (already configured via cert-manager)
