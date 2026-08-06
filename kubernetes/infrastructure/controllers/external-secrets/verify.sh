#!/bin/bash
# Verification script for External Secrets Operator setup
# Run this after configuring and deploying ESO to verify everything is working

set -e

echo "=== External Secrets Operator Verification ==="
echo ""

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print status
print_status() {
  if [ $1 -eq 0 ]; then
    echo -e "${GREEN}✓${NC} $2"
  else
    echo -e "${RED}✗${NC} $2"
  fi
}

# Function to print warning
print_warning() {
  echo -e "${YELLOW}⚠${NC} $1"
}

# Function to print section
print_section() {
  echo ""
  echo "=== $1 ==="
}

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
  echo -e "${RED}✗${NC} kubectl not found. Please install kubectl."
  exit 1
fi

# Check namespace
print_section "1. Checking Namespace"
if kubectl get namespace external-secrets &> /dev/null; then
  print_status 0 "Namespace 'external-secrets' exists"
else
  print_status 1 "Namespace 'external-secrets' does not exist"
  exit 1
fi

# Check HelmRelease
print_section "2. Checking HelmRelease"
if kubectl get helmrelease -n external-secrets external-secrets &> /dev/null; then
  print_status 0 "HelmRelease 'external-secrets' exists"

  HELM_STATUS=$(kubectl get helmrelease -n external-secrets external-secrets -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
  if [ "$HELM_STATUS" = "True" ]; then
    print_status 0 "HelmRelease is ready"
  else
    print_status 1 "HelmRelease is not ready"
    print_warning "Run: kubectl describe helmrelease -n external-secrets external-secrets"
  fi
else
  print_status 1 "HelmRelease 'external-secrets' does not exist"
  exit 1
fi

# Check Pods
print_section "3. Checking Pods"
POD_COUNT=$(kubectl get pods -n external-secrets -l app.kubernetes.io/name=external-secrets --no-headers 2>/dev/null | wc -l)
if [ "$POD_COUNT" -gt 0 ]; then
  print_status 0 "Found $POD_COUNT External Secrets pod(s)"

  RUNNING_COUNT=$(kubectl get pods -n external-secrets -l app.kubernetes.io/name=external-secrets --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
  if [ "$RUNNING_COUNT" -gt 0 ]; then
    print_status 0 "$RUNNING_COUNT pod(s) running"
  else
    print_status 1 "No pods are running"
    print_warning "Run: kubectl get pods -n external-secrets"
  fi
else
  print_status 1 "No External Secrets pods found"
  print_warning "Wait a few minutes for pods to be created"
fi

# Check OCI credentials secret
print_section "4. Checking OCI Credentials"
if kubectl get secret -n external-secrets oci-vault-credentials &> /dev/null; then
  print_status 0 "Secret 'oci-vault-credentials' exists"

  # Check if it has required keys
  HAS_PRIVATE_KEY=$(kubectl get secret -n external-secrets oci-vault-credentials -o jsonpath='{.data.privateKey}' 2>/dev/null)
  HAS_FINGERPRINT=$(kubectl get secret -n external-secrets oci-vault-credentials -o jsonpath='{.data.fingerprint}' 2>/dev/null)

  if [ -n "$HAS_PRIVATE_KEY" ]; then
    print_status 0 "Secret has 'privateKey' field"
  else
    print_status 1 "Secret missing 'privateKey' field"
  fi

  if [ -n "$HAS_FINGERPRINT" ]; then
    print_status 0 "Secret has 'fingerprint' field"
  else
    print_status 1 "Secret missing 'fingerprint' field"
  fi
else
  print_status 1 "Secret 'oci-vault-credentials' does not exist"
  print_warning "Make sure you encrypted and deployed oci-vault-secret-enc.yaml"
fi

# Check ClusterSecretStore
print_section "5. Checking ClusterSecretStore"
if kubectl get clustersecretstore oci-vault &> /dev/null; then
  print_status 0 "ClusterSecretStore 'oci-vault' exists"

  CSS_STATUS=$(kubectl get clustersecretstore oci-vault -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  if [ "$CSS_STATUS" = "True" ]; then
    print_status 0 "ClusterSecretStore is ready"
  elif [ -z "$CSS_STATUS" ]; then
    print_warning "ClusterSecretStore status not available yet (may still be initializing)"
  else
    print_status 1 "ClusterSecretStore is not ready"
    print_warning "Run: kubectl describe clustersecretstore oci-vault"

    # Check for common errors
    CSS_MESSAGE=$(kubectl get clustersecretstore oci-vault -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null)
    if [ -n "$CSS_MESSAGE" ]; then
      echo "  Error: $CSS_MESSAGE"
    fi
  fi

  # Check configuration
  VAULT_OCID=$(kubectl get clustersecretstore oci-vault -o jsonpath='{.spec.provider.oracle.vault}' 2>/dev/null)
  TENANCY_OCID=$(kubectl get clustersecretstore oci-vault -o jsonpath='{.spec.provider.oracle.auth.tenancy}' 2>/dev/null)
  USER_OCID=$(kubectl get clustersecretstore oci-vault -o jsonpath='{.spec.provider.oracle.auth.user}' 2>/dev/null)

  if [ -n "$VAULT_OCID" ] && [ "$VAULT_OCID" != '""' ]; then
    print_status 0 "Vault OCID configured"
  else
    print_status 1 "Vault OCID not configured"
    print_warning "Edit secret-store.yaml and add your vault OCID"
  fi

  if [ -n "$TENANCY_OCID" ] && [ "$TENANCY_OCID" != '""' ]; then
    print_status 0 "Tenancy OCID configured"
  else
    print_status 1 "Tenancy OCID not configured"
    print_warning "Edit secret-store.yaml and add your tenancy OCID"
  fi

  if [ -n "$USER_OCID" ] && [ "$USER_OCID" != '""' ]; then
    print_status 0 "User OCID configured"
  else
    print_status 1 "User OCID not configured"
    print_warning "Edit secret-store.yaml and add your user OCID"
  fi
else
  print_status 1 "ClusterSecretStore 'oci-vault' does not exist"
  exit 1
fi

# Check for any ExternalSecrets
print_section "6. Checking ExternalSecrets"
ES_COUNT=$(kubectl get externalsecret -A --no-headers 2>/dev/null | wc -l)
if [ "$ES_COUNT" -gt 0 ]; then
  print_status 0 "Found $ES_COUNT ExternalSecret(s)"

  SYNCED_COUNT=$(kubectl get externalsecret -A -o json 2>/dev/null | jq -r '.items[] | select(.status.conditions[]? | select(.type=="Ready" and .status=="True")) | .metadata.name' 2>/dev/null | wc -l)
  if [ "$SYNCED_COUNT" -gt 0 ]; then
    print_status 0 "$SYNCED_COUNT ExternalSecret(s) synced successfully"
  else
    print_warning "No ExternalSecrets are synced yet"
  fi
else
  print_warning "No ExternalSecrets found (this is normal if you haven't created any yet)"
fi

# Summary
print_section "Summary"
echo ""

if [ "$CSS_STATUS" = "True" ]; then
  echo -e "${GREEN}✓ External Secrets Operator is ready!${NC}"
  echo ""
  echo "Next steps:"
  echo "1. Create a test secret in OCI Vault"
  echo "2. Create an ExternalSecret resource"
  echo "3. Verify the secret is created in Kubernetes"
  echo ""
  echo "See README.md and QUICK_REFERENCE.md for examples."
else
  echo -e "${YELLOW}⚠ Configuration incomplete or not ready yet${NC}"
  echo ""
  echo "Required actions:"
  if [ -z "$VAULT_OCID" ] || [ "$VAULT_OCID" = '""' ]; then
    echo "- Configure vault OCID in secret-store.yaml"
  fi
  if [ -z "$TENANCY_OCID" ] || [ "$TENANCY_OCID" = '""' ]; then
    echo "- Configure tenancy OCID in secret-store.yaml"
  fi
  if [ -z "$USER_OCID" ] || [ "$USER_OCID" = '""' ]; then
    echo "- Configure user OCID in secret-store.yaml"
  fi
  if [ -z "$HAS_PRIVATE_KEY" ]; then
    echo "- Add OCI private key to oci-vault-secret-enc.yaml"
  fi
  if [ -z "$HAS_FINGERPRINT" ]; then
    echo "- Add OCI fingerprint to oci-vault-secret-enc.yaml"
  fi
  echo ""
  echo "See OCI_VAULT_SETUP.md for detailed setup instructions."
fi

echo ""
