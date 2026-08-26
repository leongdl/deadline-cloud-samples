#!/usr/bin/env python3
"""Print one row per sweep combination from the metrics.json files it is given.

Standard library only, so it runs on whatever python3 the host has.
"""

import json
import sys

FMT = "  %-26s %6s %7s %6s %10s %10s %12s %9s"


def main(paths):
    if not paths:
        return 0
    print(FMT % ("combination", "frames", "steps", "clip_s", "mp4_bytes",
                 "peak_flex", "peak_force", "wall_s"))
    rows = []
    for path in paths:
        try:
            with open(path) as handle:
                m = json.load(handle)
        except (OSError, ValueError) as err:
            print(f"  {path}: unreadable ({err})")
            continue
        rows.append(m)

    for m in sorted(rows, key=lambda r: r.get("label", "")):
        print(FMT % (
            m.get("label", "?"),
            m.get("frames", "?"),
            m.get("steps", "?"),
            m.get("clip_seconds", "?"),
            m.get("mp4_bytes", "?"),
            round(m.get("peak_flexion_rad", 0.0), 3),
            round(m.get("peak_actuator_force", 0.0), 3),
            m.get("wall_seconds", "?"),
        ))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
