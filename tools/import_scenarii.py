#!/usr/bin/env python3
"""Convert BeamMP "scenarii" races and derbies into Race Manager layouts.

    python tools/import_scenarii.py ~/Downloads/scenarii
    python tools/import_scenarii.py ~/Downloads/scenarii --out import
    python tools/import_scenarii.py ~/Downloads/scenarii --list

Writes, under --out (default `import/`), the two folders the server reads:

    Race Layout/<map>.json    every race on that map, one file per map
    Derby Arena/<map>.json    every derby arena on that map, likewise
    INDEX.md                  a table of every map, race and arena that came out

That IS the server's own layout store -- since the per-map migration these two
folders are what it loads -- so the output can be copied straight into
Resources/Server/RaceManager/ once you have looked at it.

NOTHING IS INSTALLED ANYWAY. These folders are every track an admin has ever
built, so this writes them somewhere else and leaves the copy to a human.

    --merge PATH    fold an existing store in FIRST, so imports never displace
                    anything you built. PATH may be a flat layouts.json, a
                    derbyArenas.json, or a Resources/Server/RaceManager folder
                    holding any of them.

DUPLICATE NAMES ARE KEPT, BOTH OF THEM. The server matches a layout by name
within a map, so two tracks called "Race" on one map is one track that quietly
shadows another. An imported name that collides gets " (2)", " (3)" and so on
appended -- the import moves, never the thing that was already there.

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


def read_store(path, kind):
    """Read an existing store: a flat file, or a folder of per-map files.

    `kind` is "layouts" or "arenas", and it only decides which names are looked
    for inside a folder -- both file formats are the same `{"layouts": [...]}`
    the server has always written.
    """
    if not path:
        return []
    flat_names = {"layouts": "layouts.json", "arenas": "derbyArenas.json"}[kind]
    dir_names = {"layouts": "Race Layout", "arenas": "Derby Arena"}[kind]
    out = []
    if os.path.isfile(path):
        out.extend(load(path).get("layouts", []))
        return out
    if not os.path.isdir(path):
        return out
    # A server folder: prefer the per-map folder, fall back to the flat file,
    # exactly as the server itself does -- reading both would double every entry
    # that had been migrated.
    sub = os.path.join(path, dir_names)
    if os.path.isdir(sub):
        for name in sorted(os.listdir(sub)):
            if name.endswith(".json"):
                base = name[:-5]
                for entry in load(os.path.join(sub, name)).get("layouts", []):
                    entry.setdefault("map", base)
                    out.append(entry)
        return out
    flat = os.path.join(path, flat_names)
    if os.path.isfile(flat):
        out.extend(load(flat).get("layouts", []))
    # The folder may itself be a per-map folder handed in directly.
    if not out:
        for name in sorted(os.listdir(path)):
            if name.endswith(".json") and name not in flat_names:
                base = name[:-5]
                for entry in load(os.path.join(path, name)).get("layouts", []):
                    entry.setdefault("map", base)
                    out.append(entry)
    return out


def merge_unique(existing, incoming):
    """Append `incoming` to `existing`, renaming any name that already exists.

    THE INCOMING ONE MOVES. The server resolves a layout by name within a map,
    so a collision is not a merge conflict to be resolved by picking a winner --
    it is one track silently shadowing another, and the one that was already
    there is the one somebody built. An import that renamed the local track
    would break every reference to it in a league's own notes.

    Case-insensitively, because that is how the server matches.
    """
    taken = set()
    for e in existing:
        taken.add((e.get("map", ""), str(e.get("name", "")).lower()))
    merged = list(existing)
    renamed = []
    for e in incoming:
        m = e.get("map", "")
        base = str(e.get("name", "Unnamed"))
        name = base
        n = 1
        while (m, name.lower()) in taken:
            n += 1
            name = "%s (%d)" % (base, n)
        if name != base:
            renamed.append((m, base, name))
            e["name"] = name
        taken.add((m, name.lower()))
        merged.append(e)
    return merged, renamed


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("source", help="the scenarii folder")
    ap.add_argument("--out", default="import", help="output folder (default: import)")
    ap.add_argument("--list", action="store_true",
                    help="say what would be converted and write nothing")
    ap.add_argument("--merge", metavar="PATH",
                    help="fold an existing store in first: a layouts.json, a "
                         "derbyArenas.json, or a Resources/Server/RaceManager "
                         "folder. Imports go second, so a duplicate name "
                         "renames the IMPORT and never what you built.")
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
    race_dir = os.path.join(out, "Race Layout")
    arena_dir = os.path.join(out, "Derby Arena")
    os.makedirs(race_dir, exist_ok=True)
    os.makedirs(arena_dir, exist_ok=True)

    # LOCAL FIRST, IMPORTS SECOND, so a collision renames the import and leaves
    # what somebody built exactly where it was.
    local_races = read_store(args.merge, "layouts")
    local_arenas = read_store(args.merge, "arenas")
    if args.merge:
        print("merging %d existing layout(s) and %d arena(s) from %s"
              % (len(local_races), len(local_arenas), args.merge))

    incoming_races = [r for m in sorted(races_by_map) for r in races_by_map[m]]
    incoming_arenas = [a for m in sorted(arenas_by_map) for a in arenas_by_map[m]]
    layouts, renamed_r = merge_unique(local_races, incoming_races)
    arenas, renamed_a = merge_unique(local_arenas, incoming_arenas)
    for m, was, now in renamed_r + renamed_a:
        print('  renamed %s: "%s" -> "%s" (a track of that name was already there)'
              % (m, was, now))

    def write(path, obj):
        with open(path, "w", encoding="utf-8") as f:
            json.dump(obj, f, indent=1)
            f.write("\n")

    def by_map(entries):
        grouped = {}
        for e in entries:
            grouped.setdefault(e.get("map", "unknown"), []).append(e)
        return grouped

    def safe(name):
        return "".join(c if (c.isalnum() or c in "-_.") else "_" for c in name) or "unknown"

    # ONE FILE PER MAP, in the two folders the server reads. "Which tracks do we
    # have races for" is a directory listing, and an edit to one track moves one
    # small file rather than a 300 KB blob.
    grouped_races = by_map(layouts)
    grouped_arenas = by_map(arenas)
    for m, entries in sorted(grouped_races.items()):
        write(os.path.join(race_dir, safe(m) + ".json"),
              {"version": 1, "map": m, "layouts": entries})
    for m, entries in sorted(grouped_arenas.items()):
        write(os.path.join(arena_dir, safe(m) + ".json"),
              {"version": 2, "map": m, "layouts": entries})
    print("%d layout(s) over %d map file(s); %d arena(s) over %d map file(s)"
          % (len(layouts), len(grouped_races), len(arenas), len(grouped_arenas)))

    with open(os.path.join(out, "INDEX.md"), "w", encoding="utf-8") as f:
        f.write("# Imported scenarii\n\n")
        f.write("%d races, %d arenas, %d maps.\n\n" % (n_races, n_arenas, len(maps)))
        f.write("| Map | Kind | Name | Gates | Notes |\n|---|---|---|--:|---|\n")
        for m, kind, nm, count, note in report:
            f.write("| %s | %s | %s | %d | %s |\n" % (m, kind, nm, count, note or ""))
    print('wrote %s/"Race Layout"/*.json, %s/"Derby Arena"/*.json, %s/INDEX.md'
          % (out, out, out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
