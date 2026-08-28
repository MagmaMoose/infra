#!/usr/bin/env python3
"""Verify every ExternalSecret remoteRef names a secret that exists in OCI Vault.

WHY THIS EXISTS
    External Secrets Operator has no per-key "optional". It aborts the whole
    ExternalSecret at the first key it cannot resolve, so ONE wrong name leaves
    the ENTIRE target Secret unwritten and every pod that mounts it sitting
    Pending/ImagePullBackOff behind a single opaque SecretSyncedError. Nothing
    surfaces that at pull-request time.

    This bug class has caused two outages in this estate:
      1. infra b5da0e6 named two finance vault secrets that never existed.
         NOTE: that one was NOT in a `kind: ExternalSecret` document -- it was a
         HelmRelease `spec.values.externalSecret.data` map. Hence extractor B.
      2. dunmir-pro was renamed from mikrotik-minder-pro and its remoteRefs were
         updated to dunmir-pro-*, but the vault entries never were. All eight
         refs 404'd and the namespace was down for days.

USAGE
    check_external_secret_refs.py --path kubernetes [--report-orphans]

EXIT CODES
    0  every checked ref resolves (prints PASS), or credentials absent (SKIPPED)
    1  at least one ref is MISSING or INACTIVE  <- the bug class this catches
    2  operational failure: unparseable manifest, unrecognised shape, missing
       secretStoreRef, OCI auth/API error, or a vault listing below the
       plausibility floor

It exits non-zero if any referenced vault secret does not exist or is not ACTIVE.
It NEVER reads a secret value: the credential is granted SECRET_INSPECT only.
"""

from __future__ import annotations

import argparse
import difflib
import os
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable

import yaml

# Store refs whose `key` is a vault secret name. Anything else -- notably the
# kubernetes-provider mirrors (ghcr-pull-secret-mirror, postgres-oci-app-mirror)
# whose `key` is an in-cluster Secret name -- is SKIPPED.
#
# This is an ALLOWLIST on purpose. A denylist would false-fail the next mirror
# somebody adds. Cost of a wrong skip: one unguarded ExternalSecret. Cost of a
# wrong check: a red build on a correct manifest.
DEFAULT_VAULT_STORES = ["ClusterSecretStore/oci-vault"]

# A vault listing far below the real size means a truncated page, a wrong
# compartment or an expired credential -- all of which would mark every
# reference missing. Refuse to compare rather than emit a wall of false failures.
DEFAULT_MIN_VAULT_SECRETS = 25

OCI_ENV_VARS = [
    "OCI_TENANCY_OCID",
    "OCI_USER_OCID",
    "OCI_FINGERPRINT",
    "OCI_KEY_CONTENT",
    "OCI_REGION",
    "OCI_VAULT_OCID",
]

LINE_KEY = "__line__"


# --------------------------------------------------------------------------- #
# YAML loading with line numbers
# --------------------------------------------------------------------------- #
class _LineLoader(yaml.SafeLoader):
    """SafeLoader that records the source line of every mapping."""


def _construct_mapping(loader: _LineLoader, node: yaml.MappingNode) -> dict:
    mapping = yaml.SafeLoader.construct_mapping(loader, node, deep=False)
    mapping[LINE_KEY] = node.start_mark.line + 1
    return mapping


_LineLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _construct_mapping
)


def _line_of(obj: Any, default: int = 0) -> int:
    return obj.get(LINE_KEY, default) if isinstance(obj, dict) else default


def _real_keys(mapping: dict) -> Iterable[str]:
    """Iterate a mapping's keys, skipping the injected line marker.

    This matters exactly once -- the HelmRelease `data:` map whose keys are
    env-var names -- but getting it wrong there invents a phantom ref.
    """
    return (k for k in mapping if k != LINE_KEY)


# --------------------------------------------------------------------------- #
# Model
# --------------------------------------------------------------------------- #
@dataclass
class Ref:
    """One vault key referenced by one manifest."""

    key: str
    file: str
    line: int
    owner: str  # "ExternalSecret dunmir-pro/dunmir-secrets"
    label_name: str  # "secretKey" | "env var" | "<dataFrom.extract>"
    label_value: str
    prop: str | None = None


@dataclass
class Skip:
    file: str
    line: int
    reason: str


@dataclass
class Findings:
    refs: list[Ref] = field(default_factory=list)
    skips: list[Skip] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)
    files_scanned: int = 0
    es_total: int = 0
    es_vault: int = 0
    hr_enabled: int = 0
    hr_disabled: int = 0


# --------------------------------------------------------------------------- #
# Discovery
# --------------------------------------------------------------------------- #
def discover_files(paths: list[str]) -> tuple[list[Path], str | None]:
    """Return git-tracked YAML under `paths`.

    git ls-files rather than os.walk does four jobs at once: it excludes the
    docs whose fenced examples hold fictional keys, excludes gitignored .old/,
    excludes .claude/worktrees/ (hundreds of ExternalSecret docs across checked
    out copies of this same repo), and matches what CI actually checks out.
    """
    try:
        out = subprocess.run(
            ["git", "ls-files", "-z", "--", *[f"{p}/*.yaml" for p in paths],
             *[f"{p}/*.yml" for p in paths]],
            capture_output=True, text=True, check=True,
        ).stdout
        return [Path(p) for p in out.split("\0") if p], None
    except (subprocess.CalledProcessError, FileNotFoundError):
        found: list[Path] = []
        skip_dirs = {".git", ".old", ".claude", "node_modules", ".venv"}
        for root in paths:
            for p in Path(root).rglob("*"):
                if p.suffix not in (".yaml", ".yml") or not p.is_file():
                    continue
                if skip_dirs & set(p.parts):
                    continue
                found.append(p)
        return found, (
            "git ls-files unavailable; fell back to a filesystem walk. "
            ".gitignore is NOT honoured, so untracked copies may be scanned."
        )


# --------------------------------------------------------------------------- #
# Extractors
# --------------------------------------------------------------------------- #
def _store_of(ref: Any, default_kind: str = "SecretStore") -> str | None:
    if not isinstance(ref, dict):
        return None
    name = ref.get("name")
    if not name:
        return None
    return f"{ref.get('kind') or default_kind}/{name}"


def extract_external_secret(doc: dict, path: str, f: Findings, allow: set[str]) -> None:
    """Extractor A -- `kind: ExternalSecret` custom resources."""
    f.es_total += 1
    spec = doc.get("spec") or {}
    meta = doc.get("metadata") or {}
    owner = (
        f"ExternalSecret {meta.get('namespace', '-')}/{meta.get('name', '<unnamed>')}"
    )

    store = _store_of(spec.get("secretStoreRef"))
    if store is None:
        f.errors.append(
            f"{path}:{_line_of(spec)}  {owner} has no spec.secretStoreRef; "
            f"the guard cannot classify it as vault-backed or not."
        )
        return

    if store not in allow:
        f.skips.append(Skip(path, _line_of(spec), f"non-vault store: {store}"))
        return

    f.es_vault += 1

    for entry in spec.get("data") or []:
        if not isinstance(entry, dict):
            continue
        # A per-entry sourceRef overrides the object-level store.
        entry_store = _store_of((entry.get("sourceRef") or {}).get("storeRef")) or store
        remote = entry.get("remoteRef")
        if not isinstance(remote, dict) or not remote.get("key"):
            f.errors.append(
                f"{path}:{_line_of(entry)}  {owner} has a spec.data entry with no "
                f"remoteRef.key. The guard refuses to report a pass on a manifest "
                f"shape it does not understand."
            )
            continue
        if entry_store not in allow:
            f.skips.append(
                Skip(path, _line_of(entry), f"non-vault sourceRef: {entry_store}")
            )
            continue
        _append_ref(
            f, remote["key"], path, _line_of(entry), owner,
            "secretKey", str(entry.get("secretKey", "-")), remote.get("property"),
        )

    for entry in spec.get("dataFrom") or []:
        if not isinstance(entry, dict):
            continue
        line = _line_of(entry)
        if "extract" in entry and isinstance(entry["extract"], dict):
            key = entry["extract"].get("key")
            if key:
                _append_ref(
                    f, key, path, line, owner, "dataFrom", "<extract>",
                    entry["extract"].get("property"),
                )
            else:
                f.errors.append(
                    f"{path}:{line}  {owner} dataFrom.extract has no key."
                )
        elif "find" in entry:
            # find.name.regexp / find.tags name no specific key, so existence
            # cannot be checked. Report it -- never drop it silently.
            f.skips.append(
                Skip(path, line, "dataFrom.find is not existence-checkable")
            )
        else:
            f.errors.append(
                f"{path}:{line}  {owner} has a dataFrom entry with neither "
                f"'extract' nor 'find'."
            )


def extract_helmrelease(doc: dict, path: str, f: Findings, allow: set[str]) -> None:
    """Extractor B -- HelmRelease `spec.values.**.externalSecret` blocks.

    NOT optional. The finance incident lived here, not in an ExternalSecret CR.
    """
    meta = doc.get("metadata") or {}
    owner_base = f"HelmRelease {meta.get('namespace', '-')}/{meta.get('name', '<unnamed>')}"
    values = ((doc.get("spec") or {}).get("values")) or {}

    for block in _find_external_secret_blocks(values):
        if not block.get("enabled", False):
            f.hr_disabled += 1
            continue
        f.hr_enabled += 1

        store = _store_of(block.get("secretStore"))
        if store is None:
            f.errors.append(
                f"{path}:{_line_of(block)}  {owner_base} has an enabled "
                f"externalSecret block with no secretStore."
            )
            continue
        if store not in allow:
            f.skips.append(Skip(path, _line_of(block), f"non-vault store: {store}"))
            continue

        data = block.get("data")
        owner = f"{owner_base}  (spec.values…externalSecret.data)"
        if isinstance(data, dict):
            for env_name in _real_keys(data):
                spec_entry = data[env_name]
                if not isinstance(spec_entry, dict) or not spec_entry.get("key"):
                    f.errors.append(
                        f"{path}:{_line_of(data)}  {owner_base} data.{env_name} "
                        f"has no 'key'."
                    )
                    continue
                _append_ref(
                    f, spec_entry["key"], path, _line_of(spec_entry), owner,
                    "env var", str(env_name), spec_entry.get("property"),
                )
        elif isinstance(data, list):
            # Defensive: some charts take the CRD list shape verbatim.
            for entry in data:
                if not isinstance(entry, dict):
                    continue
                remote = entry.get("remoteRef") or {}
                key = remote.get("key") or entry.get("key")
                if key:
                    _append_ref(
                        f, key, path, _line_of(entry), owner,
                        "secretKey", str(entry.get("secretKey", "-")),
                        remote.get("property") or entry.get("property"),
                    )


def _find_external_secret_blocks(node: Any) -> Iterable[dict]:
    """Yield every mapping under a key named `externalSecret`, at any depth."""
    if isinstance(node, dict):
        for k in _real_keys(node):
            v = node[k]
            if k == "externalSecret" and isinstance(v, dict):
                yield v
            else:
                yield from _find_external_secret_blocks(v)
    elif isinstance(node, list):
        for item in node:
            yield from _find_external_secret_blocks(item)


def _append_ref(
    f: Findings, key: Any, path: str, line: int, owner: str,
    label_name: str, label_value: str, prop: Any,
) -> None:
    key = str(key)
    if "${" in key or "{{" in key:
        f.skips.append(Skip(path, line, f"templated key, not statically resolvable: {key}"))
        return
    f.refs.append(
        Ref(key=key, file=path, line=line, owner=owner,
            label_name=label_name, label_value=label_value,
            prop=str(prop) if prop else None)
    )


def scan(paths: list[str], allow: set[str]) -> tuple[Findings, str | None]:
    f = Findings()
    files, warn = discover_files(paths)
    for path in files:
        raw = path.read_text(encoding="utf-8", errors="replace")
        try:
            docs = list(yaml.load_all(raw, Loader=_LineLoader))
        except yaml.YAMLError as exc:
            if "kind: ExternalSecret" in raw or "externalSecret:" in raw:
                f.errors.append(
                    f"{path}  is unparseable YAML but mentions ExternalSecret, so "
                    f"it cannot be treated as a silent pass: {exc}"
                )
            continue
        f.files_scanned += 1
        for doc in docs:
            if not isinstance(doc, dict):
                continue  # leading `---` after a comment header yields None
            kind, api = doc.get("kind"), str(doc.get("apiVersion", ""))
            if kind == "ExternalSecret" and api.startswith("external-secrets.io/"):
                extract_external_secret(doc, str(path), f, allow)
            elif kind == "HelmRelease" and api.startswith("helm.toolkit.fluxcd.io/"):
                extract_helmrelease(doc, str(path), f, allow)
    return f, warn


# --------------------------------------------------------------------------- #
# Vault
# --------------------------------------------------------------------------- #
def fetch_vault_secrets(vault_id: str, compartment_id: str) -> dict[str, str]:
    """Return {secret_name: lifecycle_state}. Never reads a secret value."""
    import oci  # imported late so --list works without the SDK installed

    cfg = {
        "user": os.environ["OCI_USER_OCID"],
        "tenancy": os.environ["OCI_TENANCY_OCID"],
        "fingerprint": os.environ["OCI_FINGERPRINT"],
        "region": os.environ["OCI_REGION"],
        # key_content keeps the PEM off the runner filesystem entirely -- no
        # file, no chmod, and no shell mangling its newlines.
        "key_content": os.environ["OCI_KEY_CONTENT"],
    }
    oci.config.validate_config(cfg)
    client = oci.vault.VaultsClient(cfg)
    # list_call_get_all_results, never a bare list_secrets: the OCI CLI's
    # default page size is 50 and it exits 0 while truncating, which against a
    # 134-secret vault would report most valid refs as MISSING.
    resp = oci.pagination.list_call_get_all_results(
        client.list_secrets, compartment_id=compartment_id, vault_id=vault_id
    )
    return {s.secret_name: s.lifecycle_state for s in resp.data}


# --------------------------------------------------------------------------- #
# Reporting
# --------------------------------------------------------------------------- #
def gh(line: str) -> None:
    print(line)


def summary(text: str) -> None:
    target = os.environ.get("GITHUB_STEP_SUMMARY")
    if target:
        with open(target, "a", encoding="utf-8") as fh:
            fh.write(text + "\n")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--path", action="append", default=None, help="scan root (repeatable)")
    ap.add_argument("--vault-store", action="append", default=None,
                    help="KIND/NAME allowlist (repeatable)")
    ap.add_argument("--vault-id", default=os.environ.get("OCI_VAULT_OCID", ""))
    ap.add_argument("--compartment-id",
                    default=os.environ.get("OCI_COMPARTMENT_OCID")
                    or os.environ.get("OCI_TENANCY_OCID", ""))
    ap.add_argument("--min-vault-secrets", type=int, default=DEFAULT_MIN_VAULT_SECRETS)
    ap.add_argument("--report-orphans", action="store_true")
    ap.add_argument("--fail-on-unverifiable", action="store_true")
    ap.add_argument("--vault-names-from", default=None,
                    help="offline TSV fixture (name<TAB>STATE); test use only")
    ap.add_argument("--list", action="store_true", help="print refs and exit 0")
    ap.add_argument("--no-annotations", action="store_true")
    ap.add_argument(
        "--allow-skip",
        action="store_true",
        help=(
            "Exit 0 instead of 2 when the OCI credentials are absent. For runs that "
            "genuinely cannot hold secrets (fork pull requests, Dependabot) — never as a "
            "blanket default, which is the defect this flag exists to end."
        ),
    )
    args = ap.parse_args()

    paths = args.path or ["."]
    allow = set(args.vault_store or DEFAULT_VAULT_STORES)

    findings, walk_warning = scan(paths, allow)
    if walk_warning:
        gh(f"warning: {walk_warning}")

    distinct = sorted({r.key for r in findings.refs})

    gh("external-secret vault guard")
    gh(f"  files scanned      {findings.files_scanned}")
    gh(f"  ExternalSecrets    {findings.es_total} ({findings.es_vault} vault-backed)")
    gh(f"  HelmRelease blocks {findings.hr_enabled} enabled, {findings.hr_disabled} disabled")
    gh(f"  refs found         {len(findings.refs)} across {len(distinct)} distinct keys")
    gh(f"  refs skipped       {len(findings.skips)}")
    gh("")

    for s in findings.skips:
        gh(f"  SKIPPED {s.file}:{s.line}  {s.reason}")
    if findings.skips:
        gh("")

    if findings.errors:
        for e in findings.errors:
            gh(f"  ERROR {e}")
            if not args.no_annotations:
                gh(f"::error::{e}")
        gh("")
        gh("ERROR — the guard does not understand one or more manifests and "
           "refuses to report a pass over them.")
        return 2

    if args.fail_on_unverifiable and findings.skips:
        gh("FAIL — --fail-on-unverifiable is set and some refs could not be verified.")
        return 1

    if args.list:
        for r in findings.refs:
            gh(f"  {r.key}\t{r.file}:{r.line}\t{r.owner}")
        return 0

    # ---- vault side ----------------------------------------------------- #
    if args.vault_names_from:
        states = {}
        for ln in Path(args.vault_names_from).read_text().splitlines():
            if not ln.strip():
                continue
            name, _, state = ln.partition("\t")
            states[name.strip()] = (state.strip() or "ACTIVE")
    else:
        missing_env = [v for v in OCI_ENV_VARS if not os.environ.get(v, "").strip()]
        if missing_env and not args.allow_skip:
            # THE DEFAULT IS NOW RED. The original reasoning — never fail closed,
            # because that reds every fork and Dependabot PR — was right about forks
            # and wrong about everything else. It made "the secrets were never
            # created" indistinguishable from "this run cannot hold them", and the
            # first is a misconfiguration that then hides behind a green check for as
            # long as nobody reads the annotation. It did exactly that: the guard
            # shipped, was never given credentials, and verified nothing while passing
            # every pull request in the repo it was written to protect.
            #
            # A caller that genuinely cannot hold secrets says so with --allow-skip:
            # one visible line at the call site, rather than a silent property of
            # every run everywhere.
            gh("ERROR — vault comparison IMPOSSIBLE, and skipping was not permitted")
            gh(f"  missing credentials: {', '.join(missing_env)}")
            gh(f"  {len(findings.refs)} references were parsed but NOT verified.")
            gh("")
            gh("  Either provide the credentials (see this action's README), or pass")
            gh("  allow-skip: true at the call site for runs that cannot hold them")
            gh("  (fork pull requests, Dependabot). Do not set it unconditionally —")
            gh("  that restores the behaviour this exit code exists to end.")
            note = (
                f"External Secret vault guard could not run: {', '.join(missing_env)} "
                f"unset and allow-skip is false. {len(findings.refs)} references parsed, "
                f"none verified."
            )
            if not args.no_annotations:
                gh(f"::error title=External Secret vault guard NOT RUN::{note}")
            summary(f"### External Secrets\n\n**FAILED** — {note}")
            return 2

        if missing_env:
            # Skipping was explicitly permitted for this run. Still never prints
            # "PASS": two green outcomes, two distinct words.
            gh("VAULT COMPARISON SKIPPED (allow-skip)")
            gh(f"  missing credentials: {', '.join(missing_env)}")
            gh(f"  {len(findings.refs)} references were parsed but NOT verified.")
            gh("  Expected on fork and Dependabot pull requests. On a normal branch")
            gh("  it means the org secrets are not set yet — see this action's README.")
            gh("")
            for r in findings.refs:
                gh(f"  would check  {r.key}  ({r.file}:{r.line})")
            note = (
                f"External Secret vault guard SKIPPED — credentials unavailable "
                f"({', '.join(missing_env)}). {len(findings.refs)} references parsed, "
                f"none verified."
            )
            if not args.no_annotations:
                gh(f"::notice title=External Secret vault guard SKIPPED::{note}")
            summary(f"### External Secrets\n\n**SKIPPED** — {note}")
            return 0

        try:
            states = fetch_vault_secrets(args.vault_id, args.compartment_id)
        except Exception as exc:  # noqa: BLE001 - any OCI failure is operational
            gh(f"ERROR — vault listing failed: {type(exc).__name__}: {exc}")
            gh("  A configured credential that fails is a real defect, distinct")
            gh("  from an absent one. Check the IAM policy and key rotation.")
            if not args.no_annotations:
                gh("::error title=External Secret vault guard::vault listing failed")
            return 2

    if len(states) < args.min_vault_secrets:
        gh(f"ERROR — vault listing returned {len(states)} secrets, below the "
           f"plausibility floor of {args.min_vault_secrets}. Refusing to compare: "
           f"a truncated, empty or wrong-compartment listing would mark every "
           f"reference missing.")
        return 2

    active = {n for n, st in states.items() if st == "ACTIVE"}
    gh(f"  vault              {len(states)} secrets listed, {len(active)} ACTIVE")
    gh("")

    # ---- compare -------------------------------------------------------- #
    bad: list[tuple[Ref, str]] = []
    for r in findings.refs:
        if r.key in active:
            continue
        verdict = (
            f"INACTIVE — exists but lifecycle-state={states[r.key]}"
            if r.key in states
            else "MISSING — no secret of that name exists in this vault"
        )
        bad.append((r, verdict))

    if not bad:
        gh(f"PASS — all {len(findings.refs)} vault references resolve to ACTIVE secrets.")
        props = [r for r in findings.refs if r.prop]
        if props:
            gh(f"  note: {len(props)} refs use remoteRef.property; the parent key was")
            gh("        verified, the property within it was NOT (that needs")
            gh("        GetSecretBundle, which this credential is deliberately denied).")
            gh("        A green result proves the NAME exists, not that ESO can read it.")
        if args.report_orphans:
            orphans = sorted(active - {r.key for r in findings.refs})
            gh("")
            gh(f"INFORMATIONAL — does not affect the exit code. {len(orphans)} ACTIVE "
               f"vault secrets are referenced by nothing in this scan.")
            gh("  The vault is shared across repos, so this is expected, NOT a "
               "delete list.")
            for o in orphans:
                gh(f"    {o}")
        summary(f"### External Secrets\n\n**PASS** — {len(findings.refs)} references verified.")
        return 0

    all_names = sorted(states)
    gh(f"FAIL — {len(bad)} of {len(findings.refs)} vault references do not resolve.")
    gh("")
    for r, verdict in bad:
        gh(f"  {r.file}:{r.line}")
        gh(f"    {r.owner}")
        gh(f"    {r.label_name:<16} {r.label_value}")
        gh(f"    key              {r.key}")
        gh(f"    verdict          {verdict}")
        for m in difflib.get_close_matches(r.key, all_names, n=3, cutoff=0.6):
            ratio = difflib.SequenceMatcher(None, r.key, m).ratio()
            gh(f"    nearest in vault {m}  ({ratio:.2f})")
        gh("")
        if not args.no_annotations:
            gh(f"::error file={r.file},line={r.line}::{r.key}: {verdict}")

    gh("Why this is fatal, not cosmetic:")
    gh("  External Secrets Operator has NO per-key \"optional\". It aborts the whole")
    gh("  ExternalSecret at the first key it cannot resolve, so ONE bad name leaves")
    gh("  the ENTIRE target Secret unwritten and every pod that mounts it sitting")
    gh("  Pending/ImagePullBackOff behind a single opaque SecretSyncedError.")
    gh("")
    gh("The two causes seen in production:")
    gh("  1. A RENAME THAT STOPPED AT THE MANIFEST. mikrotik-minder-pro became")
    gh("     dunmir-pro and the remoteRefs followed, but the vault entries did not.")
    gh("     If \"nearest in vault\" above shows an old project name, this is it.")
    gh("  2. A KEY THAT WAS NEVER PROVISIONED — the manifest was written before the")
    gh("     vault entry existed, and nothing failed until reconcile time.")
    summary(f"### External Secrets\n\n**FAIL** — {len(bad)} unresolved references.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
