# MuJoCo containers

Container samples for running [MuJoCo](https://github.com/google-deepmind/mujoco), Google
DeepMind's physics engine, on the CPU with headless offscreen rendering.

| Sample | What it demonstrates | Start here when |
|---|---|---|
| [Rocky Linux 9 CPU image](rocky9-cpu/) | Installing MuJoCo from wheels, with software EGL rendering and the Shadow Hand and puzzle cube models baked in | You want a MuJoCo image, or a starting point for a simulation workload |
| [Hand parameter sweep job](templates/) | Sweeping two physics parameters as an OpenJD task parameter space, rendering frames per combination in the container | You want to distribute a simulation sweep, or see WRAP_ACTIONS applied to a non-rendering workload |

Nothing is compiled. MuJoCo publishes manylinux wheels, so the image builds in about a minute —
unlike the [MoonRay](../moonray/) sample next door, whose source build takes hours.

## Simulation is not rendering

These samples exist because physics simulation fits Deadline Cloud's shape well: a sweep is an
embarrassingly parallel set of independent tasks, one per parameter combination, each writing its
own artifacts. That is the same shape as a frame range, so the same job primitives apply.

The difference is what a task produces. A render task's output is the image; a simulation task's
output is usually *data* — state trajectories, forces, contact events — with images as a
by-product for inspection. The sweep sample writes both: PNG frames plus a `metrics.json` per
combination.
