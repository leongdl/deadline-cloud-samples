# OpenFOAM containers

Container samples for running [OpenFOAM](https://www.openfoam.com/), the open-source computational
fluid dynamics toolbox, on the CPU.

| Sample | What it demonstrates | Start here when |
|---|---|---|
| [Ubuntu 24.04 CPU image](ubuntu-cpu/) | Installing OpenFOAM from the [official openfoam.com apt repository](https://www.openfoam.com/download/openfoam-installation-on-linux), plus a headless plotting tool | You want a working OpenFOAM container in a couple of minutes |
| [Open Job Description templates](templates/) | Running a CFD simulation as an OpenJD job, with `WRAP_ACTIONS` putting each action in the container | You want to see mesh, solve and post-process driven as a farm job |

Nothing is compiled: OpenCFD publishes prebuilt packages, so the image build is an `apt install`
that finishes in a couple of minutes. The result runs as a normal unprivileged container, with no
systemd and no `--privileged` requirement.

Both samples end in PNGs, not just data. OpenFOAM's `foamToVTK` writes files for ParaView, which is
not much use on a headless worker, so the image carries a small matplotlib tool that draws velocity
fields and comparison graphs with no OpenGL context and no ParaView — see
[Turning VTK output into pictures](ubuntu-cpu/README.md#turning-vtk-output-into-pictures).

These samples are the CFD counterpart of the [MoonRay sample](../moonray/), and the two are
deliberately parallel (same wrap environment shape, same run-script conventions) so the differences
stand out: a packaged install against a source build, and a mesh/solve/post-process pipeline against
a single render command.

## Where to get the simulation cases

Nothing to download. OpenFOAM ships its full tutorial tree inside the package, at
`$FOAM_TUTORIALS` (`/usr/lib/openfoam/openfoam<VERSION>/tutorials`). In v2512 that is 556 cases,
covering incompressible and compressible flow, multiphase, combustion, heat transfer,
electromagnetics and more.

The samples default to the **lid-driven cavity**
(`incompressible/icoFoam/cavity/cavity`), OpenFOAM's hello-world: a square box of fluid with the top
wall sliding sideways, 400 cells, solved in under a tenth of a second.

`foamCloneCase` is the supported way to take a copy — it clones just the case definition, leaving
the read-only tutorial tree untouched.

See [ubuntu-cpu/README.md](ubuntu-cpu/README.md) for the exact commands to solve a case by hand, and
[templates/README.md](templates/README.md) to run it as a job.
