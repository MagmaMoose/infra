"""Tests for the reference-parsing path of check_external_secret_refs.py.

The OCI vault comparison is never invoked. These tests cover:
  (1) a well-formed ExternalSecret yields the expected vault references
  (2) a manifest with no vault references yields an empty list without raising
  (3) a malformed entry (missing remoteRef.key) is recorded as a parse error,
      not silently dropped

Run: python3 .github/actions/external-secret-vault-guard/test_check_external_secret_refs.py
"""

import importlib.util
import pathlib
import sys

_HERE = pathlib.Path(__file__).resolve().parent
_GUARD = _HERE / "check_external_secret_refs.py"
spec = importlib.util.spec_from_file_location("check_external_secret_refs", _GUARD)
guard = importlib.util.module_from_spec(spec)
sys.modules["check_external_secret_refs"] = guard
spec.loader.exec_module(guard)

ALLOW = {"ClusterSecretStore/oci-vault"}

FAILURES: list[str] = []


def check(label: str, got: object, want: object) -> None:
    if got != want:
        FAILURES.append(f"{label}\n     got:  {got!r}\n     want: {want!r}")
    print(f"  {'ok  ' if got == want else 'FAIL'} {label}")


def _findings() -> guard.Findings:
    return guard.Findings()


def _es_doc(
    data_entries: list | None = None,
    data_from: list | None = None,
    store_name: str = "oci-vault",
    store_kind: str = "ClusterSecretStore",
    namespace: str = "test-ns",
    name: str = "test-es",
) -> dict:
    """Minimal ExternalSecret dict for parsing tests (no LINE_KEY injection needed)."""
    doc: dict = {
        "apiVersion": "external-secrets.io/v1beta1",
        "kind": "ExternalSecret",
        "metadata": {"namespace": namespace, "name": name},
        "spec": {
            "secretStoreRef": {"name": store_name, "kind": store_kind},
        },
    }
    if data_entries is not None:
        doc["spec"]["data"] = data_entries
    if data_from is not None:
        doc["spec"]["dataFrom"] = data_from
    return doc


# --------------------------------------------------------------------------- #
# test 1: well-formed ExternalSecret
# --------------------------------------------------------------------------- #
print("\ntest 1: well-formed ExternalSecret yields expected vault references")

doc1 = _es_doc(data_entries=[
    {"secretKey": "DB_PASSWORD", "remoteRef": {"key": "prod-db-password"}},
    {"secretKey": "API_TOKEN",   "remoteRef": {"key": "prod-api-token", "property": "token"}},
])
f1 = _findings()
guard.extract_external_secret(doc1, "test/well-formed.yaml", f1, ALLOW)

check("es_vault count incremented",        f1.es_vault,               1)
check("two refs collected",                len(f1.refs),               2)
check("no errors",                         f1.errors,                  [])
check("no skips",                          f1.skips,                   [])
check("first ref key",                     f1.refs[0].key,             "prod-db-password")
check("first ref secretKey label",         f1.refs[0].label_value,     "DB_PASSWORD")
check("first ref prop is None",            f1.refs[0].prop,            None)
check("second ref key",                    f1.refs[1].key,             "prod-api-token")
check("second ref property forwarded",     f1.refs[1].prop,            "token")
check("owner names the namespace/name",    "test-ns/test-es" in f1.refs[0].owner, True)

# dataFrom.extract path
doc1b = _es_doc(data_from=[
    {"extract": {"key": "prod-db-password"}},
])
f1b = _findings()
guard.extract_external_secret(doc1b, "test/datafrom.yaml", f1b, ALLOW)

check("dataFrom.extract: ref collected",   len(f1b.refs),  1)
check("dataFrom.extract: key correct",     f1b.refs[0].key, "prod-db-password")
check("dataFrom.extract: no errors",       f1b.errors,      [])


# --------------------------------------------------------------------------- #
# test 2: manifest with no vault references yields an empty list
# --------------------------------------------------------------------------- #
print("\ntest 2: manifest with no vault refs yields empty list without raising")

doc2 = _es_doc(data_entries=[], data_from=[])
f2 = _findings()
guard.extract_external_secret(doc2, "test/empty.yaml", f2, ALLOW)

check("empty data/dataFrom: no refs",       f2.refs,         [])
check("empty data/dataFrom: no errors",     f2.errors,       [])
check("empty data/dataFrom: no skips",      f2.skips,        [])
check("es_vault still incremented",         f2.es_vault,     1)

# Non-vault store → skip, not an error, and no refs added.
doc2b = _es_doc(
    data_entries=[{"secretKey": "K", "remoteRef": {"key": "some-key"}}],
    store_name="k8s-mirror-store",
    store_kind="SecretStore",
)
f2b = _findings()
guard.extract_external_secret(doc2b, "test/other-store.yaml", f2b, ALLOW)

check("non-vault store: refs is empty",     f2b.refs,        [])
check("non-vault store: one skip recorded", len(f2b.skips),  1)
check("non-vault store: no errors",         f2b.errors,      [])
check("non-vault store: es_vault unchanged", f2b.es_vault,   0)


# --------------------------------------------------------------------------- #
# test 3: malformed/partial reference → structured error, not silent omission
# --------------------------------------------------------------------------- #
print("\ntest 3: malformed reference is a parse error, not a silent drop")

# remoteRef present but key absent — the field the guard must have.
doc3 = _es_doc(data_entries=[
    {"secretKey": "DB_PASSWORD", "remoteRef": {}},                          # bad
    {"secretKey": "API_TOKEN",   "remoteRef": {"key": "prod-api-token"}},   # good
])
f3 = _findings()
guard.extract_external_secret(doc3, "test/missing-key.yaml", f3, ALLOW)

check("bad entry not silently added",       len(f3.refs),    1)
check("exactly one error recorded",         len(f3.errors),  1)
check("good entry still collected",         f3.refs[0].key,  "prod-api-token")
check("error names the file",               "test/missing-key.yaml" in f3.errors[0], True)
check("error mentions remoteRef.key",       "remoteRef.key" in f3.errors[0], True)

# remoteRef absent entirely (not just missing key).
doc3b = _es_doc(data_entries=[
    {"secretKey": "DB_PASSWORD"},  # no remoteRef at all
])
f3b = _findings()
guard.extract_external_secret(doc3b, "test/no-remote-ref.yaml", f3b, ALLOW)

check("absent remoteRef: no silent ref",    f3b.refs,        [])
check("absent remoteRef: error recorded",   len(f3b.errors), 1)

# dataFrom.extract present but key missing.
doc3c = _es_doc(data_from=[{"extract": {}}])
f3c = _findings()
guard.extract_external_secret(doc3c, "test/datafrom-no-key.yaml", f3c, ALLOW)

check("dataFrom missing key: no ref",       f3c.refs,        [])
check("dataFrom missing key: error",        len(f3c.errors), 1)


# --------------------------------------------------------------------------- #
# summary
# --------------------------------------------------------------------------- #
print()
if FAILURES:
    print(f"{len(FAILURES)} FAILURE(S):")
    for failure in FAILURES:
        print("  - " + failure)
    sys.exit(1)
print("all assertions passed")
