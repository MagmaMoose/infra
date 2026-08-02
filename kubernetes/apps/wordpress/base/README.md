# WordPress with Elementor Deployment

This directory contains Kubernetes manifests for deploying WordPress with Elementor support in the Firefly cluster.

## Overview

WordPress is configured with:
- **WordPress 6.7** (Apache variant)
- **MariaDB 11.2** database (StatefulSet)
- **Elementor** support for visual page building
- **Static site export** capability

## Database Architecture

This deployment uses a MariaDB StatefulSet for the database because:

1. **WordPress Compatibility**: WordPress is designed for MySQL/MariaDB
2. **Plugin Support**: Elementor and other plugins expect MySQL
3. **Reliability**: MariaDB provides stable database support
4. **StatefulSet Benefits**: Ensures stable network identity and persistent storage

The MariaDB instance runs as a separate StatefulSet with its own service and persistent volume.

## Components

- `deployment.yaml` - WordPress container
- `statefulset.yaml` - MariaDB StatefulSet
- `service.yaml` - ClusterIP service for WordPress
- `mariadb-service.yaml` - Headless service for MariaDB StatefulSet
- `ingress.yaml` - External HTTPS access via Traefik
- `pv.yaml` - Persistent volumes for WordPress files and database
- `pvc.yaml` - Persistent volume claims
- `namespace.yaml` - Dedicated namespace
- `configmap.yaml` - Configuration and usage instructions
- `secret.enc.yaml` - Database credentials (encrypted with SOPS)
- `kustomization.yaml` - Kustomize configuration

## Usage

### Access WordPress

After deployment, access WordPress at: `https://wordpress.sargeant.co`

### Initial Setup

1. Complete WordPress installation wizard
2. Install Elementor plugin from WordPress admin
3. Create pages with Elementor

### Export Static Sites

1. Install "Simply Static" plugin
2. Design your site with Elementor
3. Generate static HTML export
4. Download and host separately

See the ConfigMap README.txt for detailed instructions.

## Customization

To change the domain, edit `ingress.yaml`:
```yaml
spec:
  rules:
    - host: your-domain.com
```

To change resource limits, edit `deployment.yaml` and `statefulset.yaml` resources sections.

## Security

- Database password stored in encrypted secret
- HTTPS enabled via cert-manager
- Use strong passwords during WordPress setup
- Keep WordPress and plugins updated
