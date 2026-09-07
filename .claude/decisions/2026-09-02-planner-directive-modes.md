# The planner has two modes, and a directive FILE is the switch

Status: **accepted**
Date: 2026-09-02

Refines `2026-08-24-holmes-cluster-autonomy.md`, which gave Holmes a way to start the
conversation. This is about what it is allowed to say when it does.

## Context

Holmes can now be asked, unattended, what is wrong in the cluster, and its answer feeds the
planner — the one lane where Nievah invents work instead of reacting to it. That raised a
question worth recording, because it will be re-litigated otherwise:

> Should the `issue_planner` flag, built for the directive feature, share the same path as
> Hermes- and Holmes-triggered work?

Underneath it are three separate consents that had been blurring together:

| flag | grants |
|---|---|
| `issue_watch` | may plan an issue a human already filed |
| `issue_planner` | may invent issues, unattended |
| `cluster_evidence` | may ask Holmes about this repo |

Hermes-triggered work already uses `issue_watch` correctly: a person points at an existing
issue and a Slack approval still gates execution. `issue_planner` is the one that matters,
because work invented with nobody watching is not recoverable by a human noticing.

The fact that settles the design is one nobody had checked: **a missing directive is not an
error.** `load_directive` substitutes `DEFAULT_DIRECTIVE` and returns the source `"default"`.
`RUN_DIRECTIVE_INVALID` is for a *malformed* file only, deliberately, so a typo cannot
silently redirect a planner. So "no directive" was never an empty state — it was already a
generic standing instruction reading *"prefer defects with concrete evidence: a failing check,
an error in a log"*, which is exactly what a Holmes finding is.

## Options considered

**A. A fourth flag for cluster-originated work.** Rejected. With the fallback in place there
is nothing left for it to express: it would be `issue_planner` under another name, needing its
own exact-name check, its own tests, and its own way to be forgotten. Two flags meaning one
thing drift; one of them ends up inert and looks identical to working.

**B. Reuse `issue_planner`; switch behaviour on whether a directive FILE exists.** Chosen. The
modes are already structurally exclusive — a repo has a file or it does not — and
`directive_source` already existed, threaded through `_plan_project_locked` into the run
fingerprint. The design was half-built; it just had no consumer.

**C. Let a Holmes finding originate an issue outside the directive, under `issue_planner`.**
Rejected. That is a different trigger source — the cluster's state rather than written intent
— and `issue_planner`'s consent was given for "work derived from the directive I wrote".
Reusing it there widens a grant silently, which is `COMMON_MISTAKES` #22 moved from the
placement layer to the permission layer.

## Decision

| `directives/<owner>/<repo>.yml` | plans against | Holmes is asked |
|---|---|---|
| written | that file's goals | the goals, as ranking context |
| absent | `DEFAULT_DIRECTIVE` | the neutral question |

The three grants stay separate. `issue_planner` still requires `issue_watch` beside it, and
`cluster_evidence` remains an input permission rather than a licence to originate work.

**Goals RANK the findings; they do not FILTER them.** This is the load-bearing half and the
easiest to erode. Holmes returns at most three things, so a project that wrote down what it is
trying to do should get findings chosen for that — three slots spent on work it does not care
about are three slots wasted. But letting the directive decide what *counts as wrong* is a
different thing: a directive about test coverage would then suppress the node that is out of
memory, and the planner would be told the cluster is fine. A directive describes the work
somebody planned. It cannot describe the failure nobody predicted, which is the one worth
interrupting for. The prompt says so in as many words, and a test fails if that sentence is
ever tidied away.

Directive text *is* interpolated into the question, which `holmes.py` otherwise forbids. That
is allowed for the same reason `Directive.notes` reaches the planner verbatim: it comes from
the PR-reviewed admin repository, not from issue or pull-request prose. The rule is that
untrusted text must never COMPOSE an investigation, and reviewed operator configuration is not
that.

## Consequences

**`magmamoose/infra` is enrolled undirected.** `cluster-evidence-infra` gains `issue_watch`
and `issue_planner`, and **no directive file is written**. That absence is the configuration,
and it is the only part of it that does not live in `.github/nievah.yml` — which is precisely
why it is written down here. Writing a directive for infra later is a **mode change**, not an
addition.

Bounded by the deployed caps, which are keyed per repo and so take nothing from the other
planner projects: 3 issues per run, 6 per day, and the run is skipped entirely once 10
planner-filed issues are open, across `PLANNER_HOURS=6,8,10,12,14`.

The planner roster goes from two projects to three. The other two carry directives and are
unaffected apart from getting better-targeted Holmes answers. Which repos those are stays in
`.github/nievah.yml` in the private admin repo; this file is world-readable, and the design
does not need the names to be understood.

**A string across a module boundary is now a name.** `DIRECTIVE_SOURCE_DEFAULT` replaces the
`"default"` literal that `directive.py` and `worker.py` both held. Its test asserts the
*discrimination* — a missing file and a real one landing on opposite sides of the branch —
rather than comparing the constant to itself, which is the tautology the first draft shipped.

**Reversal.** Clear the two flags in `.github/nievah.yml`; it takes effect on the next fetch
with no deploy. To keep the planner but constrain it, write the directive file instead.
