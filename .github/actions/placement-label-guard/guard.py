#!/usr/bin/env python3
"""Verify every placement.sargeant.co label can actually reach a pod template.

kustomize `labels:` applies to EVERY resource a kustomization emits, while the
Kyverno placement policies match only Deployment, StatefulSet, DaemonSet and
CronJob. A label that lands on anything else is inert — and invisible to the
policies' own typo guards, which do not match those kinds either. Nothing in the
cluster reports it; the workload is simply never pinned or prioritised.

Only two carrier kinds actually matter, because they produce pods of their own
that the label cannot reach:

  HelmRelease  the chart renders the workload, so the label stops at the HR
  Cluster      CNPG builds its instance pods itself (postgresql.cnpg.io)

Everything else a kustomization emits (PVC, Ingress, Service, ExternalSecret,
ClusterRole, CRDs, Jobs...) inherits the label harmlessly. Flagging those buries
the signal.

For the two that matter the guard does not just complain — it checks whether the
concern is handled the correct way instead, per label:

  tier      needs a nodeSelector in the chart's values / the Cluster's affinity
  priority  needs a priorityClassName in the chart's values / on the Cluster

so a workload that legitimately sets placement in Helm values passes, and one
that quietly sets neither fails.

This bug class shipped twice: headlamp's tier label was inert on its HelmRelease
while landing on the oauth2-proxy and auth-redirect Deployments beside it, and
external-dns-mikrotik's priority label never reached the chart's Deployment.

SECOND CHECK — the complement. The above only sees kustomizations that DECLARE a
placement label, so it is blind to the opposite failure: a workload with no
placement at all. That one is silent too — the workload simply schedules
wherever, which on a mixed arm64/amd64 cluster can mean an image that cannot run.
So every controller Flux actually applies must have EITHER a placement label or
an inline nodeSelector.

DaemonSets are exempt: they run on every node by design, so "unpinned" is their
correct state. The check builds each Flux Kustomization's `path:` rather than
every kustomization.yaml, because a base/ directory built in isolation misses
labels its parent applies — measuring that way produces false positives.
"""

from __future__ import annotations

import json
import os
import pathlib
import subprocess
import sys

import yaml

PREFIX = "placement.sargeant.co/"
TIER = PREFIX + "tier"
PRIORITY = PREFIX + "priority"

MATCHABLE = {"Deployment", "StatefulSet", "DaemonSet", "CronJob"}
POD_BEARING_UNMATCHED = {"HelmRelease", "Cluster"}

root = pathlib.Path(os.environ.get("ROOT", "kubernetes"))
problems: list[tuple[str, str, str]] = []
checked = 0


def declares_placement_label(kfile: pathlib.Path) -> bool:
    try:
        doc = yaml.safe_load(kfile.read_text(encoding="utf-8")) or {}
    except yaml.YAMLError:
        return False
    if not isinstance(doc, dict):
        return False
    for entry in doc.get("labels") or []:
        if isinstance(entry, dict):
            if any(k.startswith(PREFIX) for k in (entry.get("pairs") or {})):
                return True
    return any(k.startswith(PREFIX) for k in (doc.get("commonLabels") or {}))


def build(directory: pathlib.Path) -> list[dict] | None:
    proc = subprocess.run(
        ["kustomize", "build", str(directory), "--load-restrictor=LoadRestrictionsNone"],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        return None
    try:
        return [d for d in yaml.safe_load_all(proc.stdout) if isinstance(d, dict)]
    except yaml.YAMLError:
        return None


def unhandled_concerns(doc: dict, labels: dict) -> list[str]:
    """Which placement concerns this pod-bearing object leaves unaddressed."""
    spec = doc.get("spec") or {}
    if doc.get("kind") == "HelmRelease":
        blob = json.dumps(spec.get("values") or {})
        has_placement = "nodeSelector" in blob or "affinity" in blob
        has_priority = "priorityClassName" in blob
        where = "the chart's spec.values"
    else:  # CNPG Cluster
        blob = json.dumps(spec)
        has_placement = "affinity" in spec or "nodeSelector" in blob
        has_priority = "priorityClassName" in spec
        where = "the Cluster spec"

    missing = []
    if TIER in labels and not has_placement:
        missing.append(f"tier (no nodeSelector/affinity in {where})")
    if PRIORITY in labels and not has_priority:
        missing.append(f"priority (no priorityClassName in {where})")
    return missing


for kfile in sorted(root.rglob("kustomization.yaml")):
    if not declares_placement_label(kfile):
        continue
    checked += 1
    docs = build(kfile.parent)
    if docs is None:
        problems.append((str(kfile), "BUILD", "kustomize build failed, so the label's reach cannot be verified"))
        continue

    reachable: dict[str, list[str]] = {}
    # A HelmRelease/Cluster carrier means the workload IS accounted for here, even
    # when the label itself is inert — so the "nothing was pinned" fallback below
    # must not fire for it. Whether it is handled *correctly* is judged separately.
    pod_bearing_seen = False
    for doc in docs:
        labels = ((doc.get("metadata") or {}).get("labels") or {})
        if not any(k.startswith(PREFIX) for k in labels):
            continue
        kind = doc.get("kind", "?")
        name = (doc.get("metadata") or {}).get("name", "?")

        if kind in MATCHABLE:
            reachable.setdefault(kind, []).append(name)
        elif kind in POD_BEARING_UNMATCHED:
            pod_bearing_seen = True
            missing = unhandled_concerns(doc, labels)
            if missing:
                problems.append(
                    (
                        str(kfile),
                        "INERT",
                        f"{kind}/{name} carries the label but the policies cannot match it, and "
                        f"nothing sets it the supported way either — unaddressed: {', '.join(missing)}",
                    )
                )

    if not reachable and not pod_bearing_seen and not any(p[0] == str(kfile) for p in problems):
        problems.append(
            (
                str(kfile),
                "UNREACHED",
                "declares a placement label but emits no Deployment/StatefulSet/DaemonSet/CronJob "
                "carrying it, so nothing is pinned or prioritised",
            )
        )

# ---------------------------------------------------------------------------
# Second check: controllers with NO placement at all.
# ---------------------------------------------------------------------------
def flux_applied_paths() -> set:
    """The `path:` of every Flux Kustomization — what actually gets applied."""
    found = set()
    for f in root.rglob("*.yaml"):
        try:
            docs = [d for d in yaml.safe_load_all(f.read_text(encoding="utf-8")) if isinstance(d, dict)]
        except (yaml.YAMLError, UnicodeDecodeError, OSError):
            continue
        for d in docs:
            if d.get("kind") == "Kustomization" and "kustomize.toolkit.fluxcd.io" in str(d.get("apiVersion", "")):
                p = (d.get("spec") or {}).get("path")
                if p:
                    found.add(p.lstrip("./"))
    return found


# DaemonSets run on every node by design, so having no nodeSelector is correct.
NEEDS_PLACEMENT = {"Deployment", "StatefulSet", "CronJob"}
controllers_checked = 0

for rel in sorted(flux_applied_paths()):
    directory = pathlib.Path(rel)
    if not directory.is_dir():
        continue
    docs = build(directory)
    if docs is None:
        continue
    for doc in docs:
        if doc.get("kind") not in NEEDS_PLACEMENT:
            continue
        controllers_checked += 1
        labels = ((doc.get("metadata") or {}).get("labels") or {})
        spec = doc.get("spec") or {}
        tmpl = spec.get("template") or (spec.get("jobTemplate") or {}).get("spec", {}).get("template") or {}
        node_selector = (tmpl.get("spec") or {}).get("nodeSelector") or {}
        if not any(k.startswith(PREFIX) for k in labels) and not node_selector:
            problems.append(
                (
                    rel,
                    "UNPLACED",
                    f"{doc.get('kind')}/{(doc.get('metadata') or {}).get('name')} has neither a "
                    f"{PREFIX}tier label nor an inline nodeSelector, so it schedules wherever there "
                    "is room — on a mixed arm64/amd64 cluster that can mean a node whose "
                    "architecture the image does not support",
                )
            )

summary = pathlib.Path(os.environ.get("GITHUB_STEP_SUMMARY", os.devnull))
with summary.open("a", encoding="utf-8") as fh:
    fh.write("## Placement label guard\n\n")
    fh.write(f"Checked **{checked}** kustomization(s) declaring a `{PREFIX}*` label, and "
             f"**{controllers_checked}** Flux-applied controller(s) for having any placement at all.\n\n")
    if problems:
        fh.write("| kustomization | problem | detail |\n|---|---|---|\n")
        for path, kind, detail in problems:
            fh.write(f"| `{path}` | {kind} | {detail} |\n")
    else:
        fh.write("Every placement label reaches a controller the policies match, or is "
                 "handled directly in chart values / the Cluster spec.\n")

for path, kind, detail in problems:
    print(f"::error file={path}::[{kind}] {detail}")

if problems:
    print(f"\n{len(problems)} placement label problem(s) found.", file=sys.stderr)
    sys.exit(1)

print(f"OK — {checked} labelled kustomization(s) reach their target, and all "
      f"{controllers_checked} Flux-applied controllers have a placement.")
