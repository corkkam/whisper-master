#!/usr/bin/env python3
"""Create the Whisper Master product dashboards in PostHog and GA4.

The Mac app already ships a typed event catalog (`AnalyticsEvent`). This script
is the other half: the saved views those events are meant to land in. It is
idempotent — re-running updates existing dashboards/insights/dimensions rather
than duplicating them.

Auth (neither is the client `phc_` / Measurement Protocol secret):

  POSTHOG_PERSONAL_API_KEY   PostHog → Settings → Personal API keys
                             scopes: dashboard:write, insight:write, project:read
  POSTHOG_PROJECT_ID         optional; discovered from the first project if unset
  POSTHOG_HOST               default https://us.posthog.com

  Google: application-default credentials with analytics.edit, e.g.
    gcloud auth application-default login \\
      --scopes=https://www.googleapis.com/auth/analytics.edit,\\
https://www.googleapis.com/auth/analytics.readonly,\\
https://www.googleapis.com/auth/cloud-platform
  GA_MEASUREMENT_ID          already in `.env` (G-E9H8VNWSB5)
  GA_PROPERTY_ID             optional; discovered from the measurement ID

Usage:
    python3 Scripts/setup-analytics-dashboards.py
    python3 Scripts/setup-analytics-dashboards.py --dry-run
    python3 Scripts/setup-analytics-dashboards.py --posthog-only
    python3 Scripts/setup-analytics-dashboards.py --ga-only
"""

from __future__ import annotations

import argparse
import json
import os
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ENV_PATH = ROOT / ".env"

POSTHOG_HOST_DEFAULT = "https://us.posthog.com"
INSIGHT_PREFIX = "[WM] "
DASHBOARD_NAMES = {
    "overview": "Mac App — Overview",
    "product": "Mac App — Product",
    "reliability": "Mac App — Reliability",
}

# Dev builds are filterable on every event via `channel`. Leaving them in
# inflates DAU/dictation counts with local relaunches; every saved view excludes
# them. Stable vs beta stay comparable on the same tiles.
EXCLUDE_DEV = {
    "type": "AND",
    "values": [
        {
            "type": "AND",
            "values": [
                {
                    "key": "channel",
                    "operator": "is_not",
                    "type": "event",
                    "value": ["dev"],
                }
            ],
        }
    ],
}


# ── .env ──────────────────────────────────────────────────────────────────


def load_dotenv(path: Path) -> None:
    if not path.is_file():
        return
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip().strip("'").strip('"')
        os.environ.setdefault(key, value)


# ── HTTP ──────────────────────────────────────────────────────────────────


def request(
    method: str,
    url: str,
    *,
    headers: dict[str, str],
    body: dict | None = None,
    dry_run: bool = False,
) -> tuple[int, object]:
    payload = None if body is None else json.dumps(body).encode()
    if dry_run and method not in {"GET", "HEAD"}:
        print(f"  DRY {method} {url}")
        if body is not None:
            preview = json.dumps(body)
            print(f"       {preview[:240]}{'…' if len(preview) > 240 else ''}")
        return 0, {}
    req = urllib.request.Request(url, data=payload, method=method, headers=headers)
    if payload is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, context=ssl.create_default_context()) as resp:
            raw = resp.read()
            data = json.loads(raw) if raw else {}
            return resp.status, data
    except urllib.error.HTTPError as exc:
        raw = exc.read()
        try:
            data = json.loads(raw) if raw else {"detail": exc.reason}
        except json.JSONDecodeError:
            data = {"detail": raw.decode("utf-8", errors="replace")}
        return exc.code, data


# ── PostHog query builders ────────────────────────────────────────────────


def events_node(event: str | None, name: str | None = None, math: str = "total") -> dict:
    # `event is None` is PostHog's "All events" series — used for the category
    # breakdown, which is stamped on every signal.
    node = {"kind": "EventsNode", "event": event, "math": math}
    if event:
        node["name"] = event
    if name:
        node["custom_name"] = name
    return node


def trends(
    series: list[dict],
    *,
    interval: str = "day",
    date_from: str = "-30d",
    breakdown: str | None = None,
    display: str = "ActionsLineGraph",
) -> dict:
    source: dict = {
        "kind": "TrendsQuery",
        "series": series,
        "interval": interval,
        "dateRange": {"date_from": date_from},
        "filterTestAccounts": True,
        "properties": EXCLUDE_DEV,
        "trendsFilter": {"display": display},
    }
    if breakdown:
        source["breakdownFilter"] = {
            "breakdown": breakdown,
            "breakdown_type": "event",
            "breakdowns": [{"property": breakdown, "type": "event"}],
        }
    return {"kind": "InsightVizNode", "source": source}


def funnel(steps: list[tuple[str, str]], *, date_from: str = "-90d") -> dict:
    return {
        "kind": "InsightVizNode",
        "source": {
            "kind": "FunnelsQuery",
            "series": [events_node(event, name) for event, name in steps],
            "dateRange": {"date_from": date_from},
            "filterTestAccounts": True,
            "properties": EXCLUDE_DEV,
            "funnelsFilter": {
                "funnelWindowInterval": 7,
                "funnelWindowIntervalUnit": "day",
                "funnelVizType": "steps",
            },
        },
    }


def retention(event: str = "App.launched") -> dict:
    entity = {"id": event, "type": "events", "name": event}
    return {
        "kind": "InsightVizNode",
        "source": {
            "kind": "RetentionQuery",
            "dateRange": {"date_from": "-90d"},
            "filterTestAccounts": True,
            "properties": EXCLUDE_DEV,
            "retentionFilter": {
                "period": "Week",
                "totalIntervals": 8,
                "retentionType": "retention_first_time",
                "retentionReference": "total",
                "targetEntity": entity,
                "returningEntity": entity,
            },
        },
    }


def lifecycle(event: str = "App.launched") -> dict:
    return {
        "kind": "InsightVizNode",
        "source": {
            "kind": "LifecycleQuery",
            "series": [events_node(event, math="total")],
            "interval": "week",
            "dateRange": {"date_from": "-90d"},
            "filterTestAccounts": True,
            "properties": EXCLUDE_DEV,
        },
    }


# ── PostHog catalog ───────────────────────────────────────────────────────


def overview_insights() -> list[dict]:
    return [
        {
            "name": "Daily / weekly active users",
            "description": "Unique people who launched the app. DAU + WAU from App.launched.",
            "query": trends(
                [
                    events_node("App.launched", "DAU", "dau"),
                    events_node("App.launched", "WAU", "weekly_active"),
                ]
            ),
        },
        {
            "name": "Dictations per day by channel",
            "description": "Finished dictations (non-empty text). Stable vs beta on one chart.",
            "query": trends(
                [events_node("Dictation.completed", "Dictations")],
                breakdown="channel",
            ),
        },
        {
            "name": "Activation funnel",
            "description": "Launch → finished onboarding → first completed dictation, 7-day window.",
            "query": funnel(
                [
                    ("App.launched", "Launched"),
                    ("Onboarding.finished", "Onboarded"),
                    ("Dictation.completed", "Dictated"),
                ]
            ),
        },
        {
            "name": "Weekly retention",
            "description": "First-time App.launched cohorts returning in later weeks.",
            "query": retention("App.launched"),
        },
        {
            "name": "Lifecycle",
            "description": "New / returning / resurrecting / dormant people per week.",
            "query": lifecycle("App.launched"),
        },
        {
            "name": "Feature use by category",
            "description": "Every event carries `category` — one breakdown for what accounts actually use.",
            "query": trends(
                [events_node(None, "Events")],
                breakdown="category",
                display="ActionsBarValue",
                date_from="-30d",
            ),
        },
        {
            "name": "Sparkle updates landed",
            "description": "First launch on a newer version — how fast rollouts actually arrive.",
            "query": trends(
                [events_node("Update.installed", "Updates")],
                breakdown="toVersion",
                display="ActionsBar",
            ),
        },
        {
            "name": "Channel mix",
            "description": "Launches split by the binary's own channel (not the appcast flag).",
            "query": trends(
                [events_node("App.launched", "Launches", "dau")],
                breakdown="channel",
                display="ActionsPie",
            ),
        },
    ]


def product_insights() -> list[dict]:
    return [
        {
            "name": "Dictation completion vs discard",
            "description": "The only way to see a completion *rate* rather than a count.",
            "query": trends(
                [
                    events_node("Dictation.completed", "Completed"),
                    events_node("Dictation.discarded", "Discarded"),
                ]
            ),
        },
        {
            "name": "Discard reasons",
            "description": "cancelled / empty / engineFailed / tooShort.",
            "query": trends(
                [events_node("Dictation.discarded", "Discarded")],
                breakdown="reason",
                display="ActionsBarValue",
            ),
        },
        {
            "name": "Session length",
            "description": "Coarse duration buckets on completed dictations.",
            "query": trends(
                [events_node("Dictation.completed", "Dictations")],
                breakdown="durationBucket",
                display="ActionsBarValue",
            ),
        },
        {
            "name": "Transcript length",
            "description": "Coarse word-count buckets — never the exact text.",
            "query": trends(
                [events_node("Dictation.completed", "Dictations")],
                breakdown="wordCountBucket",
                display="ActionsBarValue",
            ),
        },
        {
            "name": "Undelivered transcripts",
            "description": "Nowhere to paste. `copied` separates an annoyance from lost words.",
            "query": trends(
                [events_node("Dictation.undelivered", "Undelivered")],
                breakdown="copied",
            ),
        },
        {
            "name": "Hands-free vs hold",
            "description": "Double-tap latch sessions against completed dictations.",
            "query": trends(
                [
                    events_node("Dictation.completed", "Completed"),
                    events_node("Dictation.handsFree", "Hands-free"),
                ]
            ),
        },
        {
            "name": "Assistant routing",
            "description": "Where fn+control words went — agent vs day-summary vs deterministic.",
            "query": trends(
                [events_node("Assistant.routed", "Routed")],
                breakdown="route",
                display="ActionsBarValue",
            ),
        },
        {
            "name": "Assistant funnel",
            "description": "Invoked → routed → a tool actually ran.",
            "query": funnel(
                [
                    ("Assistant.invoked", "Invoked"),
                    ("Assistant.routed", "Routed"),
                    ("Assistant.toolRun", "Tool ran"),
                ]
            ),
        },
        {
            "name": "Assistant tool success",
            "description": "Per-tool success/fail. `tool` is a catalog name, never an argument.",
            "query": trends(
                [events_node("Assistant.toolRun", "Tool runs")],
                breakdown="tool",
                display="ActionsBarValue",
            ),
        },
        {
            "name": "Notes created",
            "description": "By source (agent / deterministic / manual).",
            "query": trends(
                [events_node("Note.created", "Notes")],
                breakdown="source",
            ),
        },
        {
            "name": "Reminders created",
            "description": "By source. Repeating vs one-shot is on the event, not this tile.",
            "query": trends(
                [events_node("Reminder.created", "Reminders")],
                breakdown="source",
            ),
        },
        {
            "name": "Smart cleanup adoption",
            "description": "Pulled the ~1.5 GB model vs actually substituted a cleaned transcript.",
            "query": trends(
                [
                    events_node("Cleanup.modelDownloaded", "Model downloaded"),
                    events_node("Cleanup.applied", "Cleanup applied"),
                ]
            ),
        },
        {
            "name": "Connectors",
            "description": "Linked / unlinked third-party accounts by provider slug.",
            "query": trends(
                [events_node("Connector.linked", "Connector events")],
                breakdown="provider",
                display="ActionsBarValue",
            ),
        },
        {
            "name": "Spoken answers",
            "description": "System voice vs Kokoro natural voice.",
            "query": trends(
                [events_node("Speech.answerSpoken", "Spoken")],
                breakdown="voice",
            ),
        },
    ]


def reliability_insights() -> list[dict]:
    return [
        {
            "name": "Confirmed crashes",
            "description": "App.crashed with hasReport=true. Unclean exits without an .ips stay out.",
            "query": trends(
                [events_node("App.crashed", "Crashes")],
                breakdown="hasReport",
            ),
        },
        {
            "name": "Crash signatures",
            "description": "Grouping key from the .ips parser. Empty without hasReport.",
            "query": trends(
                [events_node("App.crashed", "Crashes")],
                breakdown="crashSignature",
                display="ActionsBarValue",
                date_from="-90d",
            ),
        },
        {
            "name": "Crashes by channel",
            "description": "Beta vs stable crash counts on the same stream.",
            "query": trends(
                [events_node("App.crashed", "Crashes")],
                breakdown="channel",
            ),
        },
        {
            "name": "Crashes by version that died",
            "description": "crashedVersion — not the version reporting it (that may already be an update).",
            "query": trends(
                [events_node("App.crashed", "Crashes")],
                breakdown="crashedVersion",
                display="ActionsBarValue",
                date_from="-90d",
            ),
        },
        {
            "name": "Handled failures",
            "description": "App.failure by domain (fixed area strings, never localizedDescription).",
            "query": trends(
                [events_node("App.failure", "Failures")],
                breakdown="domain",
                display="ActionsBarValue",
            ),
        },
        {
            "name": "Native exceptions",
            "description": "PostHog PLCrashReporter `$exception` — the stack you debug from.",
            "query": trends([events_node("$exception", "Exceptions")]),
        },
        {
            "name": "Permission posture",
            "description": "Sampled at launch. Accessibility is what paste needs.",
            "query": trends(
                [events_node("Permission.state", "Permission samples")],
                breakdown="accessibility",
                display="ActionsBarValue",
            ),
        },
        {
            "name": "Microphone permission",
            "description": "Same launch sample, mic half.",
            "query": trends(
                [events_node("Permission.state", "Permission samples")],
                breakdown="microphone",
                display="ActionsBarValue",
            ),
        },
    ]


# ── PostHog client ────────────────────────────────────────────────────────


class PostHog:
    def __init__(self, host: str, token: str, project_id: str | None, dry_run: bool):
        self.host = host.rstrip("/")
        self.project_id = project_id
        self.dry_run = dry_run
        self.headers = {
            "Authorization": f"Bearer {token}",
            "Accept": "application/json",
        }

    def call(self, method: str, path: str, body: dict | None = None) -> tuple[int, object]:
        return request(method, f"{self.host}{path}", headers=self.headers, body=body, dry_run=self.dry_run)

    def require_ok(self, status: int, data: object, what: str) -> object:
        if self.dry_run and status == 0:
            return data
        if status >= 400:
            raise SystemExit(f"PostHog {what} failed ({status}): {data}")
        return data

    def resolve_project(self) -> str:
        if self.project_id:
            return self.project_id
        status, data = self.call("GET", "/api/projects/")
        payload = self.require_ok(status, data, "list projects")
        results = payload.get("results") if isinstance(payload, dict) else None
        if not results:
            raise SystemExit(
                "PostHog returned no projects. Set POSTHOG_PROJECT_ID or check the key's access."
            )
        chosen = results[0]
        print(f"Using PostHog project {chosen.get('id')} ({chosen.get('name')})")
        if len(results) > 1:
            names = ", ".join(f"{r.get('id')}={r.get('name')}" for r in results)
            print(f"  (other projects: {names} — pin with POSTHOG_PROJECT_ID)")
        self.project_id = str(chosen["id"])
        return self.project_id

    def list_all(self, path: str) -> list[dict]:
        items: list[dict] = []
        url_path = path
        while url_path:
            status, data = self.call("GET", url_path)
            payload = self.require_ok(status, data, f"list {path}")
            if not isinstance(payload, dict):
                break
            items.extend(payload.get("results") or [])
            nxt = payload.get("next")
            if not nxt:
                break
            # next is an absolute URL; keep only the path+query
            parsed = urllib.parse.urlparse(str(nxt))
            url_path = parsed.path + (("?" + parsed.query) if parsed.query else "")
        return items

    def upsert_dashboard(self, name: str, description: str) -> int:
        existing = self.list_all(f"/api/projects/{self.project_id}/dashboards/?limit=100&search={urllib.parse.quote(name)}")
        match = next((d for d in existing if d.get("name") == name and not d.get("deleted")), None)
        body = {
            "name": name,
            "description": description,
            "pinned": name == DASHBOARD_NAMES["overview"],
            "tags": ["whisper-master", "mac-app"],
            "filters": {
                "date_from": "-30d",
                "properties": EXCLUDE_DEV["values"][0]["values"],
            },
        }
        if match:
            status, data = self.call(
                "PATCH",
                f"/api/projects/{self.project_id}/dashboards/{match['id']}/",
                body,
            )
            payload = self.require_ok(status, data, f"update dashboard {name}")
            dash_id = int(payload.get("id") or match["id"])
            print(f"  updated dashboard {dash_id}: {name}")
            return dash_id
        status, data = self.call("POST", f"/api/projects/{self.project_id}/dashboards/", body)
        payload = self.require_ok(status, data, f"create dashboard {name}")
        dash_id = int(payload.get("id") or 0)
        print(f"  created dashboard {dash_id}: {name}")
        return dash_id

    def upsert_insight(self, spec: dict, dashboard_id: int, known: dict[str, dict]) -> None:
        full_name = INSIGHT_PREFIX + spec["name"]
        body = {
            "name": full_name,
            "description": spec["description"],
            "query": spec["query"],
            "dashboards": [dashboard_id],
            "tags": ["whisper-master", "mac-app"],
            "favorited": False,
        }
        match = known.get(full_name)
        if match:
            status, data = self.call(
                "PATCH",
                f"/api/projects/{self.project_id}/insights/{match['id']}/",
                body,
            )
            self.require_ok(status, data, f"update insight {full_name}")
            print(f"    updated insight {match['id']}: {full_name}")
            return
        status, data = self.call("POST", f"/api/projects/{self.project_id}/insights/", body)
        payload = self.require_ok(status, data, f"create insight {full_name}")
        print(f"    created insight {payload.get('id')}: {full_name}")

    def add_text_tile(self, dashboard_id: int, body: str) -> None:
        # Text tiles are not uniquely named; skip if this heading is already there.
        status, data = self.call("GET", f"/api/projects/{self.project_id}/dashboards/{dashboard_id}/")
        payload = self.require_ok(status, data, "get dashboard")
        tiles = payload.get("tiles") if isinstance(payload, dict) else None
        if isinstance(tiles, list):
            for tile in tiles:
                text = (tile.get("text") or {}).get("body") if isinstance(tile, dict) else None
                if text == body:
                    return
        self.call(
            "POST",
            f"/api/projects/{self.project_id}/dashboards/{dashboard_id}/create_text_tile/",
            {"body": body},
        )


def setup_posthog(dry_run: bool) -> None:
    token = os.environ.get("POSTHOG_PERSONAL_API_KEY", "").strip()
    if not token:
        raise SystemExit(
            "POSTHOG_PERSONAL_API_KEY is unset.\n"
            "  Create one at https://us.posthog.com/settings/user-api-keys\n"
            "  Scopes: dashboard:write, insight:write, project:read\n"
            "  Then:  POSTHOG_PERSONAL_API_KEY=phx_… python3 Scripts/setup-analytics-dashboards.py"
        )
    if token.startswith("phc_"):
        raise SystemExit(
            "POSTHOG_PERSONAL_API_KEY is the project key (phc_…). "
            "Dashboard writes need a *personal* key (phx_…) from Settings → Personal API keys."
        )

    client = PostHog(
        host=os.environ.get("POSTHOG_HOST", POSTHOG_HOST_DEFAULT),
        token=token,
        project_id=(os.environ.get("POSTHOG_PROJECT_ID") or os.environ.get("POSTHOG_CLI_PROJECT_ID") or "").strip()
        or None,
        dry_run=dry_run,
    )
    client.resolve_project()

    overview = overview_insights()

    catalogs = [
        (
            DASHBOARD_NAMES["overview"],
            "Activation, retention, and the numbers you check every morning. "
            "`channel=dev` is filtered out so local relaunches don't inflate the counts.",
            overview,
            "## Overview\nDAU, activation, retention, and channel mix. Filter the dashboard by `channel` to split beta vs stable.",
        ),
        (
            DASHBOARD_NAMES["product"],
            "Dictation quality, assistant routing, notes, reminders, cleanup, connectors, speech.",
            product_insights(),
            "## Product\nDid the words land, and which features are earning their keep.",
        ),
        (
            DASHBOARD_NAMES["reliability"],
            "Confirmed crashes (hasReport), signatures, handled failures, permission posture.",
            reliability_insights(),
            "## Reliability\nCrash *rate* lives here (GA gets the same `app_crashed` event). Stacks live in Error tracking.",
        ),
    ]

    print("PostHog dashboards")
    existing_insights = {
        i["name"]: i
        for i in client.list_all(f"/api/projects/{client.project_id}/insights/?limit=100&search={urllib.parse.quote(INSIGHT_PREFIX.strip())}")
        if isinstance(i, dict) and i.get("name", "").startswith(INSIGHT_PREFIX) and not i.get("deleted")
    }

    for name, description, insights, heading in catalogs:
        dash_id = client.upsert_dashboard(name, description)
        if dash_id:
            client.add_text_tile(dash_id, heading)
        for spec in insights:
            client.upsert_insight(spec, dash_id, existing_insights)

    print(
        f"Open: {client.host}/project/{client.project_id}/dashboard "
        f"(look for {DASHBOARD_NAMES['overview']})"
    )


# ── Google Analytics 4 ────────────────────────────────────────────────────

# Event-scoped custom dimensions. Parameter names MUST match GA4Limits.parameterName
# output — a rename orphans history. 50 is the free-tier cap; this list stays well under.
GA_DIMENSIONS = [
    ("channel", "Channel", "Release channel of the binary: stable, beta, or dev."),
    ("category", "Category", "Feature area: lifecycle, dictation, assistant, notes, …"),
    ("app_version", "App version", "CFBundleShortVersionString of the sending build."),
    ("os_version", "OS version", "macOS version (major.minor.patch)."),
    ("platform", "Platform", "Always macos — lets the web stream stay filterable."),
    ("duration_bucket", "Duration bucket", "Coarse dictation length (0-5s … 3m+)."),
    ("word_count_bucket", "Word count bucket", "Coarse transcript length, never the text."),
    ("engine", "Engine", "ASR engine id (slidingWindow / parakeet)."),
    ("reason", "Reason", "Discard or assistant-failure reason enum."),
    ("route", "Assistant route", "agent / daySummary / deterministic."),
    ("tool", "Tool", "Catalog tool name, never an argument."),
    ("source", "Source", "How a note or reminder was created."),
    ("provider", "Connector provider", "google_calendar, slack, …"),
    ("decision", "Approval decision", "once / always / denied / timedOut."),
    ("setting", "Setting key", "Preference that was toggled."),
    ("has_report", "Has crash report", "true = confirmed .ips; false = unclean exit."),
    ("exception_type", "Exception type", "From the .ips (EXC_BAD_ACCESS, …)."),
    ("crash_signature", "Crash signature", "Short grouping key from the parser."),
    ("crashed_version", "Crashed version", "Version that died, not the one reporting."),
    ("from_version", "From version", "Version before a Sparkle update."),
    ("to_version", "To version", "Version after a Sparkle update."),
    ("copied", "Copied", "Undelivered transcript was rescued from the banner."),
    ("succeeded", "Succeeded", "Assistant tool call outcome."),
    ("voice", "Speech voice", "system or natural."),
    ("domain", "Failure domain", "Fixed area string on App.failure."),
    ("kind", "Failure kind", "Fixed reason string on App.failure."),
    ("hotkey", "Hotkey", "Push-to-talk key the user chose."),
    ("accessibility", "Accessibility", "granted / denied, sampled at launch."),
    ("microphone", "Microphone", "granted / denied, sampled at launch."),
    ("has_audio", "Has audio", "Note was created with a recording."),
]

# Marked as key events so they show up in the standard Engagement reports and
# as conversion-style rates. app_crashed is deliberately *not* here — treating
# a crash as a conversion inflates the key-event rate the wrong way.
GA_KEY_EVENTS = [
    "onboarding_finished",
    "dictation_completed",
    "cleanup_model_downloaded",
    "note_created",
    "assistant_invoked",
]


def google_token() -> str:
    # Prefer ADC (the one `gcloud auth application-default login` writes).
    adc = Path.home() / ".config/gcloud/application_default_credentials.json"
    # `gcloud auth print-access-token` uses the user creds, which often lack
    # analytics scopes. Still try it as a fallback after ADC via the CLI helper.
    try:
        out = __import__("subprocess").check_output(
            [
                "gcloud",
                "auth",
                "application-default",
                "print-access-token",
            ],
            stderr=__import__("subprocess").DEVNULL,
            text=True,
        ).strip()
        if out:
            return out
    except Exception:
        pass
    try:
        out = __import__("subprocess").check_output(
            ["gcloud", "auth", "print-access-token"],
            stderr=__import__("subprocess").DEVNULL,
            text=True,
        ).strip()
        if out:
            return out
    except Exception:
        pass
    if adc.exists():
        raise SystemExit(
            "Found application-default credentials but could not mint a token.\n"
            "  gcloud auth application-default print-access-token"
        )
    raise SystemExit(
        "No Google credentials with Analytics access.\n"
        "  gcloud auth application-default login \\\n"
        "    --scopes=https://www.googleapis.com/auth/analytics.edit,"
        "https://www.googleapis.com/auth/analytics.readonly,"
        "https://www.googleapis.com/auth/cloud-platform"
    )


def setup_ga(dry_run: bool) -> None:
    measurement_id = os.environ.get("GA_MEASUREMENT_ID", "").strip()
    if not measurement_id:
        raise SystemExit("GA_MEASUREMENT_ID is unset (expected G-… from .env).")

    if dry_run:
        print("GA4 (dry-run) — would register these event-scoped custom dimensions:")
        for parameter, display, _ in GA_DIMENSIONS:
            print(f"  {parameter:24} {display}")
        print("GA4 (dry-run) — would mark these key events:")
        for event_name in GA_KEY_EVENTS:
            print(f"  {event_name}")
        print(
            "Then create a Library collection 'Mac App' and Explorations that "
            "break down by Channel / Category. Set Reporting identity to Blended."
        )
        return

    token = google_token()
    headers = {"Authorization": f"Bearer {token}", "Accept": "application/json"}

    property_id = (os.environ.get("GA_PROPERTY_ID") or "").strip()
    if not property_id:
        print("Resolving GA4 property from measurement id", measurement_id)
        status, data = request(
            "GET",
            "https://analyticsadmin.googleapis.com/v1beta/accountSummaries",
            headers=headers,
            dry_run=dry_run,
        )
        if not dry_run and status >= 400:
            raise SystemExit(
                f"GA Admin API list accountSummaries failed ({status}): {data}\n"
                "If this is ACCESS_TOKEN_SCOPE_INSUFFICIENT, re-auth ADC with analytics.edit "
                "(see the docstring)."
            )
        summaries = (data or {}).get("accountSummaries") or [] if isinstance(data, dict) else []
        match = None
        for account in summaries:
            for prop in account.get("propertySummaries") or []:
                prop_name = prop.get("property")  # properties/123
                if not prop_name:
                    continue
                st, streams = request(
                    "GET",
                    f"https://analyticsadmin.googleapis.com/v1beta/{prop_name}/dataStreams",
                    headers=headers,
                )
                if st >= 400 or not isinstance(streams, dict):
                    continue
                for stream in streams.get("dataStreams") or []:
                    web = stream.get("webStreamData") or {}
                    if web.get("measurementId") == measurement_id:
                        match = prop_name
                        print(
                            f"  {prop.get('displayName')} / {stream.get('displayName')} "
                            f"→ {measurement_id}"
                        )
                        break
                if match:
                    break
            if match:
                break
        if not match:
            raise SystemExit(
                f"No GA4 property has a web stream with measurement id {measurement_id}.\n"
                "Confirm the stream 'whisper-master-mac-app' exists and this Google account "
                "can see it, or set GA_PROPERTY_ID=123456789."
            )
        property_id = match.split("/", 1)[-1]
    property_name = f"properties/{property_id}"
    print(f"GA4 property {property_name}")

    # Custom dimensions
    status, data = request(
        "GET",
        f"https://analyticsadmin.googleapis.com/v1beta/{property_name}/customDimensions",
        headers=headers,
        dry_run=dry_run,
    )
    if not dry_run and status >= 400:
        raise SystemExit(f"List customDimensions failed ({status}): {data}")
    existing = {}
    if isinstance(data, dict):
        for dim in data.get("customDimensions") or []:
            existing[dim.get("parameterName")] = dim

    print("GA4 custom dimensions")
    for parameter, display, description in GA_DIMENSIONS:
        if parameter in existing:
            print(f"  exists  {parameter} ({display})")
            continue
        body = {
            "parameterName": parameter,
            "displayName": display,
            "description": description,
            "scope": "EVENT",
        }
        status, created = request(
            "POST",
            f"https://analyticsadmin.googleapis.com/v1beta/{property_name}/customDimensions",
            headers=headers,
            body=body,
            dry_run=dry_run,
        )
        if dry_run:
            print(f"  would create {parameter}")
            continue
        if status >= 400:
            print(f"  FAILED {parameter}: {created}")
            continue
        print(f"  created {parameter} ({display})")

    # Key events
    status, data = request(
        "GET",
        f"https://analyticsadmin.googleapis.com/v1beta/{property_name}/keyEvents",
        headers=headers,
        dry_run=dry_run,
    )
    existing_keys = set()
    if isinstance(data, dict):
        for ev in data.get("keyEvents") or []:
            existing_keys.add(ev.get("eventName"))

    print("GA4 key events")
    for event_name in GA_KEY_EVENTS:
        if event_name in existing_keys:
            print(f"  exists  {event_name}")
            continue
        status, created = request(
            "POST",
            f"https://analyticsadmin.googleapis.com/v1beta/{property_name}/keyEvents",
            headers=headers,
            body={"eventName": event_name},
            dry_run=dry_run,
        )
        if dry_run:
            print(f"  would create {event_name}")
            continue
        if status >= 400:
            print(f"  FAILED {event_name}: {created}")
            continue
        print(f"  created {event_name}")

    print(
        f"Open: https://analytics.google.com/analytics/web/#/p{property_id}/reports/reportinghub"
    )
    print(
        "GA has no dashboard-create API. After dimensions land (can take a few hours to "
        "populate), create a Library collection 'Mac App' and Explorations that break down "
        "by Channel / Category — the script registered those so they appear as dimensions."
    )


# ── main ──────────────────────────────────────────────────────────────────


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dry-run", action="store_true", help="Print writes, do not create.")
    parser.add_argument("--posthog-only", action="store_true")
    parser.add_argument("--ga-only", action="store_true")
    args = parser.parse_args()

    load_dotenv(ENV_PATH)

    do_ph = not args.ga_only
    do_ga = not args.posthog_only
    failures = 0

    if do_ph:
        try:
            setup_posthog(args.dry_run)
        except SystemExit as exc:
            print(f"PostHog: {exc}", file=sys.stderr)
            failures += 1

    if do_ga:
        try:
            setup_ga(args.dry_run)
        except SystemExit as exc:
            print(f"GA4: {exc}", file=sys.stderr)
            failures += 1

    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
