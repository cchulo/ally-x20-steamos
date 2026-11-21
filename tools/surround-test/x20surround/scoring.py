# SPDX-License-Identifier: GPL-2.0-only
"""Scoring of the listening tests and the pass rule. Pure functions.

The pass rule, fixed before any listening (README.md): a candidate must
beat raw on localisation and not lose on tone, in two sessions on different
days.
"""

from .layout import SIDE, SPEAKERS

RAW = "raw"

# Answer keys of the localisation test, laid out like the loudspeakers:
#   1 front-left   2 centre   3 front-right
#   4 side-left               5 side-right
#   6 rear-left               7 rear-right
ANSWERS = {"1": "FL", "2": "FC", "3": "FR", "4": "SL", "5": "SR", "6": "RL", "7": "RR"}
NAMES = {"FL": "front-left", "FC": "centre", "FR": "front-right", "SL": "side-left",
         "SR": "side-right", "RL": "rear-left", "RR": "rear-right"}
FRONT = ("FL", "FC", "FR")
BACK = ("RL", "RR")
REQUIRED_DAYS = 2


def front_back(presented, answered):
    return (presented in FRONT and answered in BACK) or (presented in BACK and answered in FRONT)


def left_right(presented, answered):
    a, b = SIDE[presented], SIDE[answered]
    return a is not None and b is not None and a != b


def score(trials):
    """trials: [(presented, answered)]. Returns the localisation scores."""
    by = {c: [0, 0] for c in SPEAKERS}
    hits = fb = lr = 0
    for presented, answered in trials:
        by[presented][1] += 1
        if presented == answered:
            hits += 1
            by[presented][0] += 1
        fb += front_back(presented, answered)
        lr += left_right(presented, answered)
    n = len(trials)
    return {"trials": n, "hits": hits, "hit_rate": (hits / n) if n else 0.0,
            "front_back": fb, "left_right": lr, "by_channel": by}


def tone_tally(rounds):
    """rounds: ["candidate" | "raw" | "none", ...]."""
    return {"candidate": rounds.count("candidate"), "raw": rounds.count("raw"),
            "none": rounds.count("none")}


def day_results(records):
    """Group complete log records by (device, candidate, date).

    Returns {(device, candidate): {date: {"localise": (cand hits, cand n,
    raw hits, raw n) or None, "tone": (cand wins, raw wins) or None}}}.
    """
    out = {}
    for rec in records:
        if not rec.get("complete"):
            continue
        date = str(rec.get("time", ""))[:10]
        device = rec.get("device", "?")
        if rec.get("test") == "localise":
            conds = {c["id"]: c for c in rec.get("conditions", [])}
            raw = conds.get(RAW)
            if not raw:
                continue
            for cid, c in conds.items():
                if cid == RAW:
                    continue
                day = out.setdefault((device, cid), {}).setdefault(date, {})
                prev = day.get("localise") or (0, 0, 0, 0)
                day["localise"] = (prev[0] + c["hits"], prev[1] + c["trials"],
                                   prev[2] + raw["hits"], prev[3] + raw["trials"])
        elif rec.get("test") == "tone":
            for c in rec.get("conditions", []):
                day = out.setdefault((device, c["id"]), {}).setdefault(date, {})
                prev = day.get("tone") or (0, 0)
                day["tone"] = (prev[0] + c["candidate"], prev[1] + c["raw"])
    return out


def day_passes(day):
    """A day counts when both tests were run and the candidate beat raw on
    localisation (higher hit rate) and did not lose on tone."""
    loc, tone = day.get("localise"), day.get("tone")
    if not loc or not tone or not loc[1] or not loc[3]:
        return False
    return loc[0] / loc[1] > loc[2] / loc[3] and tone[0] >= tone[1]


def verdicts(records):
    """{(device, candidate): {"days": {date: bool}, "passed": bool}}."""
    out = {}
    for key, days in day_results(records).items():
        flags = {date: day_passes(day) for date, day in days.items()}
        out[key] = {"days": flags, "detail": days,
                    "passed": sum(flags.values()) >= REQUIRED_DAYS}
    return out
