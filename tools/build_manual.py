#!/usr/bin/env python3
"""Build the ROOTKIT field manual from the game's own source.

The manual is a reference, and a reference that disagrees with the game is
worse than no reference. So every number in the output is read out of the
GDScript rather than transcribed: change a module's damage and the next build
says so.

What CANNOT be derived is the prose — what a module is for, how an enemy
fights. That lives in NOTES below, and the build FAILS if a module or enemy
exists without one. A silent gap would be exactly the drift this exists to
prevent.

    python3 tools/build_manual.py          # writes site/index.html
    python3 tools/build_manual.py --check   # verify only, write nothing
"""

import html
import re
import string
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "site" / "index.html"


# --------------------------------------------------------------------------
# reading the game
# --------------------------------------------------------------------------

def src(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf-8")


def flat(text: str) -> str:
    """Join GDScript continuation lines so one declaration is one line."""
    return re.sub(r"\n\s+", " ", text)


def consts(rel: str) -> dict:
    """Every `const NAME := value` in a file, as text."""
    out = {}
    for m in re.finditer(r"^const ([A-Z_0-9]+) := (.+)$", src(rel), re.M):
        out[m.group(1)] = m.group(2).split("#")[0].strip()
    return out


def num(d: dict, key: str) -> float:
    """A constant's numeric value, resolving references to other constants.

    `const CORRIDOR_LENGTH := TILE * 12.0` is a clearer statement of the
    invariant than the literal 1152, but a scraper that only strips non-digits
    reads it as 12 and silently prints a twelve-unit corridor in the manual. So
    substitute names, then evaluate the arithmetic.
    """
    expr = d[key]
    for _ in range(8):                      # bounded: constants do not recurse
        names = set(re.findall(r"[A-Z_][A-Z_0-9]*", expr))
        resolvable = names & d.keys()
        if not resolvable:
            break
        for n in resolvable:
            expr = re.sub(r"\b%s\b" % n, "(%s)" % d[n], expr)
    if re.fullmatch(r"[0-9.+\-*/() ]+", expr):
        return float(eval(expr))            # digits and operators only
    return float(re.sub(r"[^0-9.\-]", "", expr))


def read_modules() -> list:
    body = src("data/module_table.gd")
    body = body[body.index("static func all()"):body.index("static func by_id")]
    rows = []
    for m in re.finditer(
            r'Module\.make\(&"(\w+)", "([^"]*)", S\.(\w+),\s*(\{[^}]*\})([^)]*)\)',
            flat(body)):
        mid, name, slot, stats, rest = m.groups()
        kind = re.search(r"[VT]\.(\w+)", rest)
        tags = re.findall(r'&"(\w+)"', rest.split("[", 1)[1].split("]", 1)[0]) \
            if "[" in rest else []
        rows.append({
            "id": mid, "name": name, "slot": slot,
            "kind": kind.group(1) if kind else "",
            "tags": tags,
            "stats": dict(re.findall(r'&"(\w+)": ([\d.e+-]+)', stats)),
        })
    return rows


def read_enemies() -> list:
    body = src("data/enemy_table.gd")
    body = body[body.index("static func all()"):]
    rows = []
    for m in re.finditer(
            r'EnemyType\.new\(&"(\w+)",\s*(\d+),\s*Color\(([^)]*)\),\s*'
            r'([\d.e+]+),\s*([\d.]+),\s*([\d.e+]+),\s*([\d.]+),\s*(\d+)'
            r'(?:,\s*Behaviour\.(\w+))?\)', flat(body)):
        rgb = [float(x) for x in m.group(3).split(",")]
        rows.append({
            "id": m.group(1),
            "color": "#%02x%02x%02x" % tuple(
                max(0, min(255, round(c * 255))) for c in rgb[:3]),
            "hp": float(m.group(4)), "speed": float(m.group(5)),
            "corrupt": float(m.group(6)), "contact": float(m.group(7)),
            "shards": int(m.group(8)),
            "behaviour": (m.group(9) or "CHASE").lower(),
        })
    return rows


def read_waves() -> list:
    out = []
    for m in re.finditer(
            r'Wave\.new\(([\d.]+),\s*([\d.]+),\s*(?:(\d+)|_idx\(&"(\w+)"\)),\s*'
            r'([\d.]+),\s*Formation\.(\w+)\)', src("scripts/run/spawn_director.gd")):
        t0, t1, idx, wid, rate, form = m.groups()
        out.append({"t0": float(t0), "t1": float(t1),
                    "index": int(idx) if idx else None, "id": wid,
                    "rate": float(rate), "formation": form.lower()})
    return out


def read_milestones() -> dict:
    body = src("scripts/meta/save_game.gd")
    body = body[body.index("const MILESTONES"):]
    body = body[:body.index("}")]
    return {m.group(1): (m.group(2), int(m.group(3)))
            for m in re.finditer(r'&"(\w+)":\s*\[&"(\w+)", (\d+)\]', body)}


def read_shop() -> list:
    body = src("scripts/meta/save_game.gd")
    out = []
    for block, mult in (("SHEET_EFFECT", False), ("MULT_EFFECT", True)):
        chunk = body[body.index("const " + block):]
        chunk = chunk[:chunk.index("\n}")]
        for m in re.finditer(r'&"(\w+)":\s*\{&"(\w+)": ([-\d.]+)\}', chunk):
            out.append({"id": m.group(1), "stat": m.group(2),
                        "per": float(m.group(3)), "mult": mult})
    return out


# --------------------------------------------------------------------------
# the authored half
# --------------------------------------------------------------------------

MODULE_NOTES = {
    "broadcast": "Hits everything in a ring around you. The reliable opener.",
    "packet": "A straight shot along your facing. Your starting weapon: aim by moving.",
    "chain": "Hops between enemies, jumping up to 120 units each time.",
    "beam": "A line along your facing through several enemies.",
    "spike": "A 90&deg; wedge along your facing. Heavy damage, demands facing.",
    "landmine": "Drops a charge a step behind you that waits until something comes within 46 units. Running lays a trail.",
    "bounce": "Shockwave with heavy knockback. Buys space rather than kills.",
    "mirror": "Shards orbit you, damaging on contact. Refiring replaces the ring rather than stacking it.",
    "checksum": "A payload: the row grants a shield on fire, absorbed before integrity, rearming every 2.6 s. On a head that already shields it only slows the refill.",
    "interval": "On a timer. The baseline every other trigger is measured against, and the only one that fires on an empty field.",
    "on_kill": "Every time anything dies. The generalist: rate plus power.",
    "on_hit": "Every time one of your shots connects. Pure rate &mdash; rewards pierce and chain.",
    "on_damage_taken": "When you are hit. Retaliation, in a burst.",
    "on_low_integrity": "When integrity crosses below 40% &mdash; once per crossing, rearming only after you climb back above it.",
    "on_flip": "When an enemy flips into your botnet. Pays in corruption, so it feeds the build that feeds it.",
    "on_level_up": "On gaining a level. The rarest event, and the biggest burst.",
    "buffer_overflow": "The plain damage payload.",
    "fork_bomb": "Adds area to a weapon that had none. Unrelated to the mini-boss of the same name.",
    "corrupt": "The main route to flipping enemies.",
    "keylog": "Heals on kills credited to this exploit.",
    "worm": "Corruption that also spreads.",
    "botnet_expand": "Raises how many flipped enemies can fight for you at once.",
    "overclock": "Faster and stronger. The strongest generic payload.",
    "harden": "Arms on fire. Wards take the max across exploits, never the sum.",
    "sandbox": "The longest ward; pairs well with a short one, which inherits its duration.",
    "nice": "Move faster while it is live.",
    "bitmask": "One more enemy per shot.",
    "race_condition": "Pure speed, at the cost of the slot.",
    "heap_spray": "Widens whatever it is attached to.",
    "tarpit": "Everything the weapon hits is slowed.",
}

ENEMY_NOTES = {
    "daemon": "The baseline swarm. Walks straight at you and dies in one hit for most of the run.",
    "firewall": "Slow and thick. The wall your damage has to grow past.",
    "worm": "Spawns as a train; segments follow the head&rsquo;s trail. Passes through terrain.",
    "sentinel": "Closes, telegraphs, then dashes at 3&times; speed along a <strong>locked</strong> direction and overshoots. Sidestep late.",
    "tracer": "Steers at where you are going, arcing the way you are heading to close your kiting lane. Fragile; dangerous in numbers.",
    "watchdog": "Holds back and heals everything near it, capped at each enemy&rsquo;s spawn integrity. Kill it first.",
    "rootkit": "Submerges &mdash; untouchable and harmless while under &mdash; then surfaces on you after a tell.",
    "probe": "Holds its distance and fires a leading shot. Its shots stop on walls, which is what makes cover worth using.",
    "fork_bomb": "Charges. On death it divides in two at half integrity, three generations deep, before the leaves die for good.",
    "packet_filter": "Heals the swarm, and takes <strong>90% less damage from the front</strong>. Facing is its movement direction, so getting behind it is a manoeuvre rather than a stat check.",
    "null_ptr": "Blinks on a short ambush cycle, leaving a damaging afterimage at every point it vanishes. A long fight progressively denies you ground.",
    "kernel_panic": "Shoots, and periodically pulses everything <strong>with line of sight to it</strong>. Putting a wall between you and it is the only answer.",
    "ice": "The subnet&rsquo;s ending. The field is purged to make room for it. It cannot be flipped &mdash; that would bypass the kill-to-win condition.",
}

SHOP_NOTES = {
    "memory": "Raises the integrity you start every subnet with.",
    "firewall": "Flat reduction on every hit taken.",
    "encryption": "Proportional mitigation, stacking with armour.",
    "bus_speed": "You move faster. The most direct answer to the collapse.",
    "bandwidth": "Shards come to you from further away.",
    "cpu_cycles": "Scales damage and corruption on every exploit.",
    "cooling": "Everything fires faster.",
    "addressing": "Scales radius and projectile travel.",
}

BEHAVIOUR_COLOR = {
    "chase": "#4dff8c", "charger": "#ffbf40", "flanker": "#8cfff2",
    "support": "#b3d9ff", "ambusher": "#d973ff", "ranged": "#ff8c8c",
}

STAT_LABEL = {
    "damage": "dmg", "corruption": "corr", "cooldown": "cadence",
    "radius": "reach", "projectile_speed": "speed", "travel": "travel",
    "chain_count": "hops", "pierce": "pierce", "cadence_mult": "cadence &times;",
    "knockback": "knock", "slow_amount": "slow", "slow_duration": "slow s",
    "shield": "shield", "orbit_count": "orbiters", "burst": "burst",
    "lifesteal": "lifesteal", "botnet_cap": "botnet", "ward_armor": "ward armour",
    "ward_defense": "ward defence", "ward_clock_speed": "ward speed",
    "ward_duration": "ward s", "shield_rearm": "rearm s",
}


def check_notes(modules, enemies, shop) -> list:
    """A module without prose is drift waiting to happen. Fail loudly."""
    gaps = []
    for m in modules:
        if m["id"] not in MODULE_NOTES:
            gaps.append("module '%s' has no note in MODULE_NOTES" % m["id"])
    for e in enemies:
        if e["id"] not in ENEMY_NOTES:
            gaps.append("enemy '%s' has no note in ENEMY_NOTES" % e["id"])
    for s in shop:
        if s["id"] not in SHOP_NOTES:
            gaps.append("upgrade '%s' has no note in SHOP_NOTES" % s["id"])
    return gaps


# --------------------------------------------------------------------------
# rendering
# --------------------------------------------------------------------------

def esc(x) -> str:
    return html.escape(str(x))


def fmt(v: float) -> str:
    return ("%g" % v)


def stat_cell(m: dict) -> str:
    bits = []
    for k, v in m["stats"].items():
        bits.append("%s&nbsp;%s" % (STAT_LABEL.get(k, esc(k)), fmt(float(v))))
    return " &middot; ".join(bits) or "&mdash;"


def lock_tag(mid: str, milestones: dict, locked: list) -> str:
    if mid not in locked:
        return ""
    if mid in milestones:
        counter, n = milestones[mid]
        return '<span class="tag lock">%d %s</span>' % (n, esc(counter))
    return '<span class="tag lock">locked</span>'


def module_rows(modules, slot, milestones, locked) -> str:
    cls = {"VECTOR": "v", "TRIGGER": "t", "PAYLOAD": "p"}[slot]
    out = []
    for m in modules:
        if m["slot"] != slot:
            continue
        out.append(
            '<tr class="%s"><td class="stripe name">%s%s</td>'
            '<td class="note">%s</td><td class="note dimmed">%s</td></tr>' % (
                cls, esc(m["name"]), lock_tag(m["id"], milestones, locked),
                MODULE_NOTES[m["id"]], stat_cell(m)))
    return "\n".join(out)


def build() -> str:
    mods = read_modules()
    enemies = read_enemies()
    waves = read_waves()
    milestones = read_milestones()
    shop = read_shop()

    gaps = check_notes(mods, enemies, shop)
    if gaps:
        raise SystemExit("manual is out of date:\n  " + "\n  ".join(gaps))

    sd = consts("scripts/run/spawn_director.gd")
    rn = consts("scripts/run/run.gd")
    tr = consts("scripts/run/terrain.gd")
    lo = consts("scripts/build/loadout.gd")
    ex = consts("scripts/build/exploit.gd")
    sg = consts("scripts/meta/save_game.gd")

    locked = re.findall(r'&"(\w+)"', src("data/module_table.gd").split(
        "const LOCKED := [", 1)[1].split("]", 1)[0])

    subnet_s = num(sd, "SUBNET_SECONDS")
    arena = re.findall(r"[\d.]+", rn["ARENA_SIZE"])
    mb_times = [float(x) for x in re.findall(r"[\d.]+", sd["MINIBOSS_TIMES"])]
    mb_ids = re.findall(r'&"(\w+)"', sd["MINIBOSS_IDS"])
    xp = num(rn, "XP_SLOWDOWN")
    xp_seq = ", ".join(str(round((5 + 3 * (n - 1)) * xp)) for n in range(1, 6))

    by_id = {e["id"]: e for e in enemies}
    ordinary = [e for e in enemies if e["id"] not in mb_ids and e["id"] != "ice"]
    setpieces = [by_id[i] for i in mb_ids if i in by_id] + \
        ([by_id["ice"]] if "ice" in by_id else [])

    # ---- timeline ----
    tl_by_type = {}
    for w in waves:
        key = w["id"] or (enemies[w["index"]]["id"] if w["index"] is not None
                          and w["index"] < len(enemies) else "?")
        tl_by_type.setdefault(key, []).append(w)
    tl_rows = []
    for key, ws in tl_by_type.items():
        colour = by_id.get(key, {}).get("color", "#599e7a")
        bars = "".join(
            '<div class="tl-bar" style="left:%.2f%%;width:%.2f%%"><span>%s</span></div>'
            % (w["t0"] / subnet_s * 100, (w["t1"] - w["t0"]) / subnet_s * 100,
               fmt(w["rate"])) for w in ws)
        tl_rows.append(
            '<div class="tl-row"><div class="tl-label">%s</div>'
            '<div class="tl-track" style="color:%s">%s</div></div>'
            % (esc(key), colour, bars))
    marks = "".join(
        '<div class="tl-mark" style="left:%.2f%%" data-l="%s"></div>'
        % (t / subnet_s * 100, esc(i)) for t, i in zip(mb_times, mb_ids))
    marks += '<div class="tl-mark" style="left:99.6%" data-l="ICE"></div>'

    # ---- enemy tables ----
    def enemy_rows(rows, extra_at=None):
        out = []
        for e in rows:
            at = ""
            if extra_at:
                at = '<td class="num">%s</td>' % extra_at.get(e["id"], "&mdash;")
            corrupt = "&mdash;" if e["corrupt"] > 1e6 else fmt(e["corrupt"])
            out.append(
                '<tr><td class="name" style="color:%s"><i class="glyph"></i>%s</td>'
                '%s<td>%s</td><td class="num">%s</td><td class="num">%s</td>'
                '<td class="num">%s</td><td class="num">%s</td><td class="num">%s</td>'
                '<td class="note">%s</td></tr>' % (
                    e["color"], esc(e["id"]), at, esc(e["behaviour"]),
                    fmt(e["hp"]), fmt(e["speed"]), corrupt,
                    fmt(e["contact"]), e["shards"], ENEMY_NOTES[e["id"]]))
        return "\n".join(out)

    mb_at = {i: "%d:%02d" % (t // 60, t % 60) for i, t in zip(mb_ids, mb_times)}
    mb_at["ice"] = "%d:%02d" % (subnet_s // 60, subnet_s % 60)

    shop_rows = "\n".join(
        '<tr><td class="name">%s</td><td>%s%s %s</td><td class="num">%s%s</td>'
        '<td class="note">%s</td></tr>' % (
            esc(s["id"]),
            "+" if s["per"] > 0 else "",
            fmt(s["per"] * 100) + "%" if s["mult"] else fmt(s["per"]),
            esc(s["stat"].replace("_", " ")),
            fmt(s["per"] * num(sg, "BUFF_MAX") * (100 if s["mult"] else 1)),
            "%" if s["mult"] else "",
            SHOP_NOTES[s["id"]])
        for s in shop)

    return string.Template(TEMPLATE).substitute(
        arena_w=arena[0], arena_h=arena[1],
        subnets=int(num(sd, "CAMPAIGN_SUBNETS")),
        subnet_min="%d:%02d" % (subnet_s // 60, subnet_s % 60),
        n_enemies=len(enemies), n_modules=len(mods),
        exploits=int(num(lo, "MAX_EXPLOITS")),
        payload_slots=int(num(ex, "PAYLOAD_SLOTS")),
        xp_slow=fmt(xp), xp_seq=xp_seq,
        hp_sub=fmt(num(sd, "HP_PER_SUBNET")), hp_over=fmt(num(sd, "HP_OVER_SUBNET")),
        heal=int(num(rn, "SUBNET_CLEAR_HEAL") * 100),
        collapse=int(num(rn, "COLLAPSE_SECONDS")),
        mb_salvage=int(num(rn, "MINIBOSS_SALVAGE")),
        splits=int(num(rn, "SPLIT_GENERATIONS")),
        front=int(num(rn, "FILTER_FRONT_SCALE") * 100),
        low=int(num(rn, "LOW_INTEGRITY_FRACTION") * 100),
        density=fmt(num(tr, "DENSITY_BASE") * 100),
        hazard=fmt(num(tr, "HAZARD_DPS")),
        slowpct=int(num(tr, "SLOW_FACTOR") * 100),
        corrsec=fmt(num(tr, "CORRUPTION_PER_SEC")),
        corridor=int(num(tr, "CORRIDOR_LENGTH")),
        buff_base=int(num(sg, "BUFF_COST_BASE")),
        buff_step=int(num(sg, "BUFF_COST_STEP")),
        buff_max=int(num(sg, "BUFF_MAX")),
        buff_last=int(num(sg, "BUFF_COST_BASE")
                      + num(sg, "BUFF_COST_STEP") * (num(sg, "BUFF_MAX") - 1)),
        n_unlocked=len(mods) - len(locked), n_locked=len(locked),
        timeline="\n".join(tl_rows), marks=marks,
        ordinary=enemy_rows(ordinary), setpieces=enemy_rows(setpieces, mb_at),
        vectors=module_rows(mods, "VECTOR", milestones, locked),
        triggers=module_rows(mods, "TRIGGER", milestones, locked),
        payloads=module_rows(mods, "PAYLOAD", milestones, locked),
        shop=shop_rows,
    )


# Read eagerly and without a fallback: an empty template would substitute
# cleanly into an empty page, and a build that "succeeds" into nothing is worse
# than one that stops.
TEMPLATE = (ROOT / "tools" / "manual_template.html").read_text(encoding="utf-8")


if __name__ == "__main__":
    page = build()
    if "--check" in sys.argv:
        print("manual builds clean: %d bytes" % len(page))
    else:
        OUT.parent.mkdir(parents=True, exist_ok=True)
        OUT.write_text(page, encoding="utf-8")
        print("wrote %s (%d bytes)" % (OUT.relative_to(ROOT), len(page)))
