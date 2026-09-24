# Hermes Agent image: upstream nousresearch/hermes-agent plus the `ddgs` package, which
# the bundled DuckDuckGo web search backend (plugins/web/ddgs) imports and upstream does
# not ship.
#
# WHY A DERIVED IMAGE: the running container cannot install it. /opt/hermes (source and
# venv) is root-owned and chmod a-w, the venv has no pip, and upstream sets
# HERMES_DISABLE_LAZY_INSTALLS=1, which turns off Hermes' own installer.
#
# EVERYTHING ELSE IS UPSTREAM'S. This file sets no USER, WORKDIR, ENTRYPOINT, CMD or ENV,
# so all of them are inherited unchanged. The inherited USER is root on purpose:
# s6-overlay's /init runs as PID 1, remaps the hermes user and chowns /opt/data, then
# drops every service to the hermes user (UID 10000 by default) with s6-setuidgid. That
# is also why the install needs no USER switch: the build already runs as root, and root
# writes through the a-w mode bits. If a future base ends as a non-root user, the RUN
# below fails on a permission error rather than quietly changing the runtime user.
#
# PINS (only the FROM line is bumped for you):
#   FROM   tag AND the INDEX digest (not the amd64 manifest digest, so an arm64 leg can
#          be added without re-pinning). Dependabot moves both.
#   ddgs   plus the two packages it brings that upstream lacks, primp and lxml. All
#          three are pinned because ddgs only sets floors (primp>=1.3.1) and primp 2.0 was
#          a rewrite. Its third dependency, click, is already in the venv.
# The install is constrained to a freeze of the venv taken just before it, so it can only
# ADD packages. If a later ddgs needs a different version of something upstream locked,
# the build fails instead of shipping a combination upstream never tested.
#
# Built and pushed by .github/workflows/docker-publish.yml to ghcr.io/magmamoose/hermes,
# linux/amd64 only. Release with a git tag of the upstream version plus a build number,
# e.g. hermes-v2026.6.19-1 (see the matrix entry there).
#
# Suppressed findings (accepted repo-wide, see DS-0026 in .trivyignore):
#   b03a748a / DS-0026  no HEALTHCHECK. Kubernetes ignores it; the Deployment has probes.
# kics-scan disable=b03a748a-542d-44f4-bb86-9199ab4fd2d5
#checkov:skip=CKV_DOCKER_3:s6-overlay's /init handles user remapping at runtime (UID 10000 via s6-setuidgid); build-time root is required to write through the venv's a-w mode bits
FROM nousresearch/hermes-agent:v2026.9.14@sha256:99641e57ec762c59e54cb44aa6746b7fc68c18b3c5ddb088af54234c613d9294

# The image's own uv (/usr/local/bin/uv), into the existing venv. The last command
# imports the module that loads primp's and lxml's native extensions, so a wheel that
# cannot load on this Python or glibc fails the build, not the first search.
RUN uv pip freeze --no-cache-dir --python /opt/hermes/.venv/bin/python --exclude-editable \
        > /tmp/upstream-venv.txt \
    && uv pip install --no-cache-dir --python /opt/hermes/.venv/bin/python \
        --constraints /tmp/upstream-venv.txt \
        ddgs==9.16.0 primp==2.0.1 lxml==6.1.3 \
    && rm -f /tmp/upstream-venv.txt \
    && /opt/hermes/.venv/bin/python -c "from ddgs.ddgs import DDGS"
