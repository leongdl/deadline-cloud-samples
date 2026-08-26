#!/usr/bin/env bash
#
# Sweep two Shadow Hand physics parameters through Open Job Description, with
# the Python openjd-cli, the Rust openjd CLI, or both.
#
# The job template carries no docker knowledge; local-docker-wrap-env.yaml
# supplies WRAP_ACTIONS hooks that re-run each action inside the mujoco-rocky9
# image with ./sessions bind mounted, so rendered frames and metrics come back
# out on the host.
#
# Which implementation runs is the first argument:
#   ./run-sweep.sh                # both, python first then rust
#   ./run-sweep.sh python         # openjd-cli   (Python) from $VENV/bin
#   ./run-sweep.sh rust           # openjd       (Rust)   from $RUST_BIN
#   ./run-sweep.sh path           # whichever openjd is already on PATH
#
# Add `smoke` as the second argument to run ONE combination instead of the full
# 2x2, which is the quick way to check the wiring:
#   ./run-sweep.sh rust smoke
#
# python and rust look in the checkout locations below, which suit a machine
# with both built from source. Use `path` if you installed one of them normally.
# Each run records the openjd it resolved, and its version, at the top of its
# log — so which implementation produced a given frame is never a guess.
#
# Environment overrides:
#   IMAGE=mujoco-rocky9        container image to run
#   DURATION=2.0               simulated seconds per combination, and clip length
#   FPS=20.0                   rendered frames per simulated second
#   DOCKER_USER=<uid>:<gid>    defaults to the invoking user
#   KEEP_SESSIONS=1            pass --preserve so session dirs survive (default 1)
#   VENV=...  RUST_BIN=...     where to find the python / rust openjd

set -u -o pipefail

TEMPLATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

JOB_TEMPLATE="$TEMPLATE_DIR/mujoco-hand-sweep-job.yaml"
WRAP_ENV="$TEMPLATE_DIR/local-docker-wrap-env.yaml"

# Session root. Everything mutable lives under here, and this whole directory is
# what gets bind mounted into the container. Not checked into git.
SESSIONS_DIR="$TEMPLATE_DIR/sessions"
OUTPUT_DIR="$SESSIONS_DIR/output"
LOG_DIR="$SESSIONS_DIR/logs"

IMAGE="${IMAGE:-mujoco-rocky9}"
CONTAINER_MOUNT="${CONTAINER_MOUNT:-/mnt/session}"
DURATION="${DURATION:-2.0}"
FPS="${FPS:-20.0}"
DOCKER_USER="${DOCKER_USER:-$(id -u):$(id -g)}"
KEEP_SESSIONS="${KEEP_SESSIONS:-1}"

VENV="${VENV:-$HOME/work/openjd/.venv}"
RUST_BIN="${RUST_BIN:-$HOME/work/openjd/openjd-rs/target/release}"

# One combination, used by `smoke`. Must be a point in the template's ranges.
SMOKE_TASK='[{"DampingScale": 0.5, "StiffnessScale": 0.5}]'

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
        python) dir="$VENV/bin" ; hint="set VENV=<path to the venv with openjd-cli installed>" ;;
        rust)   dir="$RUST_BIN" ; hint="set RUST_BIN=<openjd-rs>/target/release, or build it with: cargo build --release" ;;
        path)   dir=""          ; hint="install openjd-cli, or put the openjd-rs binary on PATH" ;;
        *)      die "resolve_openjd: unknown implementation '$impl'" ;;
    esac

    if [ -n "$dir" ]; then
        OPENJD_EXE="$dir/openjd"
        [ -x "$OPENJD_EXE" ] || die "no openjd executable at $OPENJD_EXE
    $hint
    or run ./run-sweep.sh path to use whichever openjd is on PATH"
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
    cd $(cd "$TEMPLATE_DIR/.." && pwd)/rocky9-cpu
    docker build --platform linux/amd64 -t $IMAGE ."

    [ -f "$JOB_TEMPLATE" ] || die "missing job template: $JOB_TEMPLATE"
    [ -f "$WRAP_ENV" ]     || die "missing wrap environment: $WRAP_ENV"

    mkdir -p "$OUTPUT_DIR" "$LOG_DIR"
}

# -------------------------------------------------------------------- sweep --
# $1 = impl label (python|rust|path), $2 = "smoke" for a single combination
sweep_with() {
    local impl="$1" mode="${2:-full}"
    local log="$LOG_DIR/sweep-$impl.log"
    local run_dir="$OUTPUT_DIR/$impl"

    resolve_openjd "$impl"
    local bindir="$OPENJD_DIR"

    # Note: bash 4.2 treats "${arr[@]}" on an empty array as an unbound variable
    # under `set -u`, hence the ${arr[@]+...} guards below.
    local preserve=()
    [ "$KEEP_SESSIONS" = "1" ] && preserve=(--preserve)

    local task_sel=()
    local expected=4
    if [ "$mode" = "smoke" ]; then
        task_sel=(--tasks "$SMOKE_TASK")
        expected=1
    fi

    rm -rf "$run_dir"

    note "$impl: using $OPENJD_EXE"
    note "$impl: version $OPENJD_VERSION"
    note "$impl: $mode sweep, ${DURATION}s per combination at ${FPS} fps -> $run_dir"

    # Record the resolved implementation at the top of the log, so a log or a
    # frame can always be traced back to the CLI that produced it.
    {
        echo "implementation: $impl"
        echo "openjd:         $OPENJD_EXE"
        echo "version:        $OPENJD_VERSION"
        echo "mode:           $mode (expecting $expected combination(s))"
        echo "duration:       ${DURATION}s at ${FPS} fps   image: $IMAGE"
        echo "started:        $(date -Is)"
        echo "----------------------------------------------------------------"
    } > "$log"

    # Neither CLI exposes a session-directory flag; both derive the session root
    # from the system temp dir on POSIX, so TMPDIR is what puts the session
    # working directories under ./sessions.
    local start end rc
    start=$(date +%s)
    (
        export TMPDIR="$SESSIONS_DIR"
        [ -n "$bindir" ] && PATH="$bindir:$PATH"
        [ -d "$VENV/bin" ] && PATH="$PATH:$VENV/bin"
        export PATH
        openjd run "$JOB_TEMPLATE" \
            --environment "$WRAP_ENV" \
            --step Sweep \
            -p "SessionsDir=$SESSIONS_DIR" \
            -p "ContainerMount=$CONTAINER_MOUNT" \
            -p "Image=$IMAGE" \
            -p "DockerUser=$DOCKER_USER" \
            -p "Duration=$DURATION" \
            -p "Fps=$FPS" \
            -p "RunPrefix=$impl" \
            ${task_sel[@]+"${task_sel[@]}"} \
            ${preserve[@]+"${preserve[@]}"} \
            --verbose
    ) >> "$log" 2>&1
    rc=$?
    end=$(date +%s)

    echo "EXIT:$rc SECONDS:$((end - start))" >> "$log"

    # A zero exit code is not proof the sweep ran. Every combination must have
    # produced a metrics.json, at least one frame, and a non-empty MP4.
    local combos frames clips
    combos=$(find "$run_dir" -name metrics.json 2>/dev/null | wc -l)
    frames=$(find "$run_dir" -name '*.png' 2>/dev/null | wc -l)
    clips=$(find "$run_dir" -name 'clip.mp4' -size +0 2>/dev/null | wc -l)

    if [ "$rc" -eq 0 ] && [ "$combos" -eq "$expected" ] \
       && [ "$clips" -eq "$expected" ] && [ "$frames" -gt 0 ]; then
        note "$impl: OK  $((end - start))s  $combos/$expected combinations, $frames frames, $clips clips"
        RESULTS+=("$impl|PASS|$((end - start))|$combos/$expected|$frames|$clips|$log")
    else
        note "$impl: FAILED  rc=$rc  $((end - start))s  $combos/$expected combinations, $frames frames, $clips clips  see $log"
        RESULTS+=("$impl|FAIL|$((end - start))|$combos/$expected|$frames|$clips|$log")
    fi
}

# ---------------------------------------------------------------------- main --
TARGET="${1:-both}"
MODE="${2:-full}"

case "$TARGET" in
    python|rust|path|both) ;;
    -h|--help)
        sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    *)
        die "unknown target '$TARGET' (expected python, rust, path, both, or --help)"
        ;;
esac

case "$MODE" in
    full|smoke) ;;
    *) die "unknown mode '$MODE' (expected full or smoke)" ;;
esac

preflight

RESULTS=()

case "$TARGET" in
    python) sweep_with python "$MODE" ;;
    rust)   sweep_with rust   "$MODE" ;;
    path)   sweep_with path   "$MODE" ;;
    both)
        sweep_with python "$MODE"
        sweep_with rust   "$MODE"
        ;;
esac

echo
printf '%-8s %-6s %8s %14s %8s %6s  %s\n' IMPL RESULT SECONDS COMBINATIONS FRAMES CLIPS LOG
failures=0
for row in ${RESULTS[@]+"${RESULTS[@]}"}; do
    IFS='|' read -r impl status secs combos frames clips log <<< "$row"
    printf '%-8s %-6s %8s %14s %8s %6s  %s\n' "$impl" "$status" "$secs" "$combos" "$frames" "$clips" "$log"
    [ "$status" = PASS ] || failures=$((failures + 1))
done

# Per-combination detail, straight out of the metrics each task wrote.
if [ -d "$OUTPUT_DIR" ]; then
    echo
    echo "Per-combination metrics:"
    find "$OUTPUT_DIR" -name metrics.json -print0 2>/dev/null \
        | sort -z \
        | xargs -0 -r python3 "$TEMPLATE_DIR/summarize_metrics.py" || true
fi

exit $((failures > 0))
