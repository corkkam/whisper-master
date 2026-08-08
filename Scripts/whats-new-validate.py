#!/usr/bin/env python3
"""Validates whats-new.json before it is allowed anywhere near R2.

Why this is loud rather than lenient: the app treats *any* problem with the
manifest — offline, malformed JSON, no matching release — as "show nothing".
That is the right behaviour in the field (a release note must never be the
reason something failed), but it also means a broken manifest is completely
invisible: no crash, no error, no report. Users just quietly stop seeing
release notes. So the only place a mistake can be caught is here, before
upload, which is why every rule below fails the build rather than warning.

Standard library only — the CI runner has no PyYAML and no yq.

Usage:
    python3 Scripts/whats-new-validate.py [path]        # default: whats-new.json
    python3 Scripts/whats-new-validate.py --print [path]  # emit the manifest the
                                                          # app will actually see
Exit status: 0 valid, 1 invalid (with every problem listed, not just the first).
"""

import argparse
import json
import re
import sys

# The public host the shipped app reads. Deliberately NOT derived from
# $R2_PUBLIC_BASE_URL: that secret is stale (it still names a retired r2.dev
# host) while the app hardcodes dl.corkkam.com in Auth/BetaAccess.swift. Media
# URLs built from the secret would 404 for every user. See CLAUDE.md →
# "The public R2 host is baked into shipped bundles in three places".
PUBLIC_BASE_URL = "https://dl.corkkam.com"

# Matches SemanticVersion.swift: major[.minor[.patch]][-prerelease][+build].
SEMVER = re.compile(r"^\d+(\.\d+){0,2}(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$")

# The schema the shipped app renders (WhatsNewManifest.supportedSchemaVersion).
SUPPORTED_SCHEMA_VERSION = 1

REQUIRED_RELEASE_KEYS = ("version", "headline")
OPTIONAL_URL_KEYS = ("videoURL", "posterURL")


def version_key(version):
    """Sort key matching SemanticVersion's ordering closely enough to check
    'newest first'. A pre-release sorts below the release it leads to."""
    core, _, pre = version.partition("+")[0].partition("-")
    parts = [int(p) for p in core.split(".")] + [0, 0]
    # No pre-release ranks ABOVE any pre-release of the same core version.
    return (parts[0], parts[1], parts[2], 1 if not pre else 0, pre)


def validate(path):
    problems = []

    try:
        with open(path, "r", encoding="utf-8") as handle:
            raw = handle.read()
    except OSError as error:
        return [f"cannot read {path}: {error}"], None

    try:
        manifest = json.loads(raw)
    except json.JSONDecodeError as error:
        return [f"{path} is not valid JSON: {error}"], None

    if not isinstance(manifest, dict):
        return [f"{path} must be a JSON object at the top level"], None

    schema = manifest.get("schemaVersion")
    if schema is None:
        problems.append("schemaVersion is missing")
    elif not isinstance(schema, int):
        problems.append("schemaVersion must be an integer")
    elif schema > SUPPORTED_SCHEMA_VERSION:
        problems.append(
            f"schemaVersion {schema} is newer than the shipped app understands "
            f"({SUPPORTED_SCHEMA_VERSION}) — every release would be skipped"
        )

    releases = manifest.get("releases")
    if releases is None:
        problems.append("releases is missing")
        return problems, manifest
    if not isinstance(releases, list):
        problems.append("releases must be an array")
        return problems, manifest
    if not releases:
        problems.append("releases is empty — nothing would ever be shown")
        return problems, manifest

    seen = {}
    ordered = []

    for index, release in enumerate(releases):
        where = f"releases[{index}]"

        if not isinstance(release, dict):
            problems.append(f"{where} must be an object")
            continue

        for key in REQUIRED_RELEASE_KEYS:
            value = release.get(key)
            if not isinstance(value, str) or not value.strip():
                problems.append(f"{where}.{key} is required and must be a non-empty string")

        version = release.get("version")
        if isinstance(version, str) and version.strip():
            where = f"releases[{index}] ({version})"
            if not SEMVER.match(version):
                problems.append(f"{where}: version is not well-formed semver")
            else:
                ordered.append((index, version))
            if version in seen:
                problems.append(
                    f"{where}: duplicate version, already defined at releases[{seen[version]}]"
                )
            else:
                seen[version] = index

        for key in OPTIONAL_URL_KEYS:
            url = release.get(key)
            if url is None:
                continue
            if not isinstance(url, str):
                problems.append(f"{where}.{key} must be a string")
            elif not url.startswith("https://"):
                # The app rejects any non-http(s) scheme at decode time, and a
                # plain-http media URL on an https page is a mixed-content trap.
                problems.append(f"{where}.{key} must be an https:// URL (got {url!r})")

        release_schema = release.get("schemaVersion")
        if release_schema is not None and not isinstance(release_schema, int):
            problems.append(f"{where}.schemaVersion must be an integer when present")

        highlights = release.get("highlights")
        if highlights is None:
            continue
        if not isinstance(highlights, list):
            problems.append(f"{where}.highlights must be an array")
            continue
        for position, highlight in enumerate(highlights):
            spot = f"{where}.highlights[{position}]"
            if not isinstance(highlight, dict):
                problems.append(f"{spot} must be an object")
                continue
            for key in ("title", "body", "systemImage"):
                value = highlight.get(key)
                if not isinstance(value, str) or not value.strip():
                    problems.append(f"{spot}.{key} is required and must be a non-empty string")

    # Newest first. The app sorts defensively on its own, so this is about the
    # file staying readable to a human deciding where to add the next entry.
    if len(ordered) > 1:
        sorted_desc = sorted(ordered, key=lambda pair: version_key(pair[1]), reverse=True)
        if [pair[1] for pair in ordered] != [pair[1] for pair in sorted_desc]:
            expected = ", ".join(pair[1] for pair in sorted_desc)
            problems.append(f"releases must be sorted newest first — expected order: {expected}")

    return problems, manifest


def main():
    parser = argparse.ArgumentParser(description="Validate whats-new.json")
    parser.add_argument("path", nargs="?", default="whats-new.json")
    parser.add_argument(
        "--print",
        dest="emit",
        action="store_true",
        help="print the manifest to stdout (authoring keys stripped) when valid",
    )
    args = parser.parse_args()

    problems, manifest = validate(args.path)

    if problems:
        print(f"whats-new: {args.path} is INVALID", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1

    if args.emit:
        # `_README` is authoring guidance. The app ignores unknown keys, so this
        # is about not shipping a few hundred bytes to every client, not safety.
        published = {key: value for key, value in manifest.items() if not key.startswith("_")}
        print(json.dumps(published, indent=2, ensure_ascii=False))
    else:
        count = len(manifest.get("releases", []))
        newest = manifest["releases"][0]["version"] if count else "none"
        print(f"whats-new: {args.path} is valid — {count} release(s), newest {newest}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
