# MuJoCo on Rocky Linux 9, CPU only, with headless offscreen rendering.
#
# Unlike the moonray sample next door, nothing is compiled here: MuJoCo ships
# manylinux wheels, so this is a pip install. Rocky 9 carries glibc 2.34, which
# satisfies the manylinux_2_28 tag the current wheels use.
#
# Rendering is software (llvmpipe) through EGL. RHEL 9 dropped the OSMesa
# packages that MuJoCo's `osmesa` backend needs, so `egl` is the only headless
# backend available here — see README.md.
#
# Build:
#   docker build --platform linux/amd64 -t mujoco-rocky9 .
#
# Smoke test (the image verifies this at build time too):
#   docker run --rm -v "$(pwd)/output:/output" mujoco-rocky9 \
#       'python3 -c "import mujoco; print(mujoco.__version__)"'
FROM rockylinux:9

# python3.12 is in AppStream. mesa-dri-drivers supplies the llvmpipe software
# rasteriser; mesa-libEGL + libglvnd-egl provide the EGL entry points MuJoCo
# uses for an offscreen context; mesa-libGL + libglvnd-opengl are needed
# because MuJoCo's Python renderer goes through PyOpenGL, which dlopens
# libOpenGL.so.0 / libGL.so.1 and fails with a confusing NoneType error if
# they are absent.
# ffmpeg is not in the Rocky/RHEL 9 repositories at all -- RHEL drops it over
# patent concerns -- so it comes from EPEL as `ffmpeg-free`, in a second dnf
# transaction because the first one is what makes EPEL available.
#
# `ffmpeg-free` carries no libx264, and its libopenh264 support is dynamically
# linked against a library that ships in a *separate* repo. Without the openh264
# package below, `-c:v libopenh264` fails at encoder init with a misleading
# "maybe incorrect parameters such as bit_rate, rate, width or height". Installing
# it is what makes H.264 output work; mj-hand-sweep falls back to mpeg4 if it is
# ever missing.
RUN dnf install -y epel-release \
    && dnf install -y --enablerepo=crb --setopt=install_weak_deps=False \
        openh264 \
        python3.12 \
        python3.12-pip \
        git \
        mesa-libEGL \
        mesa-libGL \
        mesa-dri-drivers \
        libglvnd-egl \
        libglvnd-opengl \
        ffmpeg-free \
    && dnf clean all \
    && rm -rf /var/cache/dnf

# Pinned so a rebuild produces the same MuJoCo. 3.11.0 is the current release;
# it needs Python >= 3.11 for a wheel, hence python3.12 above.
ARG MUJOCO_VERSION=3.11.0
RUN python3.12 -m pip install --no-cache-dir \
        "mujoco==${MUJOCO_VERSION}" \
        "numpy" \
        "pillow" \
    # Rocky's own /usr/bin/python3 is 3.9, which has no mujoco. /usr/local/bin
    # precedes /usr/bin on PATH, so these symlinks make plain `python3` (and any
    # `#!/usr/bin/env python3` shebang) resolve to the interpreter that does.
    && ln -sf /usr/bin/python3.12 /usr/local/bin/python \
    && ln -sf /usr/bin/python3.12 /usr/local/bin/python3

# --- models -----------------------------------------------------------------
# Pinned commits rather than branch tips, so the scene geometry cannot shift
# under a rebuild.
ARG CUBE_REF=bfd39af77043a3d9e44898c7db4288882a11ea72
ARG MENAGERIE_REF=71f066ad0be9cd271f7ed58c030243ef157af9f4

# kevinzakka/mujoco_cube — a 3x3x3 puzzle cube. Model only; note its `core`
# body is welded to the world, so a scene that wants the cube to be picked up
# has to add a freejoint (see ../scenes).
RUN git clone --quiet https://github.com/kevinzakka/mujoco_cube.git /models/mujoco_cube \
    && git -C /models/mujoco_cube checkout --quiet "${CUBE_REF}" \
    && rm -rf /models/mujoco_cube/.git

# google-deepmind/mujoco_menagerie — the full repo is large, so take only the
# shadow_hand directory via a blobless sparse checkout.
RUN git clone --quiet --filter=blob:none --sparse \
        https://github.com/google-deepmind/mujoco_menagerie.git /models/mujoco_menagerie \
    && git -C /models/mujoco_menagerie checkout --quiet "${MENAGERIE_REF}" \
    && git -C /models/mujoco_menagerie sparse-checkout set shadow_hand \
    && rm -rf /models/mujoco_menagerie/.git

# Record what was actually baked in, for provenance.
RUN printf 'mujoco=%s\ncube=%s\nmenagerie=%s\n' \
        "$(python3.12 -c 'import mujoco; print(mujoco.__version__)')" \
        "${CUBE_REF}" "${MENAGERIE_REF}" > /mujoco-refs.txt

# One sweep point: apply parameters to the compiled model, simulate, render
# frames. See templates/ for the job that sweeps it.
COPY scripts/mj_hand_sweep.py /usr/local/bin/mj-hand-sweep
RUN chmod 0755 /usr/local/bin/mj-hand-sweep

# egl is the only headless backend available on Rocky 9 (no OSMesa package).
ENV MUJOCO_GL=egl
ENV PYTHONUNBUFFERED=1

# Fail the build rather than the user if headless rendering is broken: render
# one frame of the real cube model and assert the pixels are not all black.
RUN cd /models/mujoco_cube \
    && python3.12 -c "\
import mujoco, sys;\
m = mujoco.MjModel.from_xml_path('cube_3x3x3.xml');\
d = mujoco.MjData(m);\
mujoco.mj_forward(m, d);\
r = mujoco.Renderer(m, 120, 160);\
r.update_scene(d);\
px = r.render();\
sys.exit(0 if px.sum() > 0 else 'offscreen render produced an empty frame')" \
    && echo "build-time render check passed"

WORKDIR /models

# Same convention as the moonray sample: the whole command arrives as one
# quoted string.
ENTRYPOINT ["/bin/bash", "-lc"]
CMD ["python3.12 -c 'import mujoco; print(\"mujoco\", mujoco.__version__)' && cat /mujoco-refs.txt"]
