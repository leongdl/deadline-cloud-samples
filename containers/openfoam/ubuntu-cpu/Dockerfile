# OpenFOAM (openfoam.com / OpenCFD release) on Ubuntu 24.04, installed from the
# official Debian/Ubuntu package repository:
# https://www.openfoam.com/download/openfoam-installation-on-linux
#
#   docker build --platform linux/amd64 -t openfoam-ubuntu .
#
# Unlike the sibling MoonRay sample, nothing is compiled here: OpenCFD publishes
# prebuilt .deb packages, so this build is an apt install and finishes in a few
# minutes rather than hours.
#
# The upstream one-liner is `curl -s https://dl.openfoam.com/add-debian-repo.sh
# | sudo bash`. That script is not used directly — piping a remote script into a
# shell inside a Dockerfile hides what is being run and makes the build
# unreproducible. The two steps it performs (import the signing key, write the
# apt source) are spelled out below instead, using the signed-by keyring form
# rather than the deprecated /etc/apt/trusted.gpg.d.

FROM ubuntu:24.04

SHELL ["/bin/bash", "-c"]

# Which OpenFOAM release to install, as the version number that appears in the
# package name (openfoam<VERSION>-default) and in the install path
# (/usr/lib/openfoam/openfoam<VERSION>). Pinned to a specific release so
# rebuilding later produces the same OpenFOAM.
#
# Available versions are the pool directories under
#   https://dl.openfoam.com/repos/deb/dists/noble/main/pool/
# named <VERSION>_<packaging date>. Override with, for example:
#   docker build --platform linux/amd64 \
#       --build-arg OPENFOAM_VERSION=2412 \
#       -t openfoam-ubuntu .
#
# Note this is the openfoam.com (OpenCFD/ESI) version series — v2506, v2512 —
# not the openfoam.org (OpenFOAM Foundation) series — 11, 12 — which is a
# separate fork with its own repository and its own solver names.
ARG OPENFOAM_VERSION=2512

# The apt suite name matches the base image's release codename. Kept as a build
# argument so changing the FROM line to another Ubuntu or Debian release only
# needs this changed alongside it; the repository publishes suites for bionic
# through resolute, and trixie/bookworm/bullseye for Debian.
ARG APT_SUITE=noble

# dl.openfoam.com redirects every request to a randomly chosen SourceForge
# mirror, and a mirror that is unreachable from the build network stalls until
# apt's default 120 s timeout:
#
#   E: Failed to fetch .../openfoam2512-common_2512.0-2_all.deb
#      Could not connect to cfhcable.dl.sourceforge.net:443 ... connection timed out
#
# A short timeout plus retries turns that into a few seconds lost and a
# different mirror on the next attempt. Set as apt configuration rather than as
# -o flags so it applies to `apt-get update` as well as to `apt-get install`,
# and so images built FROM this one inherit it.
RUN printf '%s\n' \
        'Acquire::Retries "10";' \
        'Acquire::http::Timeout "20";' \
        'Acquire::https::Timeout "20";' \
    > /etc/apt/apt.conf.d/99-openfoam-mirror-retries

# gnupg is needed to dearmor the signing key, curl to fetch it. Both are
# dropped again in the same layer once the repository is in place, so they do
# not linger in the image.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl gnupg \
    && curl -fsSL https://dl.openfoam.com/pubkey.gpg \
        | gpg --dearmor -o /usr/share/keyrings/openfoam.gpg \
    && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/openfoam.gpg]" \
            "https://dl.openfoam.com/repos/deb ${APT_SUITE} main" \
        > /etc/apt/sources.list.d/openfoam.list \
    && apt-get purge -y gnupg \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

# openfoam<VERSION>-default is the metapackage for a normal working install: the
# solvers and utilities, the tutorials, and an MPI stack for parallel runs.
# --no-install-recommends keeps ParaView and the X11 stack out, which are only
# useful with a display and would roughly double the image size.
#
# `hostname` and `bc` are not pulled in by the packages but are called by
# OpenFOAM's own shell tooling (RunFunctions, foamLog and friends); Ubuntu's
# minimal base image does not ship them.
#
# The loop is here because `apt-get update` exits 0 even when a source fails to
# download — it only warns "Some index files failed to download" — so chaining
# with && is not enough. When the OpenFOAM index is the one that failed, the
# build gets as far as `E: Unable to locate package openfoam2512-default`, which
# reads like a wrong package name rather than an unreachable mirror. Asking
# apt-cache whether the package is visible is the check that actually means the
# index arrived; each retry re-follows the redirect and lands on a new mirror.
#
# This is a ~600 MB download either way.
RUN pkg="openfoam${OPENFOAM_VERSION}-default" \
    && for attempt in 1 2 3 4 5; do \
        apt-get update || true; \
        if apt-cache show "$pkg" > /dev/null 2>&1; then break; fi; \
        echo "openfoam index unavailable (attempt ${attempt}/5), retrying" >&2; \
        sleep 5; \
    done \
    && if ! apt-cache show "$pkg" > /dev/null 2>&1; then \
        echo "could not reach the openfoam apt repository after 5 attempts" >&2; \
        exit 1; \
    fi \
    && apt-get install -y --no-install-recommends \
        "$pkg" \
        hostname \
        bc \
    && rm -rf /var/lib/apt/lists/*

# --- plotting -----------------------------------------------------------------
# foamToVTK writes data, not pictures. foam-plot (below) draws that data with
# matplotlib's Agg backend, a software rasteriser needing no OpenGL context and
# no X server.
#
# matplotlib goes in a virtual environment rather than through apt for two
# reasons. Ubuntu 24.04 is an externally managed Python, so a system-wide pip
# install needs --break-system-packages; and Ubuntu's python3-matplotlib depends
# on python3-scipy and python3-sympy, adding about 125 MB this uses none of. The
# wheel and its own dependencies come to about 210 MB.
#
# Deliberately NOT installed: python3-vtk9, which would make reading the .vtu
# files a one-liner but pulls in LLVM and mesa -- roughly 800 MB -- to link an
# OpenGL renderer Agg never calls. foam_plot.py parses the XML with the standard
# library instead. Also not installed: ParaView, whose pvbatch is the usual
# answer for OpenFOAM post-processing but costs about 400 MB and a Qt stack.
ARG MATPLOTLIB_VERSION=3.10.7
RUN apt-get update \
    && apt-get install -y --no-install-recommends python3-venv \
    && python3 -m venv /opt/foamplot \
    && /opt/foamplot/bin/pip install --no-cache-dir --disable-pip-version-check \
        "matplotlib==${MATPLOTLIB_VERSION}" \
    && rm -rf /var/lib/apt/lists/*

# The script's shebang points at /opt/foamplot/bin/python3, so it has to agree
# with the venv path above.
COPY scripts/foam_plot.py /usr/local/bin/foam-plot
RUN chmod +x /usr/local/bin/foam-plot

# Put the OpenFOAM environment on any login shell. Sourcing etc/bashrc is how
# OpenFOAM is always activated: it exports WM_PROJECT_DIR, FOAM_TUTORIALS and
# the ~80 other variables the solvers and shell functions rely on, and prepends
# the solver directory to PATH. Without it, `icoFoam` is simply not found.
#
# Ubuntu's /etc/profile sources /etc/profile.d/*.sh, and the ENTRYPOINT below is
# a login shell, so every command run in this container gets it.
RUN echo "source /usr/lib/openfoam/openfoam${OPENFOAM_VERSION}/etc/bashrc" \
        > /etc/profile.d/openfoam.sh

# Recorded so a running container can report exactly what it holds without
# having to parse paths back out of the environment.
RUN echo "${OPENFOAM_VERSION}" > /openfoam-version.txt

# Fail the build rather than the user: solve the real cavity tutorial, convert
# it, plot it, and assert the PNG is a plausible size. This exercises the whole
# chain -- blockMesh, icoFoam, foamToVTK, and the .vtu parser in foam-plot -- and
# takes a couple of seconds because the case is 400 cells.
#
# `source` is explicit because Docker RUN is not a login shell, so the
# profile.d snippet above does not apply here.
RUN source /etc/profile.d/openfoam.sh \
    && cd /tmp \
    && foamCloneCase "$FOAM_TUTORIALS/incompressible/icoFoam/cavity/cavity" /tmp/smoke > /dev/null \
    && cd /tmp/smoke \
    && blockMesh > /dev/null \
    && icoFoam > /dev/null \
    && foamToVTK -latestTime > /dev/null \
    && foam-plot field /tmp/smoke.png /tmp/smoke \
    && bytes=$(stat -c %s /tmp/smoke.png) \
    && if [ "$bytes" -lt 20000 ]; then \
        echo "build check: foam-plot produced a suspiciously small PNG (${bytes} bytes)" >&2; \
        exit 1; \
    fi \
    && echo "build check: solved, converted and plotted the cavity (${bytes} byte PNG)" \
    && rm -rf /tmp/smoke /tmp/smoke.png

# `bash -lc` matches the MoonRay sample and is what makes the profile.d snippet
# above take effect. It also means the whole command arrives as a single
# argument, which is why the wrap environment composes one string rather than
# separate argv entries.
#
# The default command reports what the image holds. There is no `foamVersion`
# executable in this release series — the version is carried in the environment
# that etc/bashrc exports.
ENTRYPOINT ["/bin/bash", "-lc"]
CMD ["echo \"OpenFOAM $WM_PROJECT_VERSION (API $FOAM_API), tutorials under $FOAM_TUTORIALS\""]
