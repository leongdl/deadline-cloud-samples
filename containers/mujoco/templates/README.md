# Shadow Hand parameter sweep as an OpenJD job

An [Open Job Description](https://github.com/OpenJobDescription) job that sweeps two Shadow Hand
physics parameters, running each combination inside the [`rocky9-cpu`](../rocky9-cpu/) image via the
`WRAP_ACTIONS` and `EXPR` extensions, and rendering frames for each.

The sweep is the step's parameter space, not a loop in a script. Two task parameters with two values
each give the cross product — four tasks, four independent simulations. Widening the sweep is
editing a `range`.

## Files

| File | Purpose |
|---|---|
| `mujoco-hand-sweep-job.yaml` | The job. `EXPR` only — no mention of docker. |
| `local-docker-wrap-env.yaml` | Environment template with the `WRAP_ACTIONS` hooks that run each task in a container on this workstation. |
| `run-sweep.sh` | Runs the sweep with the Python CLI, the Rust CLI, or both, and verifies the artifacts. |
| `summarize_metrics.py` | Prints one row per combination from the `metrics.json` files. |

## Prerequisites

* Docker, with the `mujoco-rocky9` image built from the sibling sample:

  ```console
  cd ../rocky9-cpu
  docker build --platform linux/amd64 -t mujoco-rocky9 .
  ```

* An `openjd` CLI on `PATH` — either
  [openjd-cli](https://github.com/OpenJobDescription/openjd-cli) (Python) or
  [openjd-rs](https://github.com/OpenJobDescription/openjd-rs) (Rust). Both are supported and
  produce identical results.

## Quick start

```console
./run-sweep.sh rust smoke   # one combination, to check the wiring
./run-sweep.sh rust         # the full 2x2
./run-sweep.sh              # python then rust
./run-sweep.sh path         # whichever openjd is already on PATH
```

Output lands in `sessions/output/<impl>/<combination>/`, one directory per sweep point:

```text
sessions/output/rust/damp4.0-kp2.0/
├── frames/damp4.0-kp2.0-0000.png   ... 0099.png
├── preview.gif
└── metrics.json
```

Overrides, as environment variables: `IMAGE`, `DURATION`, `FPS`, `DOCKER_USER`, `KEEP_SESSIONS`,
`VENV`, `RUST_BIN`.

## What is swept

| Task parameter | Values | Effect |
|---|---|---|
| `DampingScale` | 0.5, 4.0 | Multiplier on hinge-joint damping, across the hand's 24 finger and wrist DOFs. Low is loose and oscillatory, high is sluggish. |
| `StiffnessScale` | 0.5, 2.0 | Multiplier on the 20 position actuators' `kp`. Low underdrives the fingers so they never reach the commanded pose, high drives them hard into it. |

Job parameters set the run rather than the sweep: `Duration` (default 5.0 simulated seconds),
`Fps` (default 20), `Model`, `OutputSubdir`, `RunPrefix`, `ContainerMount`.

The hand is driven through an open/close cycle by interpolating each actuator between its
`ctrlrange` midpoint and its upper limit, so the motion stays inside every joint's declared range.

## Parameters are applied to the model, not the XML

This is the part worth copying. The obvious way to parameterise an MJCF is to parse it and rewrite
attributes by element name. On this model that silently does nothing:

* The compiled Shadow Hand has exactly **one named geom**, so matching geom names against
  `"fingertip"` or `"distal"` hits nothing.
* Its per-class joint damping lives in `<default>` blocks, not on the individual `<joint>` elements
  a naive walk would find — and 13 of the 45 `<joint>` elements *are* inside `<default>`, so editing
  all of them flattens the deliberate wrist-vs-finger split.
* `meshdir` and `<include>` resolve against the process working directory, so a
  parse-then-`from_xml_string` round trip only finds the meshes if you happen to be in the model's
  directory.

The failure mode is the dangerous one: the sweep runs, every task succeeds, every output looks
plausible, and all four combinations are identical.

So `mj_hand_sweep.py` compiles the model once and mutates `mjModel` — `dof_damping` for hinge DOFs
only, `actuator_gainprm`/`actuator_biasprm` for the position actuators — then **counts what it
touched and exits non-zero if the count is zero**. Each `metrics.json` records the before and after
values, so a no-op parameter is visible in the artifact rather than invisible.

## Verified run

Both implementations, on a 16-core x86_64 host, 5 simulated seconds per combination at 20 fps:

```
IMPL     RESULT  SECONDS   COMBINATIONS   FRAMES
python   PASS        108            4/4      400
rust     PASS        107            4/4      400
```

Per combination — 2500 steps each, identical between the two implementations:

| Combination | Frames | Steps | Peak flexion (rad) | Peak actuator force |
|---|---|---|---|---|
| `damp0.5-kp0.5` | 100 | 2500 | 1.620 | 0.781 |
| `damp0.5-kp2.0` | 100 | 2500 | 1.609 | 1.095 |
| `damp4.0-kp0.5` | 100 | 2500 | 1.392 | 1.321 |
| `damp4.0-kp2.0` | 100 | 2500 | 1.582 | 1.504 |

The four points are physically distinct — peak actuator force nearly doubles across the sweep — and
the frames differ visibly at the same time index.

## Notes

**Rendering is the cost, not the physics.** 2500 simulation steps take well under a second; the 100
rendered frames are most of the ~22 s per combination, because rendering is software (llvmpipe). Drop
`FPS` for a faster sweep, or raise it for smoother previews.

**Friction is not swept, deliberately.** Contact friction is the obvious third axis, and the scene
does put a free-floating ellipsoid in the palm, so it would have an effect. It is left out to keep
the sweep two-dimensional and its parameters independent of contact state.

**Session directories.** Neither CLI exposes a session-directory flag; both derive the session root
from the system temp dir on POSIX, so `run-sweep.sh` sets `TMPDIR` to `sessions/`. That whole
directory is what gets bind mounted, which is how output reaches the host.

**Shared parameters.** `ContainerMount` is declared in both templates with the same type and
default. The CLI merges job and environment template parameter definitions into one space, so one
`-p ContainerMount=…` moves the mount target and the in-container paths together. It is also why
`-p SessionsDir=…` works: `SessionsDir` is declared by the *environment* template.
