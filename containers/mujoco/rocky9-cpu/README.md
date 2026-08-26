# MuJoCo on Rocky Linux 9 (CPU)

A container with [MuJoCo](https://github.com/google-deepmind/mujoco) and headless offscreen
rendering, plus two models baked in: the
[3x3x3 puzzle cube](https://github.com/kevinzakka/mujoco_cube) and the Shadow Dexterous Hand from
[MuJoCo Menagerie](https://github.com/google-deepmind/mujoco_menagerie).

Nothing is compiled. Unlike the [moonray](../../moonray/rocky9-cpu/) sample next door, MuJoCo ships
manylinux wheels, so this is a `pip install` and the image builds in about a minute.

## Build

```console
docker build --platform linux/amd64 -t mujoco-rocky9 .
```

Roughly 1 minute, producing a 972 MB image. The build renders a frame of the real cube model and
fails if the pixels come back empty, so a broken GL stack surfaces at build time rather than in
your first run.

ffmpeg is included, for turning rendered frames into video. Rocky 9 ships none, so it comes from
EPEL as `ffmpeg-free` — which has no libx264, and needs the `openh264` package from the separate
`epel-cisco-openh264` repo before `-c:v libopenh264` will initialise. Both are installed.

## Run

The `ENTRYPOINT` is `bash -lc`, so the whole command goes in as one quoted string:

```console
mkdir -p output
docker run --rm -v "$(pwd)/output:/output" mujoco-rocky9 'cat /mujoco-refs.txt'
```

Render the cube to a PNG:

```console
docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -v "$(pwd)/output:/output" mujoco-rocky9 \
  'cd /models/mujoco_cube && python3.12 -c "
import mujoco
from PIL import Image
m = mujoco.MjModel.from_xml_path(\"cube_3x3x3.xml\")
d = mujoco.MjData(m); mujoco.mj_forward(m, d)
r = mujoco.Renderer(m, 480, 640); r.update_scene(d)
Image.fromarray(r.render()).save(\"/output/cube.png\")
"'
```

Swap `cd /models/mujoco_menagerie/shadow_hand` and `scene_right.xml` to render the hand instead.

## What's in the image

| Path | Contents |
|---|---|
| `/models/mujoco_cube` | `cube_3x3x3.xml`, sticker texture atlas, and the scripts that generate them |
| `/models/mujoco_menagerie/shadow_hand` | `right_hand.xml`, `left_hand.xml`, `scene_right.xml`, `scene_left.xml`, `keyframes.xml`, meshes |
| `…/shadow_hand/scene_right_ball.xml` | Added by this sample: the right hand holding a **sphere** rather than Menagerie's ellipsoid. Kept in that directory because its `<include>` and `meshdir="assets"` resolve relative to the main model file |
| `/mujoco-refs.txt` | The MuJoCo version and the two model commits actually baked in |
| `/usr/local/bin/mj-hand-sweep` | One Shadow Hand sweep point: apply parameters, simulate, render frames, encode an MP4. Driven by the job in [`../templates/`](../templates/) |

Both model repos are pinned to commits, not branch tips, so the geometry cannot shift under a
rebuild. Override with `--build-arg CUBE_REF=…`, `--build-arg MENAGERIE_REF=…`, or
`--build-arg MUJOCO_VERSION=…`.

Verified model stats, read out of the built image:

| Model | Bodies | `nq` | Actuators |
|---|---|---|---|
| `cube_3x3x3.xml` | 28 | 86 | 0 |
| `shadow_hand/scene_right.xml` | 27 | 31 | 20 |

## Rendering notes

**EGL is the only headless backend here.** RHEL 9 (and therefore Rocky 9) no longer packages
`mesa-libOSMesa`, so MuJoCo's `osmesa` backend cannot be used. The image sets `MUJOCO_GL=egl` and
renders through mesa's llvmpipe software rasteriser.

**Rendering is software, so it is slow.** This host has no GPU. A 640×480 frame is fine; long
videos will take real time. On a GPU host, install the NVIDIA Container Toolkit and pass
`--gpus all` — the same `MUJOCO_GL=egl` path will then use the GPU.

**PyOpenGL needs the GL libraries present.** MuJoCo's Python renderer goes through PyOpenGL, which
dlopens `libOpenGL.so.0` / `libGL.so.1`. Without `mesa-libGL` and `libglvnd-opengl` the failure is
an unhelpful `AttributeError: 'NoneType' object has no attribute 'glGetError'`, not a clear missing
library error. Hence both are installed.

**A harmless teardown exception.** Every render prints this on exit:

```
Exception ignored in: <function GLContext.__del__ ...>
OpenGL.raw.EGL._errors.EGLError: <exception str() failed>
```

It comes from `GLContext.free()` during interpreter shutdown, after the frame has already been
produced. `Exception ignored in` means Python discarded it — the process still exits 0 and the
image is written. Filter it out if it clutters your logs.

## Wheel and glibc constraint

MuJoCo's current wheels are tagged `manylinux_2_28`, so they need glibc 2.28 or newer. Rocky 9 has
glibc 2.34 and installs the wheel directly. On an older host (glibc 2.26, for instance) pip finds no
compatible wheel, falls back to the source distribution, and tries to compile MuJoCo — which is
part of why running this in a container is worth it. The wheel version ceiling also depends on the
Python minor version: 3.11 and 3.12 both get 3.11.0, while for older interpreters pip stops at
3.3.4.

## Scope: cube and hand, not a cube solver

Worth being explicit, because the pieces invite the wrong expectation:

* `mujoco_cube` is **a cube model only**. There is no hand in that repo. The hand here comes from
  Menagerie.
* The cube's `core` body is **welded to the world** — it has no freejoint. A scene where a hand
  picks the cube up has to add one.
* `scene_right.xml` ships a green ellipsoid as its manipulation object, and does not include
  `keyframes.xml` (so `nkey` is 0). The keyframes — `grasp sphere`, `close hand`, `three finger
  pinch` and others — are available by including that file explicitly.
* **Nothing here solves a Rubik's cube.** Dexterous in-hand cube manipulation is a reinforcement
  learning result (OpenAI's Dactyl), requiring a trained policy that neither repo provides. This
  image gives you the physics and the rendering; driving the hand is a controller you supply,
  whether that is scripted actuator targets, a keyframe interpolation, or a learned policy.
