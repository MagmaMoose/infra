# Oracle Cloud Infrastructure (OCI) Terraform Setup

This directory contains Terraform configurations for managing Oracle Cloud Infrastructure (OCI) resources using Terragrunt.

## Prerequisites

1. Install Terraform (version 1.11.3 or later)
2. Install Terragrunt
3. Set up OCI CLI and generate API keys
4. Configure environment variables for OCI authentication

## Environment Variables

The following environment variables need to be set for OCI authentication:

```bash
export OCI_TENANCY_OCID="your-tenancy-ocid"
export OCI_USER_OCID="your-user-ocid"
export OCI_PRIVATE_KEY_PATH="path/to/oci_api_key.pem"
export OCI_FINGERPRINT="your-api-key-fingerprint"
export OCI_REGION="ap-sydney-1"  # or your preferred region
```

## Directory Structure

```text
terraform/oci/
├── provider.hcl                # Provider-specific configuration
├── prod/                       # Production environment
│   ├── environment.hcl         # Environment-specific configuration
│   └── ap-sydney-1/            # Region-specific configuration
│       ├── region.hcl
│       └── compartment/        # Compartment resource
│           └── terragrunt.hcl
```

## Usage

To initialize and apply the Terraform configuration for a specific resource:

```bash
cd terraform/oci/prod/ap-sydney-1/compartment
terragrunt init
terragrunt plan
terragrunt apply
```

## Available Resources

- **Compartment**: Creates an OCI compartment and sets up a budget for it.

## Adding New Resources

To add a new resource:

1. Create a new directory under the appropriate region
2. Create a terragrunt.hcl file in the new directory
3. Create a corresponding module in terraform/oci/modules/ if needed