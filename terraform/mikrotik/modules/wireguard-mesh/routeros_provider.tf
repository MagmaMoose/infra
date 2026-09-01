# One provider instance per router. Unlike the other two mikrotik modules, the
# credentials are per-router rather than shared: the two OCI environments have
# separate admin passwords (separate Oracle accounts, separate vaults), so a
# single var.routeros_password could not reach all five devices.
provider "routeros" {
  alias    = "by_router"
  for_each = var.routers

  hosturl  = each.value.hosturl
  username = each.value.username
  password = var.router_passwords[each.key]
  insecure = each.value.insecure
}
