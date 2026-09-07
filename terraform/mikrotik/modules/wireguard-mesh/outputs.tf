output "public_keys" {
  description = "WireGuard public key per (router, tunnel) end, keyed \"<router>/<tunnel>\". Handy for eyeballing that both ends of a tunnel reference each other."
  value       = { for k, i in routeros_interface_wireguard.this : k => i.public_key }
}

output "transit_addresses" {
  description = "Transit address per (router, tunnel) end — the address to ping to prove a tunnel is passing traffic."
  value       = { for k, e in local.ends : k => e.self_ip }
}

output "allowed_addresses" {
  description = "Derived allowed-address list per end. Read this when a tunnel handshakes but a prefix does not pass."
  value       = local.allowed_addresses
}
