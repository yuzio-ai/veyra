#!/bin/bash
#
# release-notes-lib.sh — shared loader for the release note convention.
#
# Sourced by scripts/render-release-notes.sh and scripts/check-release-notes.sh.
# It reads .github/release-notes.conf and exposes, to the sourcing script:
#
#   REPO_ROOT       repository root (absolute)
#   CONFIG          the config file it read
#   TEMPLATE        .github/RELEASE_NOTES_TEMPLATE.md (absolute)
#   REPO_SLUG       owner/repo
#   PRODUCT_NAME    product name for {{PRODUCT}} placeholders
#   NOTES_DIR       notes directory (absolute)
#   ASSET_NAME      release download name
#   ASSET_STEM      ASSET_NAME without its extension, for the version-suffix rule
#   LANG_COUNT      number of language blocks
#   LANG_ID[] LANG_ANCHOR[] LANG_HEADING[] LANG_MARKER[] LANG_VOCAB[] LANG_REQUIRED[]
#                   index aligned; LANG_COUNT entries in each
#
# Nothing here is repository specific: lifting the convention into another
# repository means copying this file untouched and editing
# .github/release-notes.conf. See docs/release-notes-convention.md.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$REPO_ROOT/.github/release-notes.conf"
TEMPLATE="$REPO_ROOT/.github/RELEASE_NOTES_TEMPLATE.md"

fail() {
    printf '❌ %s\n' "$1" >&2
    exit 1
}

if [ ! -f "$CONFIG" ]; then
    fail "missing .github/release-notes.conf — see docs/release-notes-convention.md"
fi

# Pre-set so a config that forgets LANGUAGES fails with a friendly message
# instead of tripping `set -u` deep inside the loader (bash 3.2 keeps running
# after such an error, and the scripts would silently fall back to the
# single-language shape).
LANGUAGES=()

# shellcheck source=/dev/null
. "$CONFIG"

# ── repository slug ──────────────────────────────
if [ -z "${REPO_SLUG:-}" ]; then
    remote="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"
    # Both git@github.com:owner/repo.git and https://github.com/owner/repo.git
    REPO_SLUG="$(printf '%s' "$remote" | sed -e 's#^.*github\.com[:/]##' -e 's#\.git$##')"
fi
case "${REPO_SLUG:-}" in
    */*) ;;
    *) fail "cannot determine owner/repo — set REPO_SLUG in .github/release-notes.conf or add an origin remote" ;;
esac

PRODUCT_NAME="${PRODUCT_NAME:-${REPO_SLUG##*/}}"
NOTES_DIR="$REPO_ROOT/${NOTES_DIR:-docs/releases}"
ASSET_NAME="${ASSET_NAME:-$PRODUCT_NAME.zip}"
# Strip only the last extension: "My.App.zip" → "My.App".
ASSET_STEM="${ASSET_NAME%.*}"

# ── language blocks ──────────────────────────────
LANG_ID=()
LANG_ANCHOR=()
LANG_HEADING=()
LANG_MARKER=()
LANG_VOCAB=()
LANG_REQUIRED=()

release_notes_load_languages() {
    local entry id anchor heading marker vocabulary required
    local value index

    if [ "${#LANGUAGES[@]}" -eq 0 ]; then
        fail "LANGUAGES is empty in .github/release-notes.conf"
    fi

    for entry in "${LANGUAGES[@]}"; do
        IFS='|' read -r id anchor heading marker vocabulary required <<< "$entry"
        for value in "$id" "$anchor" "$heading" "$marker" "$vocabulary" "$required"; do
            [ -n "$value" ] || fail "every LANGUAGES entry needs all 6 fields: $entry"
        done

        local -a vocabulary_items=()
        local -a required_indexes=()
        IFS=',' read -r -a vocabulary_items <<< "$vocabulary"
        IFS=',' read -r -a required_indexes <<< "$required"

        for index in "${required_indexes[@]}"; do
            case "$index" in
                '' | *[!0-9]*) fail "required index '$index' is not a number: $entry" ;;
            esac
            if [ "$index" -ge "${#vocabulary_items[@]}" ]; then
                fail "required index $index is out of range, the vocabulary has ${#vocabulary_items[@]} sections: $entry"
            fi
        done

        LANG_ID+=("$id")
        LANG_ANCHOR+=("$anchor")
        LANG_HEADING+=("$heading")
        LANG_MARKER+=("$marker")
        LANG_VOCAB+=("$vocabulary")
        LANG_REQUIRED+=("$required")
    done
}

release_notes_load_languages
LANG_COUNT="${#LANG_ID[@]}"

# split_vocabulary <language index> — fills the caller's VOCABULARY array.
split_vocabulary() {
    VOCABULARY=()
    IFS=',' read -r -a VOCABULARY <<< "${LANG_VOCAB[$1]}"
}

# split_required <language index> — fills the caller's REQUIRED array.
split_required() {
    REQUIRED=()
    IFS=',' read -r -a REQUIRED <<< "${LANG_REQUIRED[$1]}"
}
