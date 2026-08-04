# OpenFOAM in a container, as an Open Job Description job

An [Open Job Description](https://github.com/OpenJobDescription) job that solves an OpenFOAM
tutorial case inside the [`ubuntu-cpu`](../ubuntu-cpu/) image, using the `WRAP_ACTIONS` and `EXPR`
extensions to put the simulation in a container without the job template knowing anything about
containers.

The job template describes a CFD run. The wrap environment describes a container. They are separate
files on purpose: the same job runs unchanged on a host with OpenFOAM already sourced, or on a farm
where the container comes from a queue environment.

These templates are the CFD counterpart of the [MoonRay templates](../../moonray/templates/), and
the two are deliberately near-identical in shape. The difference is what the hooks are used for.
MoonRay is one command producing one image; a CFD run is mesh once, solve many, post-process once,
which is exactly the three-hook structure `WRAP_ACTIONS` provides.

## Files

| File | Purpose |
|---|---|
| `openfoam-solve-job.yaml` | The job. `EXPR` only — no mention of docker. |
| `local-docker-wrap-env.yaml` | Environment template with the `WRAP_ACTIONS` hooks that run each action in a container on this workstation. |
| `run-simulation.sh` | Runs the job with the Python CLI, the Rust CLI, or both, and checks the artifacts. |
| `.gitignore` | Keeps `sessions/` out of git. |

## Prerequisites

* Docker, with the `openfoam-ubuntu` image built from the sibling sample:

  ```console
  cd ../ubuntu-cpu
  docker build --platform linux/amd64 -t openfoam-ubuntu .
  ```

  That build is an `apt install`, not a compile, and takes a few minutes. See its
  [README](../ubuntu-cpu/README.md).

* An `openjd` CLI on `PATH` — either
  [openjd-cli](https://github.com/OpenJobDescription/openjd-cli) (Python) or
  [openjd-rs](https://github.com/OpenJobDescription/openjd-rs) (Rust). Both are supported and
  produce identical container invocations.

Nothing else. Unlike the MoonRay sample there is no scene download: the tutorial cases ship inside
the image, under `$FOAM_TUTORIALS`.

## Quick start

```console
./run-simulation.sh rust      # solve with the Rust openjd CLI, from $RUST_BIN
./run-simulation.sh python    # solve with the Python openjd-cli, from $VENV/bin
./run-simulation.sh path      # use whichever openjd is already on PATH
./run-simulation.sh           # python then rust, one after the other
```

`python` and `rust` look in the source-checkout locations in the table below, which suits a machine
with both built from source; `path` is for a normally installed CLI. Each run prints and logs the
`openjd` it resolved and its version, so a case directory can always be traced back to the CLI that
produced it. A missing or mislocated CLI fails immediately with the variable to set, rather than
surfacing as `openjd: command not found` from inside a session.

Everything lands under `sessions/`:

```
sessions/cases/<impl>/base/                    the cloned, meshed case shared by every task
sessions/cases/<impl>/nu-<value>/              one solved case per task, with VTK/
sessions/output/<impl>-nu-<value>-velocity.png velocity field of each case
sessions/output/<impl>-centreline.png          one graph comparing all three cases
sessions/output/<impl>-summary.txt             the run summary
sessions/logs/solve-<impl>.log                 the session log
```

The PNGs are the pictures of the run. The `VTK/` directories hold the same data for
[ParaView](https://www.paraview.org/) on the host, if you want to explore it rather than glance at
it.

Overrides, as environment variables:

| Variable | Default | Meaning |
|---|---|---|
| `IMAGE` | `openfoam-ubuntu` | Image to run |
| `TUTORIAL` | `incompressible/icoFoam/cavity/cavity` | Case under `$FOAM_TUTORIALS` to clone |
| `SOLVER` | `icoFoam` | Solver to run; must match `TUTORIAL` |
| `END_TIME` | `10` | Simulated seconds, overriding the tutorial's `endTime` |
| `DOCKER_USER` | invoking user | `docker --user` value |
| `KEEP_SESSIONS` | `1` | Pass `--preserve` to keep session dirs |
| `VENV` | `~/work/openjd/.venv` | Venv holding the Python `openjd-cli` |
| `RUST_BIN` | `~/work/openjd/openjd-rs/target/release` | Directory holding the Rust `openjd` |

## The simulation

The default case is the **lid-driven cavity**, OpenFOAM's hello-world: a square box of fluid with
the top wall sliding sideways at 1 m/s, dragging the fluid into a single recirculating vortex. It is
a 20 × 20 × 1 mesh — 400 cells — solved by `icoFoam`, the transient incompressible laminar solver,
over 0.5 s in 100 time steps. Each solve takes about a tenth of a second.

The job runs it three times as a **Reynolds number sweep**, one task per kinematic viscosity:

| Task | `nu` (m²/s) | Reynolds number |
|---|---|---|
| `nu-0.01` | 0.01 | 10 |
| `nu-0.002` | 0.002 | 50 |
| `nu-0.001` | 0.001 | 100 |

with `Re = U·L/nu` for the 1 m/s lid and the 0.1 m cavity. Viscosity is swept rather than lid
velocity because it leaves the Courant number alone, so every task stays stable at the tutorial's
fixed time step. Raising the lid speed instead would push `Co` past 1 and the later tasks would need
a smaller `deltaT` to stay stable.

100 is the top of the range on purpose: it is the lowest case in the standard
[Ghia benchmark](https://doi.org/10.1016/0021-9991(82)90058-4), and the 20 × 20 tutorial mesh
resolves it acceptably. Higher Reynolds numbers need a finer or graded mesh — the `cavityGrade`
tutorial — before the answer means much.

**The job also overrides `endTime`,** to 10 s from the tutorial's 0.5 s. That override is not
incidental: the sweep is meaningless at 0.5 s. Viscous momentum diffuses across the cavity on a timescale of
`L²/nu`, which is 1 s to 10 s for these viscosities, so at 0.5 s all three cases are still in the
same early transient and their velocity profiles lie exactly on top of each other. Ten seconds is
past that for every case. It costs about 1.3 s of solver time per case.

### Other cases

`TUTORIAL` and `SOLVER` accept any tutorial whose entire setup is `blockMesh` plus the solver, and
which has an `nu` entry in `constant/transportProperties` for the sweep to modify. The
backward-facing step is a good second one:

```console
TUTORIAL=incompressible/simpleFoam/pitzDaily SOLVER=simpleFoam ./run-simulation.sh rust
```

12,225 cells, steady-state, and the sweep shows up in the iteration count rather than the physics —
`simpleFoam` converges in 96, 135 and 182 iterations as viscosity falls, since less diffusion means
slower convergence.

Cases needing more than `blockMesh` will not work unmodified. `damBreak`, for example, also needs
`setFields` to initialise the water column, and `motorBike` needs `snappyHexMesh` — both would mean
extending the environment's `onEnter`.

## The plots

`foamToVTK` writes data, not pictures, so the environment's `onExit` finishes by running
`foam-plot` — a small matplotlib tool baked into the image, documented in the
[image README](../ubuntu-cpu/README.md#turning-vtk-output-into-pictures). Four PNGs land in
`sessions/output/`:

**`<impl>-nu-<value>-velocity.png`**, one per case: filled contours of velocity magnitude with
streamlines over them. Across the sweep the three plots show the textbook result — at Re 10 the core
sits high, pinned near the moving lid by viscosity; by Re 100 it has migrated toward the geometric
centre and a weak corner vortex appears at the bottom right.

**`<impl>-centreline.png`**, one per run: horizontal velocity along the vertical centreline, one line
per case. That graph is the [Ghia benchmark](https://doi.org/10.1016/0021-9991(82)90058-4)
comparison, and the reason the sweep is worth running as a job at all — three tasks, one graph.

Note where each is produced. The field plots could equally be drawn by the task that solved the
case, but the centreline graph cannot: a task only sees its own case directory. Drawing both in
`onExit` keeps them together, and it is what the third wrap hook is for.

`foam-plot` handles 2D cases only and refuses a 3D mesh rather than silently flattening it, so
pointing `TUTORIAL` at something 3D solves fine but fails at the plotting step.

## Running it by hand

`run-simulation.sh` is a convenience wrapper. The underlying invocation is:

```console
openjd run openfoam-solve-job.yaml \
    --environment local-docker-wrap-env.yaml \
    --step Solve \
    -p SessionsDir="$PWD/sessions" \
    -p ContainerMount=/mnt/session \
    -p RunPrefix=rust
```

## How it works

`WRAP_ACTIONS` lets one environment replace the lifecycle actions of everything inside it. Each of
the three hooks — `onWrapEnvEnter`, `onWrapTaskRun`, `onWrapEnvExit`, which must all be defined
together — receives the action it replaced through `WrappedAction.*` variables, and here re-runs it
with `docker run`.

All three do real work in this sample:

| Job action | Wrap hook | What runs in the container |
|---|---|---|
| `FoamCase` `onEnter` | `onWrapEnvEnter` | `foamCloneCase` the tutorial, then `blockMesh` |
| `Solve` `onRun` (×3) | `onWrapTaskRun` | copy the meshed case, set `nu`, run `icoFoam` |
| `FoamCase` `onExit` | `onWrapEnvExit` | `foamToVTK` each case, write the summary, plot the PNGs |

`FoamCase` is a `jobEnvironments` entry in the job template. Because an external
`--environment` is entered *outside* the job's own environments, `FoamCase`'s `onEnter` and
`onExit` are themselves intercepted by the wrap hooks — which is the only reason `blockMesh` and
`foamToVTK` are found at all. That nesting order is what makes "mesh once, solve many" expressible
without the job template mentioning a container.

So the job's task `onRun`:

```yaml
command: bash
args: [-c, "…cp -a base nu-0.01; foamDictionary -entry nu -set 0.01 …; icoFoam …"]
```

becomes, at run time:

```console
docker run --rm --platform linux/amd64 --user <uid>:<gid> \
    -e HOME=/tmp -v <templates>/sessions:/mnt/session openfoam-ubuntu \
    'env  bash -c '"'"'…the script, quoted verbatim…'"'"''
```

Three details in that command are load-bearing:

* **One argument after the image name.** The image's `ENTRYPOINT` is `bash -lc`, which takes the
  whole command as a single string and — being a login shell — is what sources
  `/etc/profile.d/openfoam.sh` and puts the solvers on `PATH`. The hook composes one string rather
  than separate argv entries.
* **`repr_sh()`**, from `EXPR`, shell-quotes the forwarded command and args so metacharacters,
  spaces and quotes reach the process verbatim instead of being interpreted by that login shell.
  That matters more here than in the MoonRay sample, where the forwarded action is a flat argv list;
  here it is a multi-line bash script.
* **`env` prefix** applies any session-defined variables (`WrappedAction.Environment`) inside the
  container. With none defined the list is empty and `env` is a passthrough.

`EXPR` also supplies the `let` bindings that build the in-container paths once, from
`Task.Param.Viscosity`.

The wrap environment's own `onEnter`/`onExit` run on the **host**, not in a container — a wrap
environment's own lifecycle is never intercepted by its own hooks. `onEnter` uses that to check the
image exists up front, so a missing image fails once with a clear message instead of once per task.

## Notes and gotchas

**No `--cap-add` needed.** The MoonRay sample requires `--cap-add SYS_NICE` because MoonRay binds
NUMA memory with `mbind(2)`, which Docker's default seccomp profile blocks. OpenFOAM has no such
requirement and runs under the default profile.

**`-e HOME=/tmp` is not cosmetic.** OpenFOAM's `etc/bashrc` derives `WM_PROJECT_USER_DIR` from
`$HOME`, and Docker sets `HOME=/` for a uid with no `/etc/passwd` entry. Pointing it at `/tmp`
keeps anything that writes there working.

**One harmless symptom when running non-root.** `docker --user` with a uid that has no entry in the
image's `/etc/passwd` leaves `$USER` empty and makes `whoami` fail. Serial OpenFOAM does not care.
Set `DOCKER_USER=0:0` to run as root and silence it, at the cost of root-owned files in
`sessions/`.

**Each task copies the mesh.** `cp -a base nu-<value>` per task looks wasteful for a 400-cell mesh,
but it is what makes the tasks independent: no two tasks write the same files, so they can be
scheduled on separate hosts. On a real farm the base case would come from shared storage or from
job attachments instead of a bind mount.

**Embedded files do not work here.** The obvious way to ship a multi-line script into a task is
OpenJD's `embeddedFiles`, referenced as `{{ Task.File.Run }}`. That resolves to a *host* path under
the session working directory, which is not a valid path inside the container, so the task would
fail with "No such file or directory". That is why the scripts are inline `bash -c` arguments. A
wrap environment could bind mount the session directory at its own host path in addition to
`ContainerMount` to make host paths resolve, at the cost of a second mount of the same directory.

**Session directories.** Neither CLI exposes a session-directory flag; both derive the session root
from the system temp dir on POSIX. `run-simulation.sh` therefore sets `TMPDIR` to `sessions/`, so
session working directories appear as `sessions/OpenJD/…` rather than in `/tmp`. The whole
`sessions/` directory is what gets bind mounted, which is how output gets back to the host.

**Parameters shared across the two templates.** `ContainerMount` is declared in both files with the
same type and default. That is legal — the CLI merges job and environment template parameter
definitions into one parameter space — and it means one `-p ContainerMount=…` moves the mount target
and the job's paths together instead of letting them drift. It is also why `-p SessionsDir=…` works
at all: `SessionsDir` is declared by the *environment* template, not the job.

**Serial only.** The image ships an MPI stack, so a parallel version of this job would add
`decomposePar` to the environment's `onEnter` and run `mpirun -np N icoFoam -parallel` in the task.
Left out here to keep the sample readable; see the
[image README](../ubuntu-cpu/README.md#notes-and-gotchas) for the MPI-as-non-root caveat.

## Verified run

Both implementations, on a 16-core x86_64 Linux host with docker 25.0, OpenFOAM v2512:

```
IMPL     RESULT  SECONDS   CASES  PLOTS  LOG
python   PASS         15       3      4  sessions/logs/solve-python.log
rust     PASS         15       3      4  sessions/logs/solve-rust.log
```

`openjd-cli 0.7.5.post21+g4e9a38421` (Python) and the Rust `openjd` built from `openjd-rs`. Of those
15 seconds, about 4 are solver time (1.3 s per case) and the rest is five container starts — one
mesh, three solves, one post-process — plus matplotlib's import and four PNG renders.

`diff -r -x 'log.*'` between the two runs' case trees reports **no differences**: all 164 data
files — the mesh, every solved field, and the VTK output — are byte-identical, and so are all four
PNGs. The only files that differ are OpenFOAM's own `log.*`, in the header timestamp, the container
hostname, the case path and the per-step `ExecutionTime`. So the wrap environment behaves the same
under both implementations.

Each run produced:

| Property | Value |
|---|---|
| Mesh | 400 cells, 882 points, 1,640 faces |
| Cases solved | 3 (`nu-0.01`, `nu-0.002`, `nu-0.001`) |
| Time directories per case | 6 (`0` through `10`, written every 2 s) |
| Fields per written time | `U`, `p`, `phi` (`0/` holds only the `U` and `p` initial conditions) |
| VTK output per case | 1 time step (`-latestTime`), as `.vtu` plus boundary `.vtp` |
| Plots | 3 velocity fields at ~250 KB each, 1 centreline graph at ~60 KB |
| Total | 164 data files, 5.6 MB per run |
