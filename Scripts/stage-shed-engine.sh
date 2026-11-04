#!/usr/bin/env bash
set -euo pipefail

# Copies Shed's source into the app bundle: Scripts/stage-shed-engine.sh <dest>
# SHED_SRC (default ~/code/shed) is taken as it is on disk, uncommitted work included.
# Only the files the engine runs from are copied. node_modules is installed on the
# user's Mac by the app (`npm ci`), and .jev-data, .laya-token, .git, video/ and
# site/ are private or irrelevant. Writes ENGINE_VERSION.json (commit, dirty, hash).
# A missing SHED_SRC is a warning, not a failure: the app builds without the engine.

DEST="${1:?usage: stage-shed-engine.sh <dest>}"
SHED_SRC="${SHED_SRC:-$HOME/code/shed}"

if [[ ! -f "$SHED_SRC/server/index.js" ]]; then
    echo "warning: SHED_SRC ($SHED_SRC) has no server/index.js; building without the agent engine" >&2
    exit 0
fi

ITEMS=(server public bin package.json package-lock.json LICENSE)

rm -rf "$DEST"
mkdir -p "$DEST"
for item in "${ITEMS[@]}"; do
    [[ -e "$SHED_SRC/$item" ]] || continue
    rsync -a --exclude node_modules --exclude .DS_Store --exclude .jev-data --exclude .laya-token \
        --exclude .git "$SHED_SRC/$item" "$DEST/"
done

COMMIT="$(git -C "$SHED_SRC" rev-parse --short HEAD 2>/dev/null || echo unknown)"
DIRTY=false
if [[ -n "$(git -C "$SHED_SRC" status --porcelain -- "${ITEMS[@]}" 2>/dev/null)" ]]; then DIRTY=true; fi
HASH="$(cd "$DEST" && find . -type f | LC_ALL=C sort | xargs shasum -a 256 | shasum -a 256 | cut -c1-16)"
printf '{"commit":"%s","dirty":%s,"hash":"%s"}\n' "$COMMIT" "$DIRTY" "$HASH" > "$DEST/ENGINE_VERSION.json"
echo ">> Staged Shed engine $COMMIT dirty=$DIRTY hash=$HASH"
