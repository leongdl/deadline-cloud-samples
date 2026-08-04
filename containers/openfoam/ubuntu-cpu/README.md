# OpenFOAM on Ubuntu 24.04 (CPU, packaged install)

This sample installs [OpenFOAM](https://www.openfoam.com/) — the open-source computational fluid
dynamics toolbox — into an [Ubuntu 24.04](https://hub.docker.com/_/ubuntu) container from the
official [openfoam.com Debian/Ubuntu package repository](https://www.openfoam.com/download/openfoam-installation-on-linux).

Nothing is compiled. OpenCFD publishes prebuilt `.deb` packages, so this build is an `apt install`
that finishes in a couple of minutes, against the hours the sibling
[MoonRay source build](../../moonray/rocky9-cpu/) needs. The resulting image runs as a plain
unprivileged container: no systemd, no `--privileged`, no extra capabilities.

## Which OpenFOAM?

"OpenFOAM" names two actively maintained forks with different version schemes, different
repositories, and in places different solver names. This sample uses the **openfoam.com** line:

| | openfoam.com | openfoam.org |
|---|---|---|
| Maintainer | OpenCFD / ESI Group | OpenFOAM Foundation |
| Versions | `v2506`, `v2512`, … (year + half) | `11`, `12`, … |
| apt repository | `dl.openfoam.com/repos/deb` | `dl.openfoam.org/ubuntu` |
| Install prefix | `/usr/lib/openfoam/openfoam<VERSION>` | `/opt/openfoam<VERSION>` |

The two are not drop-in substitutes. openfoam.org 11 and later replaced the individual solver
executables with a single `foamRun -solver <module>`, so `icoFoam` — which the job template in
[`../templates/`](../templates/) defaults to — does not exist there. Switching forks means changing
the repository, the `source .../etc/bashrc` line, and the job's `Solver` parameter.

## Prerequisites

* Docker (or a compatible CLI such as `finch`; substitute `finch` for `docker` below)
* A 321 MB download, and 1.5 minutes on a warm network. Add ~4 minutes per retried mirror;
  see [Notes and gotchas](#notes-and-gotchas)
* ~5 GB of free disk for intermediate layers; the finished image is about 1.76 GB

## Build

```console
docker build --platform linux/amd64 -t openfoam-ubuntu .
```

### Choosing an OpenFOAM version

`OPENFOAM_VERSION` selects the release, as the number that appears in the package name and the
install path. It defaults to `2512`.

Available versions are the pool directories under
[`dl.openfoam.com/repos/deb/dists/noble/main/pool/`](https://dl.openfoam.com/repos/deb/dists/noble/main/pool/),
named `<VERSION>_<packaging date>`.

```console
docker build --platform linux/amd64 \
    --build-arg OPENFOAM_VERSION=2412 \
    -t openfoam-ubuntu-2412 .
```

`APT_SUITE` is the apt suite name, which must match the base image's release codename — `noble`
for Ubuntu 24.04. Change both together if you move the `FROM` line; the repository publishes
suites from `bionic` through `resolute`, plus `bullseye`, `bookworm` and `trixie` for Debian.

### What gets installed

`openfoam<VERSION>-default` is the metapackage for a normal working install: solvers, utilities,
the tutorial tree, and an MPI stack for parallel runs. `--no-install-recommends` keeps ParaView
and the X11 stack out, which are only useful with a display and would roughly double the image
size.

Two extras are added by hand — `hostname` and `bc` — because OpenFOAM's own shell tooling
(`RunFunctions`, `foamLog` and friends) calls them and Ubuntu's minimal base image does not ship
them.

On top of that goes a small plotting tool, `foam-plot`, and a matplotlib virtual environment for it
to run in. See [Turning VTK output into pictures](#turning-vtk-output-into-pictures).

## Verify

The default command reports what the image holds:

```console
$ docker run --rm --platform linux/amd64 openfoam-ubuntu
OpenFOAM v2512 (API 2512), tutorials under /usr/lib/openfoam/openfoam2512/tutorials
```

This release series has no `foamVersion` executable. The version lives in the environment that
`etc/bashrc` exports.

## The OpenFOAM environment

OpenFOAM is not usable until `etc/bashrc` has been sourced. It exports `WM_PROJECT_DIR`,
`FOAM_TUTORIALS` and roughly eighty other variables the solvers depend on, and prepends the solver
directory to `PATH`. Without it, `icoFoam` is simply not found.

This image handles that with `/etc/profile.d/openfoam.sh` plus an `ENTRYPOINT` of `bash -lc`, so
every command run in the container gets the environment:

```console
$ docker run --rm --platform linux/amd64 openfoam-ubuntu 'which icoFoam'
/usr/lib/openfoam/openfoam2512/platforms/linux64GccDPInt32Opt/bin/icoFoam
```

That login shell takes the whole command as a **single argument**, which is why the wrap
environment in [`../templates/`](../templates/) composes one string rather than separate argv
entries.

## Run a case by hand

The tutorials ship inside the image, so there is nothing to download. `foamCloneCase` copies just
the case definition — the first time directory, `constant/` and `system/` — leaving the read-only
tutorial tree untouched.

The lid-driven cavity is OpenFOAM's hello-world: a square box of fluid with the top wall sliding
sideways, 400 cells, solved in under a tenth of a second.

```console
mkdir -p /tmp/foam

docker run --rm --platform linux/amd64 \
    --user "$(id -u):$(id -g)" -e HOME=/tmp \
    -v /tmp/foam:/work \
    openfoam-ubuntu '
        set -e
        foamCloneCase "$FOAM_TUTORIALS/incompressible/icoFoam/cavity/cavity" /work/cavity
        cd /work/cavity
        blockMesh
        icoFoam
        foamToVTK -latestTime
    '
```

That leaves the solved time directories and a `VTK/` directory in `/tmp/foam/cavity`, ready to open
in [ParaView](https://www.paraview.org/) on the host — or to plot without leaving the container, as
below.

`--user` with a uid that has no entry in the image's `/etc/passwd` leaves `$USER` empty and makes
`whoami` fail. OpenFOAM tolerates that for serial runs. `-e HOME=/tmp` matters more: `etc/bashrc`
derives `WM_PROJECT_USER_DIR` from `$HOME`, and Docker sets `HOME=/` for such a uid, which is not
writable.

## Turning VTK output into pictures

`foamToVTK` writes **data**, not images. Four approaches get from there to something you can look at,
and they differ by an order of magnitude in weight:

| Approach | Added to the image | Gives you | Needs a GL context |
|---|---|---|---|
| ParaView `pvbatch` | ~400 MB + Qt5, GDAL, ffmpeg | 3D, volume rendering, publication quality | Yes (software mesa or a GPU) |
| `python3-vtk9` + matplotlib | ~810 MB | 2D contours, streamlines, graphs | No, but apt links LLVM and mesa anyway |
| matplotlib alone, parsing the XML | ~210 MB | 2D contours, streamlines, graphs | No |
| `gnuplot-nox` | ~30 MB | line graphs, heatmaps, arrow plots | No |

This image takes the third row. `foamToVTK` writes point-interpolated fields alongside the cell
fields, and a `.vtu` is XML, so
[`scripts/foam_plot.py`](scripts/foam_plot.py) reads the two arrays it needs with
`xml.etree` and `base64` from the standard library. That skips `python3-vtk9`, which would make
reading a one-liner but pulls in LLVM and mesa — around 800 MB — to link an OpenGL renderer that
matplotlib's Agg backend never calls.

matplotlib goes in a virtual environment at `/opt/foamplot` rather than through apt, because Ubuntu
24.04 is an [externally managed Python](https://packaging.python.org/en/latest/specifications/externally-managed-environments/)
and because Ubuntu's `python3-matplotlib` depends on `python3-scipy` and `python3-sympy`, about
125 MB of packages the plotting never imports.

`pvbatch` is still the right answer for real post-processing — 3D scenes, cut planes, animation,
anything an engineer wants to explore rather than glance at. The tool here is the smallest thing
that produces a picture.

### Using it

```console
foam-plot field   OUT.png CASE_DIR                  # velocity field of one case
foam-plot profile OUT.png CASE_DIR [CASE_DIR ...]   # centreline graph comparing cases
```

Both read the newest time directory under the case's `VTK/`, so run `foamToVTK` first. Continuing
the cavity run above:

```console
docker run --rm --platform linux/amd64 \
    --user "$(id -u):$(id -g)" -e HOME=/tmp \
    -v /tmp/foam:/work \
    openfoam-ubuntu 'foam-plot field /work/cavity-velocity.png /work/cavity'
```

`field` draws filled contours of velocity magnitude with streamlines over them. `profile` plots
horizontal velocity along the vertical centreline, one line per case — for the lid-driven cavity
that is the standard [Ghia benchmark](https://doi.org/10.1016/0021-9991(82)90058-4) comparison, and
it is what makes a parameter sweep readable as a single graph.

The build renders a real cavity solve and fails if the PNG comes back implausibly small, so a broken
plotting chain surfaces at build time rather than in your first run:

```
build check: solved, converted and plotted the cavity (258337 byte PNG)
```

### Limits of the plotting tool

It handles **2D cases only** — a mesh one cell thick, which covers `cavity`, `pitzDaily` and most
tutorials people start with. A genuinely 3D mesh is refused rather than silently flattened:

```
nu-0.01: mesh spans 21 planes in z; these plots only handle a 2D (one cell thick) case
```

It also needs the `U` field, and reads uncompressed `.vtu` — ascii or base64 binary, both of which
`foamToVTK` produces by default. For 3D, animation, or anything beyond a glance, use ParaView.

## Notes and gotchas

**Mirror failures during the build.** `dl.openfoam.com` redirects every request to a randomly chosen
SourceForge mirror, and a mirror unreachable from the build network stalls until apt's default 120 s
timeout:

```
E: Failed to fetch .../openfoam2512-common_2512.0-2_all.deb
   Could not connect to cfhcable.dl.sourceforge.net:443 ... connection timed out
```

The `Dockerfile` handles this in two places, both needed:

* `/etc/apt/apt.conf.d/99-openfoam-mirror-retries` sets `Acquire::Retries "10"` and a 20 s timeout,
  which covers individual `.deb` fetches. It is apt configuration rather than `-o` flags so it
  applies to `apt-get update` too, and so images built `FROM` this one inherit it.
* A retry loop around `apt-get update`, because that command exits 0 even when a source fails to
  download — it only warns `Some index files failed to download`. When the failed source is
  OpenFOAM's, the build gets as far as `E: Unable to locate package openfoam2512-default`, which
  reads like a wrong package name rather than an unreachable mirror. The loop asks
  `apt-cache show` whether the package is visible, which is the check that actually means the index
  arrived, and retries up to five times.

An unlucky first attempt costs about four minutes of stalled connections before the retry succeeds,
so a build that looks stuck at the install step is probably waiting on a dead mirror rather than
hung. It reports each retry:

```
openfoam index unavailable (attempt 1/5), retrying
```

**No `curl | bash`.** The upstream instructions are
`curl -s https://dl.openfoam.com/add-debian-repo.sh | sudo bash`. The `Dockerfile` spells out the
two things that script does — import the signing key, write the apt source — because piping a
remote script into a shell hides what is being run and makes the build unreproducible. It also
uses the `signed-by` keyring form rather than the deprecated `/etc/apt/trusted.gpg.d`.

**Architecture.** The apt source pins `arch=amd64`, so this image is x86_64 only. OpenCFD also
publishes arm64 packages; an arm64 image needs that `arch=` changed and the `--platform` flag
dropped.

**Parallel runs.** The MPI stack is installed, so `decomposePar` and
`mpirun -np N <solver> -parallel` work. Running MPI as root needs
`mpirun --allow-run-as-root`, and OpenMPI can be unhappy with a uid that has no `/etc/passwd`
entry — pass a `--user` whose uid exists in the image, or add one, if you go parallel.

## Next: run it as a job

[`../templates/`](../templates/) runs this image as an Open Job Description job, using the
`WRAP_ACTIONS` extension so the job template itself contains no container knowledge.
