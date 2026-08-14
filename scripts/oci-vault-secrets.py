#!/usr/bin/env python3
"""Manage OCI Vault secrets for either cluster, without the console.

    firefly        -> OCI tenancy in eu-amsterdam-1   (default vault: vault-prod)
    franklinhouse  -> a SEPARATE OCI tenancy in af-johannesburg-1
                      (default vault: vault-franklinhouse)

These are two different OCI accounts. This script keeps them apart by fetching
each one's API signing credentials from 1Password at run time into a 0700 temp
directory that is removed on exit. Nothing is written to the repo, and no OCI
profile needs to exist on the machine.

Requires: `oci` CLI and `op` (1Password CLI, authenticated). No third-party
Python packages -- deliberately, so it runs anywhere the oci CLI already does.

Usage:
    scripts/oci-vault-secrets.py -c <cluster> [-V <vault>] <command> [args]

Commands:
    vaults                List vaults in the tenancy
    list                  List secret names in the vault
    get <name>            Print a secret's value to stdout
    set <name> [value]    Create or update a secret; reads stdin if value omitted
    delete <name> [days]  Schedule deletion (default 30 days)

Examples:
    scripts/oci-vault-secrets.py -c franklinhouse list
    scripts/oci-vault-secrets.py -c franklinhouse get access-control-secret > /tmp/s
    cat id_ed25519 | scripts/oci-vault-secrets.py -c franklinhouse set access-control-deploy-key
    scripts/oci-vault-secrets.py -c firefly -V vault-firefly list

NOTE ON `get`: it writes the secret to stdout. Redirect it rather than letting
it land in scrollback or shell history.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
from datetime import datetime, timedelta, timezone

# cluster -> (1Password item reference, region, default vault name).
# Only the op:// path lives here; credentials are read at run time.
CLUSTERS = {
    "firefly": {
        "op": "op://Magma Moose/thry5omisuq7pxy6fdbqm63vce",
        "region": "eu-amsterdam-1",
        "vault": "vault-prod",
    },
    "franklinhouse": {
        "op": "op://Franklin House/mbcio5qom6xfj6glkkwtiim2za",
        "region": "af-johannesburg-1",
        "vault": "vault-franklinhouse",
    },
}


def die(msg: str) -> "NoReturn":  # noqa: F821
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def note(msg: str) -> None:
    print(msg, file=sys.stderr)


def op_read(ref: str) -> str:
    """Read a field from 1Password. Never logged, never written to the repo."""
    p = subprocess.run(["op", "read", ref], capture_output=True, text=True)
    if p.returncode != 0:
        die(
            f"could not read {ref}\n"
            f"       is `op` authenticated and granted that vault?\n"
            f"       {p.stderr.strip().splitlines()[-1] if p.stderr.strip() else ''}"
        )
    return p.stdout


class Oci:
    """Thin wrapper around the oci CLI, pinned to one tenancy's credentials."""

    def __init__(self, op_item: str, region: str) -> None:
        self.region = region
        self.workdir = tempfile.mkdtemp(prefix="ocivault-")
        os.chmod(self.workdir, stat.S_IRWXU)

        key_path = os.path.join(self.workdir, "api_key.pem")
        cfg_path = os.path.join(self.workdir, "config")

        key = op_read(f"{op_item}/private key").replace("\r\n", "\n")
        if not key.endswith("\n"):
            key += "\n"
        _write_private(key_path, key)

        cfg_raw = op_read(f"{op_item}/configuration").replace("\r\n", "\n")
        lines = [ln for ln in cfg_raw.split("\n") if not ln.strip().startswith("key_file")]
        lines.append(f"key_file={key_path}")
        _write_private(cfg_path, "\n".join(lines) + "\n")

        self.config = cfg_path
        self.tenancy = _cfg_value(cfg_raw, "tenancy")
        if not self.tenancy:
            die("no `tenancy` in the 1Password configuration field")

    def close(self) -> None:
        shutil.rmtree(self.workdir, ignore_errors=True)

    def __enter__(self) -> "Oci":
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    def run(self, *args: str) -> dict:
        # PYTHONIOENCODING is not optional on Windows: the oci CLI is itself a
        # Python program, and some secret descriptions contain non-cp1252
        # characters (e.g. U+2192). Without this it dies with UnicodeEncodeError
        # while writing its own JSON, which looks like an API failure but is not.
        env = dict(os.environ, SUPPRESS_LABEL_WARNING="True", PYTHONIOENCODING="utf-8")
        p = subprocess.run(
            ["oci", "--config-file", self.config, "--region", self.region, *args, "--output", "json"],
            capture_output=True, text=True, env=env, encoding="utf-8", errors="replace",
        )
        if p.returncode != 0:
            tail = (p.stderr or p.stdout).strip().splitlines()
            die("oci " + " ".join(args) + "\n       " + "\n       ".join(tail[-4:]))
        return json.loads(p.stdout) if p.stdout.strip() else {}


def _write_private(path: str, content: str) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", newline="\n") as fh:
        fh.write(content)


def _cfg_value(cfg: str, key: str) -> str:
    for line in cfg.split("\n"):
        s = line.strip()
        if s.startswith(key) and "=" in s:
            k, v = s.split("=", 1)
            if k.strip() == key:
                return v.strip()
    return ""


def active_vaults(oci: Oci) -> list[dict]:
    data = oci.run("kms", "management", "vault", "list", "-c", oci.tenancy).get("data") or []
    return [v for v in data if v.get("lifecycle-state") == "ACTIVE"]


def resolve_vault(oci: Oci, name: str) -> dict:
    for v in active_vaults(oci):
        if v.get("display-name") == name:
            return v
    die(f"vault '{name}' not found (ACTIVE) in this tenancy -- try the `vaults` command")


def list_secrets(oci: Oci, vault_id: str) -> list[dict]:
    data = oci.run("vault", "secret", "list", "-c", oci.tenancy, "--vault-id", vault_id, "--all").get("data") or []
    return [s for s in data if s.get("lifecycle-state") != "DELETED"]


def secret_id(oci: Oci, vault_id: str, name: str) -> str | None:
    for s in list_secrets(oci, vault_id):
        if s.get("secret-name") == name:
            return s.get("id")
    return None


def main() -> None:
    ap = argparse.ArgumentParser(
        description="Manage OCI Vault secrets for firefly or franklinhouse.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__.split("Usage:", 1)[1] if "Usage:" in __doc__ else None,
    )
    ap.add_argument("-c", "--cluster", required=True, choices=sorted(CLUSTERS))
    ap.add_argument("-V", "--vault", help="override the vault by NAME")
    ap.add_argument("command", choices=["vaults", "list", "get", "set", "delete"])
    ap.add_argument("args", nargs="*")
    a = ap.parse_args()

    for bin_ in ("oci", "op"):
        if shutil.which(bin_) is None:
            die(f"{bin_} is required but not installed")

    conf = CLUSTERS[a.cluster]
    vault_name = a.vault or conf["vault"]

    with Oci(conf["op"], conf["region"]) as oci:
        if a.command == "vaults":
            rows = [(v["display-name"], v["lifecycle-state"], v["id"]) for v in active_vaults(oci)]
            w = max((len(r[0]) for r in rows), default=4)
            for n, st, vid in sorted(rows):
                print(f"{n:<{w}}  {st:<8}  {vid}")
            return

        vault = resolve_vault(oci, vault_name)
        vault_id, mgmt = vault["id"], vault["management-endpoint"]

        if a.command == "list":
            rows = sorted((s["secret-name"], s["lifecycle-state"]) for s in list_secrets(oci, vault_id))
            if not rows:
                note(f"(no secrets in {vault_name})")
                return
            w = max(len(r[0]) for r in rows)
            for n, st in rows:
                print(f"{n:<{w}}  {st}")

        elif a.command == "get":
            if not a.args:
                die("usage: get <name>")
            out = oci.run("secrets", "secret-bundle", "get-secret-bundle-by-name",
                          "--secret-name", a.args[0], "--vault-id", vault_id)
            content = (out.get("data", {}).get("secret-bundle-content") or {}).get("content")
            if not content:
                die(f"secret '{a.args[0]}' not found in {vault_name}")
            sys.stdout.buffer.write(base64.b64decode(content))

        elif a.command == "set":
            if not a.args:
                die("usage: set <name> [value]   (reads stdin if value omitted)")
            name = a.args[0]
            value = a.args[1] if len(a.args) > 1 else sys.stdin.read()
            if not value:
                die("refusing to store an empty secret")
            b64 = base64.b64encode(value.encode()).decode()

            existing = secret_id(oci, vault_id, name)
            if existing:
                oci.run("vault", "secret", "update-base64", "--secret-id", existing,
                        "--secret-content-content", b64)
                note(f"updated '{name}' in {vault_name} (new version)")
            else:
                keys = oci.run("kms", "management", "key", "list", "-c", oci.tenancy,
                               "--endpoint", mgmt).get("data") or []
                enabled = [k for k in keys if k.get("lifecycle-state") == "ENABLED"]
                if not enabled:
                    die(f"vault '{vault_name}' has no ENABLED master key -- create one before adding secrets")
                oci.run("vault", "secret", "create-base64", "--compartment-id", oci.tenancy,
                        "--secret-name", name, "--vault-id", vault_id,
                        "--key-id", enabled[0]["id"], "--secret-content-content", b64)
                note(f"created '{name}' in {vault_name}")

        elif a.command == "delete":
            if not a.args:
                die("usage: delete <name> [days]")
            sid = secret_id(oci, vault_id, a.args[0])
            if not sid:
                die(f"secret '{a.args[0]}' not found in {vault_name}")
            days = int(a.args[1]) if len(a.args) > 1 else 30
            when = (datetime.now(timezone.utc) + timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ")
            oci.run("vault", "secret", "schedule-secret-deletion", "--secret-id", sid,
                    "--time-of-deletion", when)
            note(f"scheduled '{a.args[0]}' for deletion at {when} (cancel in the console before then)")


if __name__ == "__main__":
    main()
