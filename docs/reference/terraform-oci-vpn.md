# OCI VPN Configuration Guide

This document describes the site-to-site VPN configuration between OCI (eu-amsterdam-1) and remote sites.

## Architecture

```text
┌─────────────────────────────────────────────────────────────────────┐
│                        OCI eu-amsterdam-1                          │
│                                                                     │
│  ┌─────────────────┐     ┌──────────────────────────────────────┐  │
│  │  VCN            │     │  DRG (Dynamic Routing Gateway)       │  │
│  │  192.168.223.0/24    │                                        │  │
│  │                 │     │  ┌──────────────────────────────────┐ │  │
│  │  ┌───────────┐ │     │  │  IPSec Connection: sargeant_onprem│ │  │
│  │  │ edge      │ │─────│  │  Tunnels: 2 (for redundancy)      │ │  │
│  │  │ .0/26     │ │     │  │  Peer: 77.169.18.35               │ │  │
│  │  └───────────┘ │     │  └──────────────────────────────────┘ │  │
│  │  ┌───────────┐ │     │                                        │  │
│  │  │ app       │ │     │  ┌──────────────────────────────────┐ │  │
│  │  │ .64/26    │ │     │  │  IPSec Connection: aws_af_south_1 │ │  │
│  │  └───────────┘ │     │  │  (Pending AWS VGW deployment)     │ │  │
│  │  ┌───────────┐ │     │  └──────────────────────────────────┘ │  │
│  │  │ data      │ │     │                                        │  │
│  │  │ .128/26   │ │     └──────────────────────────────────────┘  │
│  │  └───────────┘ │                                               │
│  │  ┌───────────┐ │                                               │
│  │  │ spare     │ │                                               │
│  │  │ .192/26   │ │                                               │
│  │  └───────────┘ │                                               │
│  └─────────────────┘                                               │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              │ IPSec VPN
                              │
        ┌─────────────────────┴─────────────────────┐
        │                                           │
        ▼                                           ▼
┌───────────────────┐                    ┌───────────────────┐
│  Sargeant On-Prem │                    │  AWS af-south-1   │
│  MikroTik Router  │                    │  (Future)         │
│  77.169.18.35     │                    │                   │
│  192.168.19.0/24  │                    │  10.0.0.0/16      │
└───────────────────┘                    └───────────────────┘
```

## VPN Connections

### 1. Sargeant On-Prem (MikroTik)

| Parameter | Value |
|-----------|-------|
| CPE IP | 77.169.18.35 |
| Remote Network | 192.168.19.0/24 |
| IKE Version | IKEv2 |
| Routing | Static |
| Tunnels | 2 (for redundancy) |

#### MikroTik Configuration

After deploying the OCI VPN, you'll need to configure the MikroTik router. The OCI tunnel IPs and PSKs will be output by Terraform.

```routeros
# Get tunnel details from Terraform output:
# - tunnel1_ip: OCI Tunnel 1 public IP
# - tunnel2_ip: OCI Tunnel 2 public IP
# - PSKs: Retrieve from OCI Vault

# IPSec Profile
/ip ipsec profile
add name=oci-vpn dh-group=modp2048 enc-algorithm=aes-256 hash-algorithm=sha256 \
    lifetime=8h nat-traversal=yes dpd-interval=10s dpd-maximum-failures=3

# IPSec Proposal
/ip ipsec proposal
add name=oci-vpn auth-algorithms=sha256 enc-algorithms=aes-256-cbc lifetime=1h \
    pfs-group=modp2048

# IPSec Peer - Tunnel 1
/ip ipsec peer
add name=oci-tunnel1 address=<tunnel1_ip>/32 profile=oci-vpn exchange-mode=ike2

# IPSec Peer - Tunnel 2
/ip ipsec peer
add name=oci-tunnel2 address=<tunnel2_ip>/32 profile=oci-vpn exchange-mode=ike2

# IPSec Identity - Tunnel 1
/ip ipsec identity
add peer=oci-tunnel1 auth-method=pre-shared-key secret=<psk_tunnel1>

# IPSec Identity - Tunnel 2
/ip ipsec identity
add peer=oci-tunnel2 auth-method=pre-shared-key secret=<psk_tunnel2>

# IPSec Policy - Tunnel 1
/ip ipsec policy
add src-address=192.168.19.0/24 dst-address=192.168.223.0/24 \
    peer=oci-tunnel1 proposal=oci-vpn tunnel=yes action=encrypt level=require

# IPSec Policy - Tunnel 2 (backup)
/ip ipsec policy
add src-address=192.168.19.0/24 dst-address=192.168.223.0/24 \
    peer=oci-tunnel2 proposal=oci-vpn tunnel=yes action=encrypt level=require disabled=yes

# Firewall rules
/ip firewall filter
add chain=input protocol=udp dst-port=500,4500 action=accept comment="IPSec IKE"
add chain=input protocol=ipsec-esp action=accept comment="IPSec ESP"

# NAT exclusion for VPN traffic
/ip firewall nat
add chain=srcnat src-address=192.168.19.0/24 dst-address=192.168.223.0/24 action=accept \
    comment="No NAT for OCI VPN" place-before=0
```

### 2. AWS af-south-1 (Future)

| Parameter | Value |
|-----------|-------|
| CPE IP | Not yet allocated (AWS VPN Gateway) |
| Remote Network | 10.0.0.0/16 (AWS VPC CIDR) |
| IKE Version | IKEv2 |
| Routing | Static or BGP |
| Tunnels | 2 (for redundancy) |

#### AWS Configuration Requirements

When setting up the AWS side:

1. **Create Customer Gateway** pointing to OCI tunnel IPs
2. **Create VPN Connection** with:
   - Type: IPSec
   - Customer Gateway: (created above)
   - Target Gateway: Your VGW attached to the VPC
   - Routing: Static or BGP
   - Static Routes: 192.168.223.0/24

3. **Update Route Tables** to include 192.168.223.0/24 via VGW

4. **Security Groups** to allow traffic from 192.168.223.0/24

## Retrieving PSKs from OCI Vault

```bash
# List secrets in vault
oci vault secret list --compartment-id $OCI_COMPARTMENT_OCID

# Get secret content (requires secret OCID from terraform output)
oci secrets secret-bundle get \
    --secret-id <secret_ocid> \
    --stage CURRENT \
    | jq -r '.data["secret-bundle-content"].content' \
    | base64 -d
```

## Terraform Outputs

After applying the VPN module, you'll get:

```hcl
# Tunnel IPs for configuring remote peers
tunnel_ips = {
  sargeant_onprem = {
    tunnel1_ip = "x.x.x.x"
    tunnel2_ip = "y.y.y.y"
  }
}

# PSK secret OCIDs (retrieve from vault)
psk_secret_ids = {
  sargeant_onprem = {
    tunnel1_psk_secret_id = "ocid1.vaultsecret..."
    tunnel2_psk_secret_id = "ocid1.vaultsecret..."
  }
}
```

## Monitoring

### OCI Console
- Navigate to Networking > Dynamic Routing Gateways
- Click on the DRG
- View IPSec Connections and tunnel status

### CLI
```bash
# List IPSec connections
oci network ip-sec-connection list --compartment-id $OCI_COMPARTMENT_OCID

# Get tunnel status
oci network ip-sec-connection-tunnel list --ipsc-id <ipsec_connection_ocid>
```

## Troubleshooting

### Tunnel Not Coming Up

1. **Check Phase 1 (IKE)**
   - Verify PSK matches on both sides
   - Check IKE version compatibility
   - Verify encryption/hash algorithms match

2. **Check Phase 2 (IPSec)**
   - Verify traffic selectors (source/destination CIDRs)
   - Check proposal settings match

3. **Firewall**
   - UDP 500 (IKE)
   - UDP 4500 (NAT-T)
   - Protocol 50 (ESP)

### Routing Issues

1. Verify route tables have entries for remote networks via DRG
2. Check security lists allow traffic from remote CIDRs
3. Verify NAT exclusion rules on remote side

## Security Considerations

1. PSKs are stored in OCI Vault with encryption
2. Use IKEv2 for better security
3. Enable Perfect Forward Secrecy (PFS)
4. Monitor for failed authentication attempts
5. Regularly rotate PSKs (at least annually)
