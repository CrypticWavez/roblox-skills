"""Offline analytics report for exported event JSONL. Reads a file, never the network.

  python3 tools/analytics_report.py EVENTS.jsonl [--start ISO --end ISO] [--include-synthetic]
                                    [--console] [--out REPORT.json]

Two input formats, detected from the rows (a file mixing them is refused, exit 2):

* kit-event/1 (GameKit/Events, docs/runtime-kits.md section 9.1): funnel conversion per step,
  onboarding conversion, economy sources and sinks per currency and transaction type,
  progression drop-off per path and level, custom event counts and purchase-intent stages per
  product. --console accepts raw Studio output: lines starting with "TELEMETRY_JSON " (the
  TelemetryRoblox recorder) are read and every other line is ignored.
* legacy session rows (schema_version 1, fixtures/analytics/neutral_events.jsonl): per-cohort
  session metrics inside an explicit window (--start and --end are required).

Synthetic, Lune, Studio and test traffic is excluded unless --include-synthetic (synthetic
only; test and staging environments are always excluded). Duplicate event_ids count once.
The report is observation only: no retention, revenue, ranking or enjoyment claims (see the
"limitations" list it prints). Exit codes: 0 report written, 2 bad input or arguments.
"""
import argparse
import hashlib
import json
import math
import sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone

KIT_SCHEMA = "kit-event/1"
KIT_FORMAT = "kit-event-report/1"
CONSOLE_PREFIX = "TELEMETRY_JSON "
SYNTHETIC_ENVIRONMENTS = {"lune", "studio"}
PRODUCTION_ENVIRONMENTS = {"production", "live"}
PURCHASE_STAGES = ["offer_viewed", "prompted", "prompt_closed", "granted", "failed"]

LEGACY_LIMITATIONS = [
    "Session metrics only; no persistent player identity, D1/D7 retention, revenue, or unique-player count is inferred.",
    "The input must be a complete session event export through the declared end; this tool cannot detect silent telemetry loss.",
    "Window-edge sessions lack follow-up and are excluded from fixed-horizon denominators.",
    "Purchase metrics are observed session funnels, not durable purchase accounting or lifetime conversion; delayed receipts can arrive in other sessions.",
    "No discovery ranking prediction, revenue estimate, causal effect, or human enjoyment claim.",
    "Synthetic cohorts are separated and never treated as observed players.",
]
KIT_LIMITATIONS = [
    "Counts what the export holds; it cannot detect events dropped by the Telemetry budget, sink errors or a partial export.",
    "Funnel and onboarding conversion count distinct funnel sessions and players that reached each step; Roblox dashboards may treat skipped steps differently.",
    "Purchase intent is an observed prompt funnel, not purchase accounting; grants come from processed receipts that may land in other sessions.",
    "Economy totals are the logged amounts, not a ledger reconciliation.",
    "No retention, revenue estimate, discovery ranking prediction, causal effect, or human enjoyment claim.",
    "Synthetic, Lune and Studio rows are excluded unless --include-synthetic, and are never treated as observed players.",
]


class InputError(Exception):
    pass


def parse_time(text):
    if not isinstance(text, str):
        raise ValueError("timestamp must be a string")
    value = datetime.fromisoformat(text.replace("Z", "+00:00"))
    if value.tzinfo is None:
        raise ValueError(f"timestamp {text!r} has no timezone")
    return value.astimezone(timezone.utc)


def rate(numerator, denominator):
    return {
        "numerator": numerator,
        "denominator": denominator,
        "rate": round(numerator / denominator, 4) if denominator else None,
    }


def ratio(numerator, denominator):
    return round(numerator / denominator, 4) if denominator else None


def nearest_rank(values, percentile):
    if not values:
        return None
    ordered = sorted(values)
    index = max(1, math.ceil(percentile / 100 * len(ordered)))
    return float(ordered[index - 1])


def read_rows(raw, console):
    rows = []
    for number, line in enumerate(raw.decode("utf-8").splitlines(), start=1):
        text = line.strip()
        if console:
            position = text.find(CONSOLE_PREFIX)
            if position < 0:
                continue
            text = text[position + len(CONSOLE_PREFIX):]
        if not text:
            continue
        try:
            row = json.loads(text)
        except json.JSONDecodeError as error:
            raise InputError(f"line {number}: not JSON ({error.msg})") from error
        if not isinstance(row, dict):
            raise InputError(f"line {number}: not a JSON object")
        rows.append(row)
    return rows


def detect_format(rows):
    kinds = set()
    for row in rows:
        if row.get("schema") == KIT_SCHEMA:
            kinds.add("kit")
        elif row.get("schema_version") == 1:
            kinds.add("legacy")
        else:
            kinds.add("unknown")
    if not rows:
        raise InputError("no events in the input")
    if len(kinds) > 1:
        raise InputError(f"mixed or unknown row formats: {sorted(kinds)}")
    kind = kinds.pop()
    if kind == "unknown":
        raise InputError("rows are neither kit-event/1 nor legacy schema_version 1")
    return kind


def count_into(counter, key):
    counter[key] = counter.get(key, 0) + 1


# ---------------------------------------------------------------- legacy session report


def legacy_report(rows, start, end, include_synthetic, digest):
    excluded = {}
    anomalies = {}
    duplicates = 0
    seen_ids = set()
    kept = []
    for row in rows:
        if row.get("environment") not in PRODUCTION_ENVIRONMENTS:
            count_into(excluded, "test_or_staging_events")
            continue
        if row.get("synthetic") is True and not include_synthetic:
            count_into(excluded, "synthetic_events")
            continue
        try:
            when = parse_time(row.get("timestamp"))
        except ValueError:
            count_into(excluded, "invalid_timestamp")
            continue
        if not (start <= when < end):
            count_into(excluded, "outside_window")
            continue
        event_id = row.get("event_id")
        if event_id is not None:
            if event_id in seen_ids:
                duplicates += 1
                continue
            seen_ids.add(event_id)
        kept.append((when, row))

    sessions = defaultdict(list)
    for when, row in kept:
        session_id = row.get("session_id")
        if not isinstance(session_id, str) or not session_id:
            count_into(anomalies, "events_without_session")
            continue
        sessions[session_id].append((when, row))

    cohorts = {}
    for session_id, events in sessions.items():
        events.sort(key=lambda item: item[0])
        starts = [item for item in events if item[1].get("name") == "session_start"]
        if not starts:
            count_into(anomalies, "sessions_without_start")
            continue
        started_at, first = starts[0]
        key = (
            first.get("cohort_id"),
            first.get("build_id"),
            first.get("acquisition"),
            bool(first.get("synthetic")),
        )
        cohorts.setdefault(key, []).append((started_at, events))

    out_cohorts = []
    for key in sorted(cohorts, key=lambda item: tuple("" if part is None else str(part) for part in item)):
        out_cohorts.append(cohort_metrics(key, cohorts[key], end))

    report = {
        "schema_version": 1,
        "status": "partially_verified",
        "mode": "offline_report",
        "window": {"start_inclusive": start.isoformat(), "end_exclusive": end.isoformat()},
        "synthetic_opt_in": include_synthetic,
        "duplicate_events_ignored": duplicates,
        "excluded_events": dict(sorted(excluded.items())),
        "anomalies": dict(sorted(anomalies.items())),
        "cohorts": out_cohorts,
        "limitations": LEGACY_LIMITATIONS,
        "input_sha256": digest,
    }
    return report


def cohort_metrics(key, sessions, end):
    cohort_id, build_id, acquisition, synthetic = key
    started = len(sessions)
    eligible_60 = 0
    eligible_300 = 0
    counts = defaultdict(int)
    first_action_times = []
    loading_times = []
    sources = 0
    sinks = 0
    offered = 0
    offer_prompted = 0
    prompted = 0
    confirmed = 0
    for started_at, events in sessions:
        offsets = defaultdict(list)
        for when, row in events:
            offsets[row.get("name")].append((when - started_at).total_seconds())
            if row.get("name") == "economy_source":
                sources += row.get("value", 0)
            elif row.get("name") == "economy_sink":
                sinks += row.get("value", 0)

        def first(name):
            values = offsets.get(name)
            return min(values) if values else None

        in_60 = started_at + timedelta(seconds=60) <= end
        in_300 = started_at + timedelta(seconds=300) <= end
        eligible_60 += in_60
        eligible_300 += in_300
        load = first("load_finished")
        action = first("first_action")
        onboarding = first("onboarding_complete")
        core = first("core_loop_complete")
        ended = first("session_end")
        if load is not None:
            counts["load_success"] += 1
            loading_times.append(load)
        if first("load_failed") is not None:
            counts["load_failure"] += 1
        ordered_action = load is not None and action is not None and action >= load
        if ordered_action:
            first_action_times.append(action)
        if in_60:
            if ordered_action and action <= 60:
                counts["first_action_within_60s"] += 1
            if ended is not None and ended <= 60:
                counts["observed_exit_before_60s"] += 1
        if in_300:
            if onboarding is not None and onboarding <= 300:
                counts["onboarding_within_5m"] += 1
            if ordered_action and core is not None and action <= core <= 300:
                counts["ordered_core_loop_within_5m"] += 1
        for name in ("session_error", "social_action", "progression_step"):
            if first(name) is not None:
                counts[name] += 1
        offer = first("offer_viewed")
        prompt = first("purchase_prompted")
        confirm = first("purchase_confirmed")
        if offer is not None:
            offered += 1
            if prompt is not None and prompt >= offer:
                offer_prompted += 1
        if prompt is not None:
            prompted += 1
            if confirm is not None and confirm >= prompt:
                confirmed += 1

    return {
        "cohort_id": cohort_id,
        "build_id": build_id,
        "acquisition": acquisition,
        "synthetic": synthetic,
        "sessions_started": started,
        "excluded_from_60s_denominator": started - eligible_60,
        "excluded_from_5m_denominator": started - eligible_300,
        "load_success": rate(counts["load_success"], started),
        "load_failure": rate(counts["load_failure"], started),
        "first_action_within_60s": rate(counts["first_action_within_60s"], eligible_60),
        "onboarding_within_5m": rate(counts["onboarding_within_5m"], eligible_300),
        "ordered_core_loop_within_5m": rate(counts["ordered_core_loop_within_5m"], eligible_300),
        "observed_exit_before_60s": rate(counts["observed_exit_before_60s"], eligible_60),
        "session_error": rate(counts["session_error"], started),
        "social_action": rate(counts["social_action"], started),
        "progression_step": rate(counts["progression_step"], started),
        "offer_to_prompt": rate(offer_prompted, offered),
        "prompt_to_confirmation": rate(confirmed, prompted),
        "time_to_first_action_seconds": {
            "sample_sessions": len(first_action_times),
            "p50": nearest_rank(first_action_times, 50),
            "p95": nearest_rank(first_action_times, 95),
            "population": "ordered converters only",
        },
        "loading_seconds": {
            "sample_sessions": len(loading_times),
            "p50": nearest_rank(loading_times, 50),
            "p95": nearest_rank(loading_times, 95),
        },
        "economy_units": {"sources": sources, "sinks": sinks, "net": sources - sinks},
    }


# ---------------------------------------------------------------- kit-event/1 report

REQUIRED_BODY = {
    "economy": ("economy", ("flow", "currency", "amount", "transaction_type")),
    "progression": ("progression", ("path", "status", "level")),
    "funnel": ("funnel", ("funnel", "step", "step_name", "funnel_session_id")),
    "onboarding": ("onboarding", ("step", "step_name")),
    "purchase_intent": ("purchase", ("stage", "product", "kind")),
}


def kit_row_problem(row):
    category = row.get("category")
    if category == "custom":
        return None if isinstance(row.get("name"), str) else "custom event without a name"
    if category not in REQUIRED_BODY:
        return f"unknown category {category!r}"
    key, fields = REQUIRED_BODY[category]
    body = row.get(key)
    if not isinstance(body, dict):
        return f"{category} event without a {key} body"
    missing = [field for field in fields if field not in body]
    return f"{category} body misses {missing}" if missing else None


def kit_report(rows, start, end, include_synthetic, digest):
    excluded = {}
    duplicates = 0
    seen_ids = set()
    kept = []
    for row in rows:
        environment = row.get("environment")
        if environment is not None and environment not in PRODUCTION_ENVIRONMENTS | SYNTHETIC_ENVIRONMENTS:
            count_into(excluded, "test_or_staging_events")
            continue
        synthetic = row.get("synthetic") is True or environment in SYNTHETIC_ENVIRONMENTS
        if synthetic and not include_synthetic:
            count_into(excluded, "synthetic_events")
            continue
        if start is not None:
            try:
                when = parse_time(row.get("timestamp"))
            except ValueError:
                count_into(excluded, "missing_timestamp")
                continue
            if not (start <= when < end):
                count_into(excluded, "outside_window")
                continue
        if kit_row_problem(row) is not None:
            count_into(excluded, "invalid_events")
            continue
        event_id = row.get("event_id")
        if event_id is not None:
            if event_id in seen_ids:
                duplicates += 1
                continue
            seen_ids.add(event_id)
        kept.append(row)

    funnels = defaultdict(lambda: defaultdict(set))
    funnel_names = defaultdict(dict)
    onboarding = defaultdict(set)
    onboarding_names = {}
    economy = defaultdict(lambda: {"sources": defaultdict(float), "sinks": defaultdict(float), "events": 0})
    progression = defaultdict(lambda: defaultdict(lambda: {"start": set(), "complete": set(), "fail": set()}))
    custom = defaultdict(lambda: {"count": 0, "value_sum": 0.0, "with_value": 0})
    purchases = defaultdict(lambda: {stage: 0 for stage in PURCHASE_STAGES})
    players = set()

    for row in kept:
        category = row["category"]
        player = row.get("player") or ""
        if player:
            players.add(player)
        if category == "funnel":
            body = row["funnel"]
            funnels[body["funnel"]][body["step"]].add(body["funnel_session_id"])
            funnel_names[body["funnel"]].setdefault(body["step"], body["step_name"])
        elif category == "onboarding":
            body = row["onboarding"]
            onboarding[body["step"]].add(player)
            onboarding_names.setdefault(body["step"], body["step_name"])
        elif category == "economy":
            body = row["economy"]
            entry = economy[body["currency"]]
            side = "sources" if body["flow"] == "source" else "sinks"
            entry[side][body["transaction_type"]] += body["amount"]
            entry["events"] += 1
        elif category == "progression":
            body = row["progression"]
            if body["status"] in ("start", "complete", "fail"):
                progression[body["path"]][body["level"]][body["status"]].add(player)
        elif category == "custom":
            entry = custom[row["name"]]
            entry["count"] += 1
            if isinstance(row.get("value"), (int, float)):
                entry["value_sum"] += row["value"]
                entry["with_value"] += 1
        elif category == "purchase_intent":
            body = row["purchase"]
            if body["stage"] in PURCHASE_STAGES:
                purchases[body["product"]][body["stage"]] += 1

    def number(value):
        return int(value) if float(value).is_integer() else round(value, 4)

    def step_table(steps, names, unit):
        out = []
        first_count = len(steps.get(min(steps), ())) if steps else 0
        previous = None
        for step in sorted(steps):
            reached = len(steps[step])
            out.append(
                {
                    "step": step,
                    "step_name": names.get(step),
                    unit: reached,
                    "conversion_from_previous": ratio(reached, previous) if previous is not None else None,
                    "conversion_from_first": ratio(reached, first_count),
                }
            )
            previous = reached
        return out

    report = {
        "format": KIT_FORMAT,
        "status": "partially_verified",
        "mode": "offline_report",
        "window": None
        if start is None
        else {"start_inclusive": start.isoformat(), "end_exclusive": end.isoformat()},
        "synthetic_opt_in": include_synthetic,
        "events_read": len(rows),
        "events_used": len(kept),
        "players_observed": len(players),
        "duplicate_events_ignored": duplicates,
        "excluded_events": dict(sorted(excluded.items())),
        "funnels": {
            name: {"steps": step_table(funnels[name], funnel_names[name], "sessions")}
            for name in sorted(funnels)
        },
        "onboarding": {"steps": step_table(onboarding, onboarding_names, "players")},
        "economy": {
            currency: {
                "sources": {kind: number(amount) for kind, amount in sorted(entry["sources"].items())},
                "sinks": {kind: number(amount) for kind, amount in sorted(entry["sinks"].items())},
                "source_total": number(sum(entry["sources"].values())),
                "sink_total": number(sum(entry["sinks"].values())),
                "net": number(sum(entry["sources"].values()) - sum(entry["sinks"].values())),
                "events": entry["events"],
            }
            for currency, entry in sorted(economy.items())
        },
        "progression": {
            path: {
                "levels": [
                    {
                        "level": level,
                        "started": len(levels[level]["start"]),
                        "completed": len(levels[level]["complete"]),
                        "failed": len(levels[level]["fail"]),
                        "drop_off": ratio(
                            len(levels[level]["start"] - levels[level]["complete"]), len(levels[level]["start"])
                        ),
                    }
                    for level in sorted(levels)
                ]
            }
            for path, levels in sorted(progression.items())
        },
        "custom": {
            name: {
                "count": entry["count"],
                "value_sum": number(entry["value_sum"]) if entry["with_value"] else None,
            }
            for name, entry in sorted(custom.items())
        },
        "purchase_intent": {
            product: dict(
                stages,
                offer_to_prompt=ratio(stages["prompted"], stages["offer_viewed"]),
                prompt_to_grant=ratio(stages["granted"], stages["prompted"]),
            )
            for product, stages in sorted(purchases.items())
        },
        "limitations": KIT_LIMITATIONS,
        "input_sha256": digest,
    }
    return report


# ---------------------------------------------------------------- command line


def build_report(raw, start=None, end=None, include_synthetic=False, console=False):
    """The report for raw input bytes (raises InputError on bad input or arguments)."""
    digest = hashlib.sha256(raw).hexdigest()
    rows = read_rows(raw, console)
    kind = detect_format(rows)
    if (start is None) != (end is None):
        raise InputError("--start and --end go together")
    if start is not None and not start < end:
        raise InputError("--start must be before --end")
    if kind == "legacy":
        if start is None:
            raise InputError("legacy session rows need --start and --end")
        return legacy_report(rows, start, end, include_synthetic, digest)
    return kit_report(rows, start, end, include_synthetic, digest)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("events", help="JSONL export (kit-event/1 or legacy schema_version 1 rows)")
    parser.add_argument("--start", help="window start, inclusive (ISO 8601 with timezone)")
    parser.add_argument("--end", help="window end, exclusive (ISO 8601 with timezone)")
    parser.add_argument("--include-synthetic", action="store_true", help="count synthetic, Lune and Studio rows")
    parser.add_argument("--console", action="store_true", help="read TELEMETRY_JSON lines from Studio output")
    parser.add_argument("--out", help="write the report here instead of stdout")
    args = parser.parse_args(argv)
    try:
        start = parse_time(args.start) if args.start else None
        end = parse_time(args.end) if args.end else None
        with open(args.events, "rb") as handle:
            raw = handle.read()
        report = build_report(raw, start, end, args.include_synthetic, args.console)
    except (InputError, ValueError, OSError) as error:
        print(f"analytics_report: {error}", file=sys.stderr)
        return 2
    text = json.dumps(report, indent=2) + "\n"
    if args.out:
        with open(args.out, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
