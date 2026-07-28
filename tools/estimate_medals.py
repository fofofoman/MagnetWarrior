#!/usr/bin/env python3
"""Estimate a clean-run time for every stage, and propose medal thresholds.

Medal times were originally hand-picked, then the movement and combat tuning
changed underneath them. Rather than guess new numbers, this derives them from
the layouts themselves: the critical path a run has to walk, plus the fixed cost
of everything that makes a player stop moving.

Every assumption is a named constant below, so re-running this after a tuning
change is a one-line diff rather than a fresh guess. It reads the same layout
files the game builds from, so it cannot drift out of sync with the geometry.

    python3 tools/estimate_medals.py            # print the table
    python3 tools/estimate_medals.py --apply    # rewrite StageConfig.luau
"""

import argparse
import math
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LAYOUTS = os.path.join(ROOT, "src/server/Stage/Layouts")
CONFIG = os.path.join(ROOT, "src/shared/Config/StageConfig.luau")
SERVICE = os.path.join(ROOT, "src/server/Stage/StageService.luau")

# ── Assumptions ─────────────────────────────────────────────────────────────
# Deliberately pessimistic. A medal nobody can earn is a dead goal, while one
# that is slightly generous still works — so every constant here is set toward
# "slower than a great player" rather than toward the theoretical best.

# Checkpoints are measured in straight lines, but nobody moves in straight
# lines: you overshoot, come back for a slab, and climb around things.
ROUTE_FACTOR = 1.4

# Effective speed is far under the 128 studs/s peak. Climbing a wall is 16, a
# ferry travels at its own pace, and every launch costs aim and turn-around
# time — a stage full of magnet walls is *not* a fast stage.
SPEED_KINETIC  = 22.0   # ferries and cling climbs set the pace
SPEED_COMBAT   = 20.0   # stop-and-fight pacing
SPEED_PUZZLE   = 16.0   # carrying and placing between stops
SPEED_LAUNCH   = 30.0   # push-off traversal, the fastest honest average
SPEED_DEFAULT  = 24.0

# Raised with the drone health pass. A Push is attenuated by distance, so at 115
# HP a Scrapper only dies to a slam thrown from inside ~46 studs where 60 HP died
# to a poke from 80. Killing things now means closing on them first.
COST_PER_ENEMY   = 3.6  # close the distance, aim, commit, confirm the kill
COST_PER_SOCKET  = 8.0  # fetch a slab, drag it in stages, place it precisely
COST_PER_GATE    = 1.2  # the open tween plus reacting to it
COST_PER_WALL    = 3.0  # turn around, aim at it, fire, recover
COST_PER_HAZARD  = 1.6  # jump it, or walk the long way round it
PULSE_WAIT_SHARE = 0.6  # you usually just miss the window and wait for the next

# Applied to the final estimate. See the note on pessimism above.
#
# Tightened from 1.25 with the difficulty pass. The estimate underneath it is
# already deliberately slower than a competent run, so this is the slack on top
# of a pessimistic number rather than on top of a realistic one — but 25% of
# slack meant gold arrived without ever chaining a launch, which made the top
# medal a participation award.
GOLD_MARGIN = 1.15

# Boss fights, from HP / damage-per-window * window length. See MagnetConfig's
# worked example and BossService for where these come from. Both went up with
# the armour-window pass: the collector's window fell 4.0s -> 3.0s against 1000
# HP, the furnace's 3.5s -> 2.8s against 1800.
BOSS_SECONDS = {"collector": 43.0, "furnace": 72.0}

# Bronze at +90% of gold was awarded for finishing at all, which made two of the
# three medals meaningless. Silver now wants a clean run and bronze wants a run
# that did not go badly wrong.
SILVER_RATIO = 1.25
BRONZE_RATIO = 1.60
# minPossibleMs is an anti-cheat floor, not a target. Deriving it purely from
# path length at the audit ceiling produces a few seconds, which is useless: the
# per-segment check in RunSessionService divides this floor across the segments,
# so a floor of 5s lets a clipped segment through at 0.5s. Taking a fraction of
# the estimated gold keeps it meaningful while staying far below any real run —
# this is also the ratio the hand-authored table happened to use (~0.4).
FLOOR_RATIO = 0.35
AUDIT_CEILING = 140.0


def block(src, name, indent="\t"):
    m = re.search(rf"^{indent}{name} = \{{", src, re.M)
    if not m:
        return ""
    i, depth, j = m.end() - 1, 0, m.end() - 1
    while j < len(src):
        if src[j] == "{":
            depth += 1
        elif src[j] == "}":
            depth -= 1
            if depth == 0:
                return src[i + 1 : j]
        j += 1
    return ""


def vectors(text):
    return [
        tuple(float(v) for v in m)
        for m in re.findall(
            r"Vector3\.new\(\s*(-?[\d.]+)\s*,\s*(-?[\d.]+)\s*,\s*(-?[\d.]+)\s*\)", text
        )
    ]


def first_vector(entry):
    m = re.search(
        r"position = Vector3\.new\(\s*(-?[\d.]+)\s*,\s*(-?[\d.]+)\s*,\s*(-?[\d.]+)\s*\)", entry
    )
    return tuple(float(g) for g in m.groups()) if m else None


def dist(a, b):
    return math.dist(a, b)


def analyse(path):
    src = open(path, encoding="utf-8").read()

    start = first_vector(block(src, "start"))
    finish = first_vector(block(src, "finish"))
    checkpoints = [
        first_vector(e) for e in re.findall(r"\{ position[^}]*\}", block(src, "checkpoints"))
    ]
    checkpoints = [c for c in checkpoints if c]

    route = [p for p in [start] + checkpoints + [finish] if p]
    path_length = sum(dist(route[i], route[i + 1]) for i in range(len(route) - 1))

    enemies = len(re.findall(r'kind = "\w+"', block(src, "enemies")))
    socket_entries = re.findall(r"\{ position[^}]*\}", block(src, "sockets"))
    sockets = len(socket_entries)
    gates = len(re.findall(r"openBy = ", block(src, "gates")))
    walls = len(re.findall(r"surface = true", block(src, "magnetic")))
    hazards = len(re.findall(r"\{ name = ", block(src, "hazards")))

    # Slabs have to be fetched. That round trip is real distance the straight
    # checkpoint route does not contain.
    fetch = 0.0
    socket_points = [first_vector(e) for e in socket_entries]
    socket_points = [p for p in socket_points if p]
    for entry in re.findall(r"\{ position[^}]*\}", block(src, "blocks")):
        b = first_vector(entry)
        if b and socket_points:
            fetch += min(dist(b, s) for s in socket_points) * 2

    kin = block(src, "kinetics")
    kinetic_count = len(re.findall(r"period = ", kin))
    pulse_periods = [
        float(p)
        for entry, p in re.findall(r"(\{[^{}]*?pulses = true[^{}]*?\})|period = ([\d.]+)", kin)
        if p
    ]
    # Period is written as `period = BEAT` or `BEAT * 2`; resolve the local.
    beat = re.search(r"^local BEAT = ([\d.]+)", src, re.M)
    beat = float(beat.group(1)) if beat else 6.0
    pulsing = len(re.findall(r"pulses = true", kin))

    boss = re.search(r'\bid = "(\w+)"', block(src, "boss"))
    boss_id = boss.group(1) if boss else None

    if kinetic_count > 0:
        speed = SPEED_KINETIC
    elif sockets > 0:
        speed = SPEED_PUZZLE
    elif enemies > 0:
        speed = SPEED_COMBAT
    elif walls > 0:
        speed = SPEED_LAUNCH
    else:
        speed = SPEED_DEFAULT

    travelled = path_length * ROUTE_FACTOR + fetch

    seconds = travelled / speed
    seconds += enemies * COST_PER_ENEMY
    seconds += sockets * COST_PER_SOCKET
    seconds += gates * COST_PER_GATE
    seconds += hazards * COST_PER_HAZARD
    seconds += pulsing * beat * PULSE_WAIT_SHARE
    # Only count launch walls on stages where they *are* the traversal; on a
    # combat stage they are scenery to slam things into.
    if enemies == 0 and kinetic_count == 0:
        seconds += walls * COST_PER_WALL
    if boss_id:
        seconds += BOSS_SECONDS.get(boss_id, 40.0)

    seconds *= GOLD_MARGIN

    return {
        "path": travelled,
        "speed": speed,
        "enemies": enemies,
        "sockets": sockets,
        "gates": gates,
        "pulsing": pulsing,
        "boss": boss_id,
        "hazards": hazards,
        "gold": seconds,
        "hardFloor": path_length / AUDIT_CEILING,
        "walls": walls,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true", help="rewrite StageConfig.luau")
    args = ap.parse_args()

    registered = dict(
        re.findall(
            r"(\w+) = require\(script\.Parent\.Layouts\.(\w+)\)",
            open(SERVICE, encoding="utf-8").read(),
        )
    )
    config = open(CONFIG, encoding="utf-8").read()
    current = {
        m.group(1): (int(m.group(2)), int(m.group(3)))
        for m in re.finditer(
            r'id = "(\w+)".*?Gold = seconds\((\d+)\).*?minPossibleMs = seconds\((\d+)\)',
            config,
            re.S,
        )
    }

    print(f"{'stage':22} {'route':>7} {'spd':>4} {'e':>3} {'s':>3} {'g':>3} {'p':>3} {'w':>3} "
          f"{'boss':>6} | {'gold':>6} {'silver':>7} {'bronze':>7} {'floor':>6} | {'was':>5} {'Δ':>6}")
    print("-" * 120)

    proposals = {}
    for stage_id, mod in sorted(registered.items()):
        a = analyse(os.path.join(LAYOUTS, f"{mod}.luau"))
        gold = max(12, round(a["gold"]))
        silver = round(gold * SILVER_RATIO)
        bronze = round(gold * BRONZE_RATIO)
        # Never below what physics allows, never near enough to gold to reject a
        # genuinely great run.
        floor = max(round(a["hardFloor"]), round(gold * FLOOR_RATIO))
        proposals[stage_id] = (gold, silver, bronze, floor)

        was_gold, _was_floor = current.get(stage_id, (0, 0))
        delta = gold - was_gold
        print(
            f"{mod:22} {a['path']:7.0f} {a['speed']:4.0f} {a['enemies']:3} {a['sockets']:3} "
            f"{a['gates']:3} {a['pulsing']:3} {a['walls']:3} {(a['boss'] or '-'):>6} | "
            f"{gold:6} {silver:7} {bronze:7} {floor:6} | {was_gold:5} {delta:+6}"
        )

    if not args.apply:
        print("\n(--apply to write these into StageConfig.luau)")
        return 0

    out = config
    for stage_id, (gold, silver, bronze, floor) in proposals.items():
        i = out.index(f'id = "{stage_id}"')
        j = out.index("\n\t},", i)
        entry = out[i:j]
        entry = re.sub(
            r"medals = \{ Gold = seconds\(\d+\), Silver = seconds\(\d+\), Bronze = seconds\(\d+\) \}",
            f"medals = {{ Gold = seconds({gold}), Silver = seconds({silver}), Bronze = seconds({bronze}) }}",
            entry,
        )
        entry = re.sub(r"minPossibleMs = seconds\(\d+\)", f"minPossibleMs = seconds({floor})", entry)
        out = out[:i] + entry + out[j:]

    open(CONFIG, "w", encoding="utf-8").write(out)
    print("\nStageConfig.luau updated")
    return 0


if __name__ == "__main__":
    sys.exit(main())
