#!/usr/bin/env python3
"""Run one Shadow Hand simulation and render frames, for one point in a parameter sweep.

One invocation is one sweep point. The caller varies the parameters and owns the
sweep itself -- here that caller is an Open Job Description task parameter space.

Parameters are applied to the compiled mjModel rather than by rewriting the MJCF.
Editing the XML by element name looks convenient but fails silently on this model:
the compiled Shadow Hand has exactly one *named* geom, and its per-class joint
damping lives in <default> blocks, so name-matching edits hit nothing and the
simulation runs at its defaults. Every mutation below therefore counts what it
touched and fails if that count is zero.
"""

import argparse
import json
import os
import pathlib
import sys
import time

import mujoco
import numpy as np
from PIL import Image

# Menagerie's own scene suggests this viewing angle via <global azimuth/>.
DEFAULT_AZIMUTH = 220.0
DEFAULT_ELEVATION = -30.0


def hand_camera(model, data, azimuth, elevation, zoom):
    """Aim a free camera at the hand, derived from where the hand actually is.

    The Shadow Hand lies along +X and is nearly flat in Z, so a hardcoded lookat
    is easy to get wrong -- and a wrong one silently renders a picture of the
    floor. Frame the bounding box of the hand's own geoms instead, ignoring the
    scene's free-floating object so it cannot drag the view off the hand.
    """
    body_names = [mujoco.mj_id2name(model, mujoco.mjtObj.mjOBJ_BODY, i) for i in range(model.nbody)]
    hand_bodies = {i for i, n in enumerate(body_names) if n and n.startswith("rh_")}
    hand_geoms = [g for g in range(model.ngeom) if model.geom_bodyid[g] in hand_bodies]
    if not hand_geoms:
        # Not the Shadow Hand; fall back to MuJoCo's whole-model framing.
        hand_geoms = list(range(model.ngeom))

    lo = data.geom_xpos[hand_geoms].min(axis=0)
    hi = data.geom_xpos[hand_geoms].max(axis=0)

    camera = mujoco.MjvCamera()
    mujoco.mjv_defaultFreeCamera(model, camera)
    camera.lookat[:] = (lo + hi) / 2.0
    camera.distance = float(np.linalg.norm(hi - lo)) * zoom
    camera.azimuth = azimuth
    camera.elevation = elevation
    return camera


def build_model(model_path, damping_scale, stiffness_scale):
    """Compile the model and apply the sweep parameters to it.

    Returns (model, applied) where `applied` records what each mutation changed,
    so a parameter that silently matched nothing is a hard error rather than a
    run that quietly used defaults.
    """
    # meshdir and <include> in the MJCF resolve against the process working
    # directory, so compile from the model's own directory.
    model_path = pathlib.Path(model_path).resolve()
    os.chdir(model_path.parent)
    model = mujoco.MjModel.from_xml_path(str(model_path))

    # Hinge DOFs are the hand's finger and wrist joints. The scene also carries a
    # free-floating object whose 6 DOFs must keep their own damping, so select on
    # joint type instead of touching dof_damping wholesale.
    hinge_dofs = [
        d
        for d in range(model.nv)
        if model.jnt_type[model.dof_jntid[d]] == mujoco.mjtJoint.mjJNT_HINGE
    ]
    if not hinge_dofs:
        sys.exit("no hinge DOFs found: wrong model?")

    damping_before = float(np.mean(model.dof_damping[hinge_dofs]))
    model.dof_damping[hinge_dofs] *= damping_scale
    damping_after = float(np.mean(model.dof_damping[hinge_dofs]))

    # The hand is driven by position actuators; their gainprm/biasprm carry the
    # position gain kp. Scaling it changes how hard the fingers are driven toward
    # the target, which is visible as reach and overshoot.
    position_acts = [
        a
        for a in range(model.nu)
        if model.actuator_gaintype[a] == mujoco.mjtGain.mjGAIN_FIXED
    ]
    if not position_acts:
        sys.exit("no fixed-gain actuators found: wrong model?")

    kp_before = float(np.mean(model.actuator_gainprm[position_acts, 0]))
    for a in position_acts:
        model.actuator_gainprm[a, 0] *= stiffness_scale
        # biasprm[1] is -kp for a position actuator; keep it consistent or the
        # actuator no longer behaves as position control.
        model.actuator_biasprm[a, 1] *= stiffness_scale
    kp_after = float(np.mean(model.actuator_gainprm[position_acts, 0]))

    applied = {
        "hinge_dofs_scaled": len(hinge_dofs),
        "mean_damping_before": damping_before,
        "mean_damping_after": damping_after,
        "position_actuators_scaled": len(position_acts),
        "mean_kp_before": kp_before,
        "mean_kp_after": kp_after,
    }
    return model, applied


def grasp_targets(model, phase):
    """Control targets for an open/close cycle, as a fraction `phase` of full flexion.

    Each actuator is driven between its ctrlrange midpoint (open) and its upper
    limit (flexed), so the motion stays inside every joint's declared range.
    """
    low = model.actuator_ctrlrange[:, 0]
    high = model.actuator_ctrlrange[:, 1]
    open_pose = np.where(low < 0.0, np.zeros_like(low), low)
    return open_pose + phase * (high - open_pose)


def main():
    p = argparse.ArgumentParser(description="Shadow Hand sweep point: simulate and render.")
    p.add_argument("--model", default="/models/mujoco_menagerie/shadow_hand/scene_right.xml")
    p.add_argument("--damping-scale", type=float, default=1.0,
                   help="Multiplier on hinge-joint damping.")
    p.add_argument("--stiffness-scale", type=float, default=1.0,
                   help="Multiplier on position-actuator kp.")
    p.add_argument("--duration", type=float, default=5.0,
                   help="Simulated seconds.")
    p.add_argument("--cycle", type=float, default=2.0,
                   help="Seconds per open/close cycle.")
    p.add_argument("--fps", type=float, default=20.0,
                   help="Rendered frames per simulated second.")
    p.add_argument("--width", type=int, default=480)
    p.add_argument("--height", type=int, default=360)
    p.add_argument("--out-dir", required=True,
                   help="Directory for frames/, preview.gif and metrics.json.")
    p.add_argument("--label", default="run",
                   help="Name for this sweep point, used in filenames.")
    p.add_argument("--azimuth", type=float, default=DEFAULT_AZIMUTH)
    p.add_argument("--elevation", type=float, default=DEFAULT_ELEVATION)
    p.add_argument("--zoom", type=float, default=1.15,
                   help="Camera distance as a multiple of the hand's bounding diagonal.")
    args = p.parse_args()

    model, applied = build_model(args.model, args.damping_scale, args.stiffness_scale)
    data = mujoco.MjData(model)

    steps = int(round(args.duration / model.opt.timestep))
    frame_every = max(1, int(round(1.0 / (args.fps * model.opt.timestep))))

    out_dir = pathlib.Path(args.out_dir)
    frames_dir = out_dir / "frames"
    frames_dir.mkdir(parents=True, exist_ok=True)

    mujoco.mj_forward(model, data)
    camera = hand_camera(model, data, args.azimuth, args.elevation, args.zoom)

    renderer = mujoco.Renderer(model, args.height, args.width)
    frames = []
    peak_flexion = 0.0
    peak_actuator_force = 0.0
    wall_start = time.time()

    for step in range(steps):
        # Triangle wave in [0, 1]: closes, opens, repeats.
        cycle_pos = (data.time % args.cycle) / args.cycle
        phase = 2.0 * cycle_pos if cycle_pos < 0.5 else 2.0 * (1.0 - cycle_pos)
        data.ctrl[:] = grasp_targets(model, phase)

        mujoco.mj_step(model, data)

        peak_flexion = max(peak_flexion, float(np.abs(data.qpos[: model.nu]).max()))
        peak_actuator_force = max(peak_actuator_force, float(np.abs(data.actuator_force).max()))

        if step % frame_every == 0:
            renderer.update_scene(data, camera)
            px = renderer.render()
            frames.append(Image.fromarray(px))
            frames[-1].save(frames_dir / f"{args.label}-{len(frames) - 1:04d}.png")

    if hasattr(renderer, "close"):
        renderer.close()

    wall_seconds = time.time() - wall_start

    if frames:
        frames[0].save(out_dir / "preview.gif", format="GIF", save_all=True,
                       append_images=frames[1:], duration=int(1000 / args.fps), loop=0)

    metrics = {
        "label": args.label,
        "params": {
            "damping_scale": args.damping_scale,
            "stiffness_scale": args.stiffness_scale,
            "duration_s": args.duration,
            "cycle_s": args.cycle,
            "fps": args.fps,
        },
        "model": {
            "path": str(args.model),
            "timestep": float(model.opt.timestep),
            "nq": int(model.nq),
            "nv": int(model.nv),
            "nu": int(model.nu),
        },
        "applied": applied,
        "steps": steps,
        "frames": len(frames),
        "peak_flexion_rad": peak_flexion,
        "peak_actuator_force": peak_actuator_force,
        "wall_seconds": round(wall_seconds, 2),
        "mujoco": mujoco.__version__,
    }
    (out_dir / "metrics.json").write_text(json.dumps(metrics, indent=2) + "\n")

    print(
        f"{args.label}: {steps} steps = {args.duration}s sim, {len(frames)} frames, "
        f"damping x{args.damping_scale} ({applied['mean_damping_before']:.4f} -> "
        f"{applied['mean_damping_after']:.4f} over {applied['hinge_dofs_scaled']} dofs), "
        f"kp x{args.stiffness_scale} ({applied['mean_kp_before']:.2f} -> "
        f"{applied['mean_kp_after']:.2f} over {applied['position_actuators_scaled']} actuators), "
        f"peak_flexion {peak_flexion:.3f} rad, peak_force {peak_actuator_force:.3f}, "
        f"{wall_seconds:.1f}s wall"
    )

    if len(frames) == 0:
        sys.exit("no frames rendered")


if __name__ == "__main__":
    main()
