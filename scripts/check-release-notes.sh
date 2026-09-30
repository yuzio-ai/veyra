#!/bin/bash
#
# check-release-notes.sh — release note style check.
#
# .github/RELEASE_NOTES_TEMPLATE.md defines the pinned release note style; this
# script enforces it. A note authored from scratch cannot pass, so a new release
# cannot quietly drift away from the previous one.
#
# Usage:
#   bash scripts/check-release-notes.sh                     # all notes in NOTES_DIR
#   bash scripts/check-release-notes.sh <file> [<file>...]  # specific files
#   bash scripts/check-release-notes.sh --skeleton <file>   # structure only: allow
#                                                           # unfilled sections and {{placeholders}}
#
# Pinned invariants (every repository specific value comes from
# .github/release-notes.conf via scripts/release-notes-lib.sh):
#   1. a multi-language note opens with the language nav line and carries the
#      language blocks in the configured order, each with its own anchor;
#   2. ## for a language, ### for a section, and no other heading level — a
#      single-language note carries ### sections only;
#   3. sections come from the configured vocabulary of their language and keep
#      its order;
#   4. the sections flagged required in LANGUAGES are always present;
#   5. every section that survives has content;
#   6. each language block closes with compare/<previous-tag>...<tag>
#      (commits/<tag> for the first release), and <tag> matches the file name;
#   7. the asset is always <ASSET_NAME>, never <stem>-<version>.
#
# See docs/release-notes-convention.md.
# 全部通过退出码为 0，任意一项失败退出码为 1。

set -uo pipefail

. "$(dirname "$0")/release-notes-lib.sh"

# The asset is checked as a literal name; escape it for grep -E.
ASSET_PATTERN="$(printf '%s' "$ASSET_STEM" | sed 's#[][\.*^$(){}?+|/]#\\&#g')"

SKELETON=0
PROBLEMS=()
FAILED_FILES=0

problem() { PROBLEMS+=("$1"); }

# index_of <needle> <haystack...> — prints the 0-based index, or fails.
index_of() {
    local needle="$1"; shift
    local i=0
    for candidate in "$@"; do
        if [ "$candidate" = "$needle" ]; then
            printf '%s' "$i"
            return 0
        fi
        i=$((i + 1))
    done
    return 1
}

# version_key <vX.Y.Z> — zero padded, and stripped of the leading "v", so a plain
# lexical sort matches version order (v10.0.0 must sort after v9.0.0).
version_key() {
    printf '%s' "$1" | sed 's/^v//' | awk -F. '{ printf "%04d%04d%04d", $1, $2, $3 }'
}

# lowest_note_tag <dir> — the oldest release note next to this one. That note is
# the only one allowed to link to commits/<tag> instead of a comparison; every
# later release must point at its predecessor.
lowest_note_tag() {
    local dir="$1" candidate
    for candidate in "$dir"/v*.md; do
        [ -e "$candidate" ] || continue
        candidate="${candidate##*/}"
        printf '%s %s\n' "$(version_key "${candidate%.md}")" "${candidate%.md}"
    done | LC_ALL=C sort -k1,1 | head -1 | awk '{ print $2 }'
}

# strip_comments <file> — drop HTML comments, so authoring hints never read as
# content. Comments inside a ``` fence are literal content and are left alone.
strip_comments() {
    awk '
        /^[[:space:]]*```/ { fence = !fence; print; next }
        fence { print; next }
        {
            line = $0
            while (match(line, /<!--/)) {
                before = substr(line, 1, RSTART - 1)
                rest = substr(line, RSTART + 4)
                if (match(rest, /-->/)) {
                    line = before substr(rest, RSTART + 3)
                    continue
                }
                # Multi-line comment: swallow lines up to the one that closes it,
                # then loop again — the closing line may hold another comment.
                line = before
                while ((getline more) > 0) {
                    if (match(more, /-->/)) { line = line substr(more, RSTART + 3); break }
                }
                continue
            }
            print line
        }' "$1"
}

# outside_fences <file> — the lines that are not inside a ``` code fence.
# A fence may be indented (a list item wraps its block in spaces), so the marker
# is matched after any leading whitespace — see headings_of and strip_comments.
outside_fences() {
    awk '
        /^[[:space:]]*```/ { fence = !fence; next }
        !fence { print }
    ' "$1"
}

# headings_of <stripped-file> — "line<TAB>level<TAB>text", code fences excluded.
headings_of() {
    awk '
        /^[[:space:]]*```/ { fence = !fence; next }
        fence { next }
        /^#+ / {
            match($0, /^#+/)
            level = RLENGTH
            printf "%d\t%d\t%s\n", NR, level, substr($0, level + 2)
        }
    ' "$1"
}

# block_has <headings> <from> <to> <level> <text> — 0 when found inside (from, to); to=0 means EOF.
block_has() {
    awk -F'\t' -v from="$2" -v to="$3" -v level="$4" -v text="$5" '
        $2 == level && $3 == text && $1 > from && (to == 0 || $1 < to) { found = 1 }
        END { exit !found }
    ' "$1"
}

# empty_sections <stripped> <headings> — "line<TAB>text" for headings with no body.
empty_sections() {
    awk -v headings_file="$2" '
        BEGIN {
            while ((getline h < headings_file) > 0) {
                split(h, parts, "\t")
                heading_at[parts[1]] = parts[3]
            }
        }
        {
            if (NR in heading_at) {
                if (current != "" && !content) printf "%d\t%s\n", current_line, current
                current = heading_at[NR]; current_line = NR; content = 0
                next
            }
            if (current != "" && $0 ~ /[^[:space:]]/) content = 1
        }
        END {
            if (current != "" && !content) printf "%d\t%s\n", current_line, current
        }' "$1"
}

# check_sections <headings> <from> <to> <lang-index> — vocabulary, order and
# required sections inside one language block. to=0 means EOF.
check_sections() {
    local headings="$1" from="$2" to="$3" i="$4"
    local lang="${LANG_ID[$i]}"
    local -a vocabulary required
    split_vocabulary "$i"
    vocabulary=("${VOCABULARY[@]}")
    split_required "$i"
    required=("${REQUIRED[@]}")

    local line level text index last=-1
    while IFS=$'\t' read -r line level text; do
        [ "$level" = "3" ] || continue
        [ "$line" -gt "$from" ] || continue
        if [ "$to" -ne 0 ] && [ "$line" -ge "$to" ]; then
            continue
        fi
        if ! index="$(index_of "$text" "${vocabulary[@]}")"; then
            problem "[$lang] line $line: \"$text\" is not a fixed section name"
            continue
        fi
        if [ "$index" -le "$last" ]; then
            problem "[$lang] line $line: \"$text\" is out of order or repeated"
        fi
        last="$index"
    done < "$headings"

    local required_index
    for required_index in "${required[@]}"; do
        if ! block_has "$headings" "$from" "$to" 3 "${vocabulary[$required_index]}"; then
            problem "[$lang] missing required section \"${vocabulary[$required_index]}\""
        fi
    done
}

# validate_changelog <url> <lang> <tag> <is-first-release>
validate_changelog() {
    local url="$1" lang="$2" tag="$3" first="$4"
    if [ -z "$url" ]; then
        problem "[$lang] missing the closing changelog line"
        return 0
    fi
    [ "$SKELETON" -eq 1 ] && return 0
    local expected="https://github.com/$REPO_SLUG/compare/<previous-tag>...$tag"
    local pattern="^https://github\.com/$REPO_SLUG/compare/v[0-9][0-9.]*\.\.\.$tag\$"
    if [ "$first" -eq 1 ]; then
        expected="https://github.com/$REPO_SLUG/compare/<previous-tag>...$tag (or commits/$tag for the first release)"
        pattern="^https://github\.com/$REPO_SLUG/(compare/v[0-9][0-9.]*\.\.\.$tag|commits/$tag)\$"
    fi
    if ! printf '%s' "$url" | grep -qE "$pattern"; then
        problem "[$lang] changelog link must be $expected — got: $url"
    fi
}

# marker_line_and_url <marker> — the first line starting with the marker sets
# MARKER_LINE (its line number) and MARKER_URL (the remainder of the line).
marker_line_and_url() {
    MARKER_LINE=""
    MARKER_URL=""
    local marker="$1" line number=0
    while IFS= read -r line || [ -n "$line" ]; do
        number=$((number + 1))
        case "$line" in
            "$marker"*)
                MARKER_LINE="$number"
                MARKER_URL="${line#"$marker"}"
                return 0
                ;;
        esac
    done < "$STRIPPED"
}

check_file() { # check_file <path>
    local file="$1"
    local base
    base="$(basename "$file")"
    PROBLEMS=()

    if [ "$SKELETON" -eq 0 ] && ! printf '%s' "$base" | grep -qE '^v[0-9]+\.[0-9]+(\.[0-9]+)?\.md$'; then
        problem "file name must be v<major>.<minor>[.<patch>].md — got $base"
    fi

    strip_comments "$file" | tr -d '\r' > "$STRIPPED"
    headings_of "$STRIPPED" > "$HEADINGS"

    local i lang heading anchor
    local -a H=() A=()

    # ── language nav line (multi-language notes only) ──
    if [ "$LANG_COUNT" -ge 2 ]; then
        local nav="" nav_line
        i=0
        while [ "$i" -lt "$LANG_COUNT" ]; do
            [ "$i" -eq 0 ] || nav="$nav | "
            nav="$nav<a href=\"#${LANG_ANCHOR[$i]}\">${LANG_HEADING[$i]}</a>"
            i=$((i + 1))
        done
        nav_line="$(grep -nF -m1 -- "$nav" "$STRIPPED" | cut -d: -f1)"
        if [ -z "$nav_line" ]; then
            problem "missing the language nav line: $nav"
        elif [ "$nav_line" -gt 1 ] && [ "$(head -n $((nav_line - 1)) "$STRIPPED" | grep -c '[^[:space:]]')" -ne 0 ]; then
            problem "the language nav line must be the first non-blank line"
        fi
    fi

    # ── per-language anchors and heading positions ──
    local prev_line=0 prev_heading="" h_count
    i=0
    while [ "$i" -lt "$LANG_COUNT" ]; do
        lang="${LANG_ID[$i]}"
        heading="${LANG_HEADING[$i]}"
        anchor="${LANG_ANCHOR[$i]}"
        if [ "$LANG_COUNT" -ge 2 ]; then
            A[$i]="$(grep -nF -m1 -- "<a id=\"$anchor\"></a>" "$STRIPPED" | cut -d: -f1)"
            [ -n "${A[$i]}" ] || problem "missing the anchor <a id=\"$anchor\"></a>"
            H[$i]="$(awk -F'\t' -v t="$heading" '$2 == 2 && $3 == t { print $1; exit }' "$HEADINGS")"
            h_count="$(awk -F'\t' -v t="$heading" '$2 == 2 && $3 == t' "$HEADINGS" | wc -l | tr -d ' ')"
            [ "$h_count" = "1" ] || problem "\"## $heading\" must appear exactly once — found $h_count"
            if [ -n "${H[$i]}" ]; then
                if [ "$prev_line" -ne 0 ] && [ "${H[$i]}" -le "$prev_line" ]; then
                    problem "$heading must come after $prev_heading — $prev_heading is at line $prev_line, $heading at line ${H[$i]}"
                fi
                if [ -n "${A[$i]}" ] && [ "${A[$i]}" -gt "${H[$i]}" ]; then
                    problem "[$lang] the $anchor anchor must precede the \"## $heading\" heading"
                fi
                prev_line="${H[$i]}"
                prev_heading="$heading"
            fi
        else
            H[$i]=0
            A[$i]=""
        fi
        i=$((i + 1))
    done

    # ── heading levels and language labels ──
    local line level text
    while IFS=$'\t' read -r line level text; do
        case "$level" in
            2)
                if [ "$LANG_COUNT" -lt 2 ]; then
                    problem "line $line: h2 heading — a single-language note carries only ### sections — \"$text\""
                elif ! printf '%s\n' "${LANG_HEADING[@]}" | grep -qFx -- "$text"; then
                    problem "line $line: language heading must be one of: ${LANG_HEADING[*]} — got \"$text\""
                fi
                ;;
            3) ;;
            *)
                if [ "$LANG_COUNT" -ge 2 ]; then
                    problem "line $line: h$level heading — only ## for a language and ### for a section are allowed — \"$text\""
                else
                    problem "line $line: h$level heading — only ### for a section is allowed in a single-language note — \"$text\""
                fi
                ;;
        esac
    done < "$HEADINGS"

    # ── section vocabulary and required sections ──
    local from to
    i=0
    while [ "$i" -lt "$LANG_COUNT" ]; do
        if [ "$LANG_COUNT" -ge 2 ]; then
            from="${H[$i]}"
            if [ -z "$from" ]; then
                i=$((i + 1))
                continue
            fi
            if [ "$i" -lt $((LANG_COUNT - 1)) ]; then
                to="${H[$((i + 1))]}"
                # The next block is missing or out of order — already reported.
                if [ -z "$to" ] || [ "$from" -ge "$to" ]; then
                    i=$((i + 1))
                    continue
                fi
            else
                to=0
            fi
        else
            from=0
            to=0
        fi
        check_sections "$HEADINGS" "$from" "$to" "$i"
        i=$((i + 1))
    done

    # ── closing changelog lines ──
    local tag="${base%.md}"
    local first=0
    if [ "$tag" = "$(lowest_note_tag "$(dirname "$file")")" ]; then
        first=1
    fi
    local marker_url marker_line
    i=0
    while [ "$i" -lt "$LANG_COUNT" ]; do
        lang="${LANG_ID[$i]}"
        marker_line_and_url "${LANG_MARKER[$i]}"
        marker_line="$MARKER_LINE"
        marker_url="$MARKER_URL"
        validate_changelog "$marker_url" "$lang" "$tag" "$first"
        if [ "$LANG_COUNT" -ge 2 ] && [ -n "$marker_line" ]; then
            if [ -n "${A[$i]}" ] && [ "$marker_line" -le "${A[$i]}" ]; then
                problem "[$lang] the changelog line must close the ${LANG_HEADING[$i]} block, after the ${LANG_HEADING[$i]} anchor"
            fi
            if [ "$i" -lt $((LANG_COUNT - 1)) ] && [ -n "${A[$((i + 1))]}" ] && [ "$marker_line" -ge "${A[$((i + 1))]}" ]; then
                problem "[$lang] the changelog line must close the ${LANG_HEADING[$i]} block, before the ${LANG_HEADING[$((i + 1))]} anchor"
            fi
        fi
        i=$((i + 1))
    done

    # ── asset name ──
    local bad_asset
    if bad_asset="$(grep -m1 -oE "$ASSET_PATTERN-[0-9][0-9A-Za-z._-]*" "$STRIPPED")"; then
        problem "the asset is called $ASSET_NAME — found $bad_asset"
    fi

    # ── actually filled in ───────────────────────
    if [ "$SKELETON" -eq 0 ]; then
        local leftover
        leftover="$(grep -m1 -oE '\{\{[^}]*\}\}' "$STRIPPED")"
        [ -z "$leftover" ] || problem "unreplaced template placeholder left in the note: $leftover"
        local hints
        hints="$(outside_fences "$file" | grep -cF '<!--')"
        if [ "$hints" -gt 0 ]; then
            problem "authoring comment left in the note — remove all $hints <!-- ... --> hint(s) (comments inside a code fence are content and are fine)"
        fi
        while IFS=$'\t' read -r line text; do
            [ -n "$line" ] || continue
            problem "line $line: section \"$text\" has no content — fill it in or delete it"
        done < <(empty_sections "$STRIPPED" "$HEADINGS")
    fi

    # ── report ───────────────────────────────────
    if [ "${#PROBLEMS[@]}" -eq 0 ]; then
        printf '  ✅ %s\n' "${file#"$REPO_ROOT"/}"
    else
        FAILED_FILES=$((FAILED_FILES + 1))
        printf '  ❌ %s\n' "${file#"$REPO_ROOT"/}"
        local item
        for item in "${PROBLEMS[@]}"; do
            printf '     - %s\n' "$item"
        done
    fi
}


# ── arguments ────────────────────────────────────
FILES=()
if [ "$#" -gt 0 ]; then
    for argument in "$@"; do
        case "$argument" in
            --skeleton) SKELETON=1 ;;
            -h|--help)
                sed -n '3,30p' "$0"
                exit 0
                ;;
            *) FILES+=("$argument") ;;
        esac
    done
fi

if [ "${#FILES[@]}" -eq 0 ]; then
    if [ -d "$NOTES_DIR" ]; then
        while IFS= read -r found; do
            FILES+=("$found")
        done < <(find "$NOTES_DIR" -maxdepth 1 -name '*.md' | LC_ALL=C sort)
    fi
    if [ "${#FILES[@]}" -eq 0 ]; then
        echo "❌ no release notes found under ${NOTES_DIR#"$REPO_ROOT"/}" >&2
        exit 1
    fi
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/release-notes.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
STRIPPED="$WORK_DIR/stripped.md"
HEADINGS="$WORK_DIR/headings.tsv"

echo "──────────────────────────────────────────────"
echo " $PRODUCT_NAME 发布说明样式"
if [ "$SKELETON" -eq 1 ]; then
    echo " 模式: 只校验骨架"
fi
echo "──────────────────────────────────────────────"

for file in "${FILES[@]}"; do
    if [ ! -f "$file" ]; then
        echo "❌ not a file: $file" >&2
        exit 1
    fi
    check_file "$file"
done

echo "──────────────────────────────────────────────"
if [ "$FAILED_FILES" -eq 0 ]; then
    echo " 🎉 ${#FILES[@]} 份发布说明符合固定样式"
    exit 0
else
    echo " ⚠️  ${#FILES[@]} 份中有 $FAILED_FILES 份偏离固定样式"
    echo "     模板: ${TEMPLATE#"$REPO_ROOT"/}"
    exit 1
fi
