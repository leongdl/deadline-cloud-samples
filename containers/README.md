# AWS Deadline Cloud container samples

These samples provide Dockerfiles and related resources for building container images compatible with [AWS Deadline Cloud](https://aws.amazon.com/deadline-cloud/) worker environments.

## Sample index

This table covers the user-selectable container samples below `containers/`. Supporting scripts and image assets remain with their sample.

| Sample | What it demonstrates | Start here when |
|---|---|---|
| [AL2023 worker-equivalent image](al2023-deadline/) | Reproducing a point-in-time service-managed fleet package set on Amazon Linux 2023 | You need to test packages or software against worker-compatible system libraries |
| [Blender application container](blender/blender-aswf-ci-base/) | Packaging Blender, the Deadline Cloud adaptor, and GPU support in an application image | You want to render Blender workloads from a purpose-built container |
| [MoonRay application container](moonray/) | Compiling MoonRay from source for CPU rendering on Rocky Linux 9 | You want to render with MoonRay, or need a specific MoonRay revision |
| [MuJoCo application container](mujoco/) | Installing MuJoCo from wheels on Rocky Linux 9, and sweeping physics parameters as an OpenJD job | You want to run physics simulation workloads from a container |
| [OpenFOAM application container](openfoam/) | Installing OpenFOAM from packages on Ubuntu 24.04, and running a CFD simulation as an OpenJD job | You want to run computational fluid dynamics workloads from a container |

The worker-equivalent image is useful for local compatibility work and package builds. The Blender, MoonRay, MuJoCo, and OpenFOAM images are application-container examples; Blender includes its own deployment resources and instructions, MoonRay builds the renderer from source, and MuJoCo and OpenFOAM install from published wheels and packages respectively.

The MoonRay and OpenFOAM samples both include Open Job Description templates that use the `WRAP_ACTIONS` extension to run a job inside a container without the job template referring to containers at all.
