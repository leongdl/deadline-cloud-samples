#!/usr/bin/env bash
#
# Solve an OpenFOAM tutorial case through Open Job Description, once with the
# Python openjd-cli and once with the Rust openjd CLI.
#
# The job template carries no docker knowledge; local-docker-wrap-env.yaml
# supplies WRAP_ACTIONS hooks that re-run each action inside the openfoam-ubuntu
# image with ./sessions bind mounted, so the meshed case, the solver output and
# the VTK conversion all land back on the host.
#
# Unlike the sibling MoonRay sample there is nothing to download: the tutorial
# cases ship inside the image, under $FOAM_TUTORIALS.
#
# Which implementation runs is the first argument:
#   ./run-simulation.sh            # both, python first then rust
#   ./run-simulation.sh python     # openjd-cli   (Python) from $VENV/bin
#   ./run-simulation.sh rust       # openjd       (Rust)   from $RUST_BIN
#   ./run-simulation.sh path       # whichever openjd is already on PATH
#
# python and rust look in the checkout locations below, which suit a machine
# with both built from source. Use `path` if you installed one of them normally.
# Each run records the openjd it resolved, and its version, at the top of its
# log — so which implementation produced a given case is never a guess.
#
# Environment overrides:
#   IMAGE=openfoam-ubuntu      container image to run
#   TUTORIAL=...               case under $FOAM_TUTORIALS to clone
#   SOLVER=icoFoam             solver to run; must match TUTORIAL
#   END_TIME=10                simulated seconds, overriding the tutorial's endTime
#   DOCKER_USER=<uid>:<gid>    defaults to the invoking user
#   KEEP_SESSIONS=1            pass --preserve so session dirs survive (default 1)
#   VENV=...  RUST_BIN=...     where to find the python / rust openjd

set -u -o pipefail

TEMPLATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

JOB_TEMPLATE="$TEMPLATE_DIR/openfoam-solve-job.yaml"
WRAP_ENV="$TEMPLATE_DIR/local-docker-wrap-env.yaml"

# Session root. Everything mutable lives under here, and this whole directory is
# what gets bind mounted into the container. Not checked into git.
SESSIONS_DIR="$TEMPLATE_DIR/sessions"
CASES_DIR="$SESSIONS_DIR/cases"
OUTPUT_DIR="$SESSIONS_DIR/output"
LOG_DIR="$SESSIONS_DIR/logs"

IMAGE="${IMAGE:-openfoam-ubuntu}"
CONTAINER_MOUNT="${CONTAINER_MOUNT:-/mnt/session}"
TUTORIAL="${TUTORIAL:-incompressible/icoFoam/cavity/cavity}"
SOLVER="${SOLVER:-icoFoam}"
END_TIME="${END_TIME:-10}"
DOCKER_USER="${DOCKER_USER:-$(id -u):$(id -g)}"
KEEP_SESSIONS="${KEEP_SESSIONS:-1}"

VENV="${VENV:-$HOME/work/openjd/.venv}"
RUST_BIN="${RUST_BIN:-$HOME/work/openjd/openjd-rs/target/release}"

die() { echo "error: $*" >&2; exit 1; }
note() { echo "==> $*"; }

# ------------------------------------------------------- implementation pick --
# Resolve the openjd executable for one implementation, failing early and
# specifically rather than letting `openjd: command not found` surface from
# inside a session. Sets OPENJD_DIR (empty means "leave PATH alone"),
# OPENJD_EXE and OPENJD_VERSION.
resolve_openjd() {
    local impl="$1" dir="" hint=""

    case "$impl" in
        python) dir="$VENV/bin"  ; hint="set VENV=<path to the venv with openjd-cli installed>" ;;
        rust)   dir="$RUST_BIN"  ; hint="set RUST_BIN=<openjd-rs>/target/release, or build it with: cargo build --release" ;;
        path)   dir=""           ; hint="install openjd-cli, or put the openjd-rs binary on PATH" ;;
        *)      die "resolve_openjd: unknown implementation '$impl'" ;;
    esac

    if [ -n "$dir" ]; then
        OPENJD_EXE="$dir/openjd"
        [ -x "$OPENJD_EXE" ] || die "no openjd executable at $OPENJD_EXE
    $hint
    or run ./run-simulation.sh path to use whichever openjd is on PATH"
    else
        OPENJD_EXE="$(command -v openjd 2>/dev/null || true)"
        [ -n "$OPENJD_EXE" ] || die "no openjd found on PATH
    $hint"
    fi

    OPENJD_DIR="$dir"

    # openjd-cli implements --version; the Rust CLI currently does not, so fall
    # back to naming the binary rather than reporting nothing.
    OPENJD_VERSION="$("$OPENJD_EXE" --version 2>/dev/null | head -1)"
    [ -n "$OPENJD_VERSION" ] || OPENJD_VERSION="(no --version flag; openjd-rs does not implement one)"
}

# ---------------------------------------------------------------- preflight --
preflight() {
    command -v docker >/dev/null 2>&1 || die "docker not found on PATH"
    docker info >/dev/null 2>&1 || die "the docker daemon is not reachable"

    docker image inspect "$IMAGE" >/dev/null 2>&1 \
        || die "image '$IMAGE' not found. Build it first, from the sibling sample:
    cd $(cd "$TEMPLATE_DIR/.." && pwd)/ubuntu-cpu
    docker build --platform linux/amd64 -t $IMAGE ."

    [ -f "$JOB_TEMPLATE" ] || die "missing job template: $JOB_TEMPLATE"
    [ -f "$WRAP_ENV" ]     || die "missing wrap environment: $WRAP_ENV"

    mkdir -p "$CASES_DIR" "$OUTPUT_DIR" "$LOG_DIR"
}

# --------------------------------------------------------------------- solve --
# $1 = impl label (python|rust|path)
solve_with() {
    local impl="$1"
    local log="$LOG_DIR/solve-$impl.log"
    local summary="$OUTPUT_DIR/$impl-summary.txt"
    local case_root="$CASES_DIR/$impl"

    resolve_openjd "$impl"
    local bindir="$OPENJD_DIR"

    # Note: bash 4.2 (this host) treats "${arr[@]}" on an empty array as an
    # unbound variable under `set -u`, hence the ${arr[@]+...} guards below.
    local preserve=()
    [ "$KEEP_SESSIONS" = "1" ] && preserve=(--preserve)

    rm -f "$summary" "$OUTPUT_DIR/$impl"-*.png
    rm -rf "$case_root"

    note "$impl: using $OPENJD_EXE"
    note "$impl: version $OPENJD_VERSION"
    note "$impl: solving $TUTORIAL with $SOLVER to t=$END_TIME s  (log: $log)"

    # Record the resolved implementation at the top of the log, so a log or a
    # case directory can always be traced back to the CLI that produced it.
    {
        echo "implementation: $impl"
        echo "openjd:         $OPENJD_EXE"
        echo "version:        $OPENJD_VERSION"
        echo "tutorial:       $TUTORIAL   solver: $SOLVER   endTime: $END_TIME   image: $IMAGE"
        echo "started:        $(date -Is)"
        echo "----------------------------------------------------------------"
    } > "$log"

    # Neither CLI exposes a session-directory flag; both derive the session root
    # from the system temp dir on POSIX, so TMPDIR is what puts the session
    # working directories under ./sessions (as ./sessions/OpenJD/...).
    local start end rc
    start=$(date +%s)
    (
        export TMPDIR="$SESSIONS_DIR"
        # Put the chosen implementation first. For `path` there is nothing to
        # prepend. The venv's bin follows when it exists, so the bare `python`
        # some job fixtures spawn resolves the same way for every choice.
        [ -n "$bindir" ] && PATH="$bindir:$PATH"
        [ -d "$VENV/bin" ] && PATH="$PATH:$VENV/bin"
        export PATH
        openjd run "$JOB_TEMPLATE" \
            --environment "$WRAP_ENV" \
            --step Solve \
            -p "SessionsDir=$SESSIONS_DIR" \
            -p "ContainerMount=$CONTAINER_MOUNT" \
            -p "Image=$IMAGE" \
            -p "DockerUser=$DOCKER_USER" \
            -p "Tutorial=$TUTORIAL" \
            -p "Solver=$SOLVER" \
            -p "EndTime=$END_TIME" \
            -p "RunPrefix=$impl" \
            ${preserve[@]+"${preserve[@]}"} \
            --verbose
    ) >> "$log" 2>&1
    rc=$?
    end=$(date +%s)

    echo "EXIT:$rc SECONDS:$((end - start))" >> "$log"

    # A zero exit code is not proof the simulation happened — check the
    # artifacts. Every solved case must have a VTK directory and a field PNG,
    # there must be one centreline graph, and the summary written by the
    # environment's onExit must exist.
    local solved=0 vtk=0 pngs=0
    if [ -d "$case_root" ]; then
        solved=$(find "$case_root" -maxdepth 1 -type d -name 'nu-*' | wc -l)
        vtk=$(find "$case_root" -maxdepth 2 -type d -name VTK | wc -l)
    fi
    # -size +1k so a truncated or empty PNG does not count as a plot.
    pngs=$(find "$OUTPUT_DIR" -maxdepth 1 -name "$impl-*.png" -size +1k | wc -l)
    local want_pngs=$((solved + 1))

    if [ "$rc" -eq 0 ] && [ -s "$summary" ] && [ "$solved" -gt 0 ] \
        && [ "$vtk" -eq "$solved" ] && [ "$pngs" -eq "$want_pngs" ]; then
        note "$impl: OK  $((end - start))s  $solved cases, $vtk converted, $pngs plots"
        note "$impl: plots in $OUTPUT_DIR"
        RESULTS+=("$impl|PASS|$((end - start))|$solved|$pngs|$log")
    else
        note "$impl: FAILED  rc=$rc  $((end - start))s  cases=$solved vtk=$vtk pngs=$pngs (want $want_pngs)  see $log"
        RESULTS+=("$impl|FAIL|$((end - start))|$solved|$pngs|$log")
    fi
}

# ---------------------------------------------------------------------- main --
TARGET="${1:-both}"

case "$TARGET" in
    python|rust|path|both) ;;
    -h|--help)
        sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    *)
        die "unknown target '$TARGET' (expected python, rust, path, or both)"
        ;;
esac

preflight

RESULTS=()

case "$TARGET" in
    python) solve_with python ;;
    rust)   solve_with rust ;;
    path)   solve_with path ;;
    both)
        solve_with python
        solve_with rust
        ;;
esac

echo
printf '%-8s %-6s %8s %7s %6s  %s\n' IMPL RESULT SECONDS CASES PLOTS LOG
failures=0
for row in ${RESULTS[@]+"${RESULTS[@]}"}; do
    IFS='|' read -r impl status secs cases pngs log <<< "$row"
    printf '%-8s %-6s %8s %7s %6s  %s\n' "$impl" "$status" "$secs" "$cases" "$pngs" "$log"
    [ "$status" = PASS ] || failures=$((failures + 1))
done

exit $((failures > 0))
