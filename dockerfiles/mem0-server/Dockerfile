# mem0 fleet-memory server image — built from UPSTREAM SOURCE, not from the published
# mem0/mem0-api-server image.
#
# WHY NOT THE PUBLISHED IMAGE (this is the whole point of this file):
#   `mem0/mem0-api-server` has exactly ONE tag (`latest`), last pushed 2025-09-10, while
#   mem0ai/mem0's `server/` tree is actively security-patched — two large rounds since
#   (2026-07-30 "32 HIGH + 57 MEDIUM", 2026-08-21 "17 HIGH+CRITICAL"). Pinning that image
#   by digest froze us ~11 months behind a healthy repo. There is no server image release
#   channel upstream; releases are SDK-only. So we build what upstream's own
#   `server/Dockerfile` builds: python:3.12-slim + server/requirements.txt.
#
#   Second-order win, and the reason the Deployment moved: the published image is arm64
#   ONLY, which forced mem0 onto the OCI (arm64) node tier while its Postgres lives
#   on-prem — every query crossed the site-to-site VPN. python:3.12-slim is multi-arch,
#   so this image is amd64+arm64 and mem0 now runs beside its database on ff-vm1.
#
# Built + pushed by .github/workflows/docker-publish.yml to
# ghcr.io/magmamoose/mem0-server — NOT by hand. A laptop `docker push` needs a
# write:packages token and produces an artifact no one can reproduce. Cut a release with
# the `mem0-server-v*` tag prefix; a push to main rebuilds `:latest`.
#
# NOTE the namespace: this is the ORG namespace (matching nievah and the rest of the
# agent fleet), NOT the personal ghcr.io/calebsargeant/* one the other images in this
# directory use. That difference is load-bearing — the workflow authenticates the two
# with DIFFERENT credentials (built-in GITHUB_TOKEN for the org, the GHCR_TOKEN PAT for
# the personal namespace), so changing `registry_owner` alone is not sufficient.
#
# THREE PINS, and they must be moved together:
#   MEM0_REF        the upstream commit the server code comes from
#   mem0ai==        the SDK the server imports. Upstream's requirements.txt says
#                   `mem0ai>=0.1.48`, which floats to whatever PyPI has that day; the
#                   server and the SDK ship from the SAME repo, so a floating SDK against
#                   a pinned server is the one combination upstream never tests. 2.0.19 is
#                   the version in mem0ai/mem0's own pyproject.toml at MEM0_REF.
#   the base digest an INDEX digest (multi-platform), not a per-arch manifest digest — a
#                   per-arch digest silently breaks the other architecture's leg.
# Re-resolve the base with:
#   docker buildx imagetools inspect python:3.12-slim
#
# Suppressed findings (accepted risks, reviewed):
#   b03a748a / DS-0026  no HEALTHCHECK – Kubernetes ignores Docker HEALTHCHECK entirely;
#                       the Deployment has HTTP readiness + liveness probes. Adding one
#                       would pull curl/wget into the image — more attack surface, no effect.
#                       Trivy suppression is in the repo-root .trivyignore (DS-0026).
#                       KICS suppression is inline below (b03a748a).
# kics-scan disable=b03a748a-542d-44f4-bb86-9199ab4fd2d5

ARG PYTHON_BASE=python:3.12-slim@sha256:7a8b475003c4fe15a2cd4e55e5cfc2f3560bdc9333d624f24cdd6d4340fd7a17

# --- stage 1: fetch the upstream server tree at a fixed commit -----------------------
#checkov:skip=CKV_DOCKER_7:image pinned by digest via PYTHON_BASE ARG; tag is 3.12-slim not latest
FROM ${PYTHON_BASE} AS source

# mem0ai/mem0 @ main, 2026-08-24. Bump WITH the mem0ai pin below.
ARG MEM0_REF=39bc02330563764e7d4465f1ecff5f002d94da1a

# DL3008 (pin apt versions): deliberately not pinned. This stage is thrown away — nothing
# from it reaches the runtime image except the checked-out source — and a pinned Debian
# package version breaks the build the moment the base image's snapshot moves on.
# The `rm -rf` at the end drops what we do not ship: the Next.js admin dashboard (not
# deployed) and the local-dev build files. Everything else under server/ is imported or
# read at runtime. The two `test` lines fail the build loudly if a future MEM0_REF moves
# the server tree, instead of producing an image whose CMD cannot find main.py.
# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/* \
    && git init -q /src \
    && git -C /src remote add origin https://github.com/mem0ai/mem0.git \
    && git -C /src fetch -q --depth 1 origin "${MEM0_REF}" \
    && git -C /src checkout -q FETCH_HEAD \
    && test -f /src/server/main.py \
    && test -d /src/server/alembic \
    && rm -rf /src/.git \
    && rm -rf /src/server/dashboard /src/server/docker-compose.yaml \
              /src/server/dev.Dockerfile /src/server/Dockerfile /src/server/Makefile \
              /src/server/scripts /src/server/.env.example

# --- stage 2: runtime ----------------------------------------------------------------
#checkov:skip=CKV_DOCKER_7:image pinned by digest via PYTHON_BASE ARG; tag is 3.12-slim not latest
FROM ${PYTHON_BASE}

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /app

COPY --from=source /src/server/requirements.txt /tmp/requirements.txt

# One pip invocation so the resolver sees our pins AND upstream's constraints together;
# two invocations would let the second silently move what the first installed.
#
# psycopg[binary]: upstream's requirements ask for bare `psycopg`, which needs libpq on
# the system. python:3.12-slim has no libpq, so without the `binary` extra the pgvector
# store fails at import — the one dependency upstream's own Dockerfile gets away with
# only because nothing else in their compose path exercises it early.
RUN pip install --no-cache-dir \
        -r /tmp/requirements.txt \
        "mem0ai==2.0.19" \
        "psycopg[binary,pool]==3.3.4" \
    && rm -f /tmp/requirements.txt

COPY --from=source /src/server/ /app/

USER 65534

EXPOSE 8000

# No --reload (upstream's Dockerfile carries it; it is a dev flag: it spawns a file
# watcher and a reloader parent process, and needs a writable filesystem).
# Migrations are NOT run here — the Deployment runs `alembic upgrade head` in an
# initContainer so a crash-looping migration is visible as its own container status
# rather than as a mysterious app restart.
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
