#!/usr/bin/env python3
"""Convert BeamMP "scenarii" races and derbies into Race Manager layouts.

    python tools/import_scenarii.py ~/Downloads/scenarii
    python tools/import_scenarii.py ~/Downloads/scenarii --out import
    python tools/import_scenarii.py ~/Downloads/scenarii --list

Writes, under --out (default `import/`):

    layouts.json          every converted race, in the format the server loads
    derbyArenas.json      every converted derby arena, likewise
    by-map/<map>.json     the same races and arenas split one file per map,
                          which is the readable half: one file per track, so
                          "which tracks do we have races for" is `ls`.
    INDEX.md              a table of every map, race and arena that came out

NOTHING IS INSTALLED. The two top-level files are drop-in replacements for the
ones under Resources/Server/RaceManager/, and layouts.json in particular is
every track an admin has ever built -- so this writes them somewhere else and
leaves the merge to a human. Use --merge to fold an existing layouts.json in
rather than starting from the imported set alone.

--------------------------------------------------------------------------
What converts cleanly, and what does not
--------------------------------------------------------------------------
A scenarii race is a list of STEPS, and each step is a list of waypoints that
are alternatives to each other. Race Manager calls the first of those a
checkpoint and the rest BRANCH GATES on the same slot, which is the same idea
with the same meaning: any one of them clears the step. That half is exact.

Two things are approximations, and both are called out per race in the index:

  RADIUS BECOMES A WIDTH. A scenarii waypoint is a sphere of some radius; a
  Race Manager checkpoint is an upright rectangle with a width, a height and a
  direction. Width is taken as radius * 2 -- the same span across -- but a
  sphere has no facing, so a converted gate is only as good as the heading
  below, and a car crossing the old gate diagonally may miss the new one.

  HEADING COMES FROM THE ROUTE, not from the waypoint's stored rotation. The
  rotation on a scenarii waypoint is the direction the AUTHOR's car happened to
  be pointing when they dropped it, which for a gate placed at a hairpin can be
  most of a right angle away from the direction the field will cross it. The
  path in and out of the step is the honest answer, and it is what this uses:
  the vector from the previous step to the next one. Stored rotations ARE used
  for start positions, where "which way does the car face" is the whole point
  and the author's own heading is exactly right.
"""

import argparse
import json
import math
import os
import sys

# Race Manager's own defaults, from RM_onSaveLayout. A converted layout carries
# them explicitly rather than relying on the server to fill them in, so what the
# file says is what the track is.
DEFAULT_HEIGHT = 8
DEFAULT_DEPTH = 2
# A sphere has no height. 8 up and 2 down is the mod's own default gate and is
# tall enough to see from a car without burying half of it in the road.
MIN_WIDTH = 4.0
MAX_WIDTH = 120.0
# How many vertices a converted circular derby arena gets. The boundary polygon
# is what every client runs point-in-polygon against, so this is a real
# trade-off between a round arena and a cheap test; 16 is round enough that a
# driver cannot see the corners and cheap enough not to matter.
ARENA_VERTICES = 16


def quat_yaw(rot):
    """Yaw in radians from a BeamNG quaternion, ignoring pitch and roll.

    The waypoints carry small x/y components from the terrain slope they were
    dropped on; this is the standard extraction and discards them, which is what
    a heading on the ground plane wants.
    """
    x = float(rot.get("x", 0.0))
    y = float(rot.get("y", 0.0))
    z = float(rot.get("z", 0.0))
    w = float(rot.get("w", 1.0))
    return math.atan2(2.0 * (w * z + x * y), 1.0 - 2.0 * (y * y + z * z))


def yaw_to_heading(yaw):
    """The inverse of the mod's own headingRot().

    headingRot is `yaw = atan2(hx, hy) + pi`, where the half-turn bakes in
    BeamNG's -Y vehicle forward. Inverting it here rather than guessing at a
    convention is what keeps an imported start position facing the way the
    author left it instead of backwards.
    """
    a = yaw - math.pi
    return round(math.sin(a), 6), round(math.cos(a), 6)


def norm2(dx, dy):
    d = math.hypot(dx, dy)
    if d < 1e-6:
        return 0.0, 1.0
    return round(dx / d, 6), round(dy / d, 6)


def pos_of(node):
    p = node.get("pos") or {}
    return (float(p.get("x", 0.0)), float(p.get("y", 0.0)), float(p.get("z", 0.0)))


def centroid(step):
    """The middle of a step's alternatives, for working out the path direction.

    A step with two gates side by side has a centre between them, and it is that
    centre the route runs through -- not either gate.
    """
    pts = [pos_of(w) for w in step]
    n = float(len(pts)) or 1.0
    return (sum(p[0] for p in pts) / n,
            sum(p[1] for p in pts) / n,
            sum(p[2] for p in pts) / n)


def step_heading(steps, i, loopable):
    """Which way the field crosses step i.

    From the previous step to the next one, so a gate faces along the racing
    line rather than along whatever the author was pointing at. Falls back to
    the neighbours it has at the ends of a sprint stage, and wraps on a circuit
    because there the last step leads back to the first.
    """
    n = len(steps)
    if n == 1:
        return 0.0, 1.0
    if loopable:
        prev = centroid(steps[(i - 1) % n])
        nxt = centroid(steps[(i + 1) % n])
    else:
        prev = centroid(steps[i - 1]) if i > 0 else centroid(steps[i])
        nxt = centroid(steps[i + 1]) if i + 1 < n else centroid(steps[i])
    if prev == nxt:
        # A one-step route, or a degenerate pair. The waypoint's own rotation is
        # all there is left to go on.
        return None
    return norm2(nxt[0] - prev[0], nxt[1] - prev[1])


def gate_from(node, hx, hy):
    x, y, z = pos_of(node)
    radius = float(node.get("radius", 5) or 5)
    width = max(MIN_WIDTH, min(MAX_WIDTH, radius * 2.0))
    return {
        "x": round(x, 3), "y": round(y, 3), "z": round(z, 3),
        "hx": hx, "hy": hy,
        "width": round(width, 2),
        "height": DEFAULT_HEIGHT,
        "depth": DEFAULT_DEPTH,
    }


def start_from(node):
    """A start position, facing the way its author left it.

    This is the one place the stored rotation is trusted over the route, and it
    is the place it is actually right: a grid slot's whole content is where the
    car stands and which way it points.
    """
    x, y, z = pos_of(node)
    hx, hy = yaw_to_heading(quat_yaw(node.get("rot") or {}))
    return {"x": round(x, 3), "y": round(y, 3), "z": round(z, 3), "hx": hx, "hy": hy}


def convert_race(race, map_name):
    """One scenarii race -> one Race Manager layout, or None if unusable."""
    steps = race.get("steps") or []
    steps = [s for s in steps if isinstance(s, list) and s]
    if not steps:
        return None, "no usable steps"

    loopable = bool(race.get("loopable"))
    checkpoints, branches, notes = [], [], []
    fallback_headings = 0
    for i, step in enumerate(steps):
        h = step_heading(steps, i, loopable)
        if h is None:
            h = yaw_to_heading(quat_yaw(step[0].get("rot") or {}))
            fallback_headings += 1
        hx, hy = h
        # The first alternative is the checkpoint; the rest are branch gates on
        # its slot. Race Manager counts a step as cleared by ANY of them, which
        # is what scenarii means by putting them in one list.
        checkpoints.append(gate_from(step[0], hx, hy))
        for extra in step[1:]:
            g = gate_from(extra, hx, hy)
            g["slot"] = i + 1          # slots are 1-based
            branches.append(g)

    entry = {
        "name": str(race.get("name") or "Unnamed"),
        "map": map_name,
        "width": 20, "height": DEFAULT_HEIGHT, "depth": DEFAULT_DEPTH,
        "checkpoints": checkpoints,
        # A scenarii race that does not loop is driven once from the first gate
        # to the last, which is exactly what Race Manager calls a sprint stage.
        "pointToPoint": not loopable,
        # Imported tracks are NOT offered for practice. Practice lets a
        # non-admin load a track on their own, and an import nobody has driven
        # yet is not something to hand the whole server unreviewed.
        "practice": False,
    }
    starts = [start_from(s) for s in (race.get("startPositions") or [])]
    if starts:
        entry["startPositions"] = starts
    if branches:
        entry["branches"] = branches

    if branches:
        notes.append("%d branch gate(s)" % len(branches))
    if fallback_headings:
        notes.append("%d gate(s) fell back to the stored rotation" % fallback_headings)
    if not starts:
        notes.append("no start positions: generate a grid before racing it")
    return entry, ", ".join(notes)


def convert_arena(arena, map_name):
    """One scenarii derby -> one Race Manager arena, or None if unusable."""
    c = arena.get("centerPosition") or {}
    try:
        cx, cy, cz = float(c["x"]), float(c["y"]), float(c["z"])
    except (KeyError, TypeError, ValueError):
        return None, "no centre position"
    radius = float(arena.get("radius", 0) or 0)
    if radius <= 0:
        return None, "no radius"

    # A CIRCLE BECOMES A POLYGON, because the polygon is what the mod polices
    # against -- every client runs point-in-polygon on `boundary` and nothing
    # else. `shape` is written alongside as the square that encloses it so the
    # rectangle editor has something to open, but the polygon is the arena.
    boundary = []
    for i in range(ARENA_VERTICES):
        a = (2.0 * math.pi * i) / ARENA_VERTICES
        boundary.append({
            "x": round(cx + radius * math.cos(a), 3),
            "y": round(cy + radius * math.sin(a), 3),
            "z": round(cz, 3),
        })

    entry = {
        "name": str(arena.get("name") or "Unnamed Arena"),
        "map": map_name,
        "boundary": boundary,
        # Left as a polygon rather than claimed as a rect: the imported shape is
        # a circle, and calling it a rectangle would let the rect editor's
        # sliders silently square it off the first time anybody touched them.
        "boundaryMode": "polygon",
        "startPositions": [start_from(s) for s in (arena.get("startPositions") or [])],
    }
    notes = ["circle r=%.1f as a %d-sided polygon" % (radius, ARENA_VERTICES)]
    if not entry["startPositions"]:
        notes.append("no start positions")
    return entry, ", ".join(notes)


def map_of(filename):
    """`east_coast_usa_races.json` -> `east_coast_usa`.

    The suffix is the scenario kind and the rest is the level folder, which is
    what the mod's own getCurrentMap() normalises a map path down to -- so the
    two agree without a translation table.
    """
    base = os.path.basename(filename)
    for suffix in ("_races.json", "_derby.json"):
        if base.endswith(suffix):
            return base[: -len(suffix)]
    return None


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("source", help="the scenarii folder")
    ap.add_argument("--out", default="import", help="output folder (default: import)")
    ap.add_argument("--list", action="store_true",
                    help="say what would be converted and write nothing")
    ap.add_argument("--merge", metavar="LAYOUTS_JSON",
                    help="fold an existing layouts.json in, imports second")
    args = ap.parse_args()

    if not os.path.isdir(args.source):
        print("not a folder: " + args.source, file=sys.stderr)
        return 2

    races_by_map, arenas_by_map, report = {}, {}, []
    skipped = []

    for name in sorted(os.listdir(args.source)):
        map_name = map_of(name)
        if not map_name:
            continue          # deliveries, buslines, hunter, stations: not ours
        path = os.path.join(args.source, name)
        try:
            data = load(path)
        except (OSError, ValueError) as e:
            skipped.append((name, "unreadable: %s" % e))
            continue
        if not isinstance(data, list):
            skipped.append((name, "not a list of scenarios"))
            continue

        is_race = name.endswith("_races.json")
        for item in data:
            if not isinstance(item, dict):
                continue
            if is_race:
                entry, note = convert_race(item, map_name)
                bucket = races_by_map
            else:
                entry, note = convert_arena(item, map_name)
                bucket = arenas_by_map
            if entry is None:
                skipped.append(("%s / %s" % (name, item.get("name", "?")), note))
                continue
            bucket.setdefault(map_name, []).append(entry)
            report.append((map_name, "race" if is_race else "derby",
                           entry["name"],
                           len(entry.get("checkpoints", entry.get("boundary", []))),
                           note))

    n_races = sum(len(v) for v in races_by_map.values())
    n_arenas = sum(len(v) for v in arenas_by_map.values())
    maps = sorted(set(races_by_map) | set(arenas_by_map))
    print("%d race(s) and %d arena(s) across %d map(s)" % (n_races, n_arenas, len(maps)))
    for m in maps:
        print("  %-28s %3d race(s)  %2d arena(s)"
              % (m, len(races_by_map.get(m, [])), len(arenas_by_map.get(m, []))))
    if skipped:
        print("skipped %d:" % len(skipped))
        for what, why in skipped[:20]:
            print("  %s -- %s" % (what, why))

    if args.list:
        return 0

    out = args.out
    os.makedirs(os.path.join(out, "by-map"), exist_ok=True)

    layouts = []
    if args.merge:
        existing = load(args.merge)
        layouts.extend(existing.get("layouts", []))
        print("merged %d existing layout(s) from %s" % (len(layouts), args.merge))
    for m in sorted(races_by_map):
        layouts.extend(races_by_map[m])
    arenas = []
    for m in sorted(arenas_by_map):
        arenas.extend(arenas_by_map[m])

    def write(path, obj):
        with open(path, "w", encoding="utf-8") as f:
            json.dump(obj, f, indent=1)
            f.write("\n")

    write(os.path.join(out, "layouts.json"), {"version": 1, "layouts": layouts})
    write(os.path.join(out, "derbyArenas.json"), {"version": 2, "layouts": arenas})

    # ONE FILE PER MAP, and this is the half that answers "which tracks do we
    # have races for". The server reads the two files above; these are for
    # people, and for diffing an edit to one track without a 300 KB blob moving.
    for m in maps:
        write(os.path.join(out, "by-map", m + ".json"), {
            "map": m,
            "layouts": races_by_map.get(m, []),
            "derbyArenas": arenas_by_map.get(m, []),
        })

    with open(os.path.join(out, "INDEX.md"), "w", encoding="utf-8") as f:
        f.write("# Imported scenarii\n\n")
        f.write("%d races, %d arenas, %d maps.\n\n" % (n_races, n_arenas, len(maps)))
        f.write("| Map | Kind | Name | Gates | Notes |\n|---|---|---|--:|---|\n")
        for m, kind, nm, count, note in report:
            f.write("| %s | %s | %s | %d | %s |\n" % (m, kind, nm, count, note or ""))
    print("wrote %s/layouts.json, %s/derbyArenas.json, %s/by-map/*.json, %s/INDEX.md"
          % (out, out, out, out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
