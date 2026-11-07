#!/bin/zsh
# Verifies an exported release Veyra.app before publishing: version, build,
# bundle identity, category, menu-bar mode, universal architectures, Developer
# ID signing with Hardened Runtime, Gatekeeper notarization, and the stapled
# ticket. Optionally packages the app into a ZIP and prints its SHA-256.
# Run from anywhere; paths resolve against the repository root.
# Usage:
#   ./scripts/verify_release_app.sh /path/to/Veyra.app [options]
# Options:
#   --version X.Y.Z     Expect this CFBundleShortVersionString (default: the
#                       MARKETING_VERSION in project.pbxproj, when unique).
#   --build N           Expect this CFBundleVersion (default: the
#                       CURRENT_PROJECT_VERSION in project.pbxproj, when unique).
#   --bundle-id ID      Expect this bundle identifier (default ai.yuzio.veyra).
#   --zip PATH          After verification passes, package the app with ditto
#                       into PATH (relative to the repository root) and print
#                       its SHA-256. Refuses to overwrite an existing ZIP.
# Exit status: 0 when every check passes, 1 otherwise.
set -euo pipefail
cd "${0:A:h:h}"

usage() {
    print -r -- "Usage: $0 <path-to-Veyra.app> [--version X.Y.Z] [--build N] [--bundle-id ID] [--zip PATH]"
}

app_path=""
expected_version=""
expected_build=""
expected_bundle_id="ai.yuzio.veyra"
zip_path=""
while (( $# )); do
    case "$1" in
        --version|--build|--bundle-id|--zip)
            if (( $# < 2 )); then
                print -r -- "error: $1 requires a value" >&2
                usage >&2
                exit 2
            fi
            case "$1" in
                --version) expected_version="$2" ;;
                --build) expected_build="$2" ;;
                --bundle-id) expected_bundle_id="$2" ;;
                --zip) zip_path="$2" ;;
            esac
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            print -r -- "error: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
        *)
            if [[ -n "$app_path" ]]; then
                print -r -- "error: unexpected extra argument: $1" >&2
                usage >&2
                exit 2
            fi
            app_path="$1"
            shift
            ;;
    esac
done
if [[ -z "$app_path" ]]; then
    usage >&2
    exit 2
fi

print -r -- "Release app: $app_path"
failures=0

fail() {
    print -r -- "  FAIL: $1" >&2
    failures=$((failures + 1))
}
pass() {
    print -r -- "  ok:   $1"
}
plist() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$app_path/Contents/Info.plist" 2>/dev/null
}

# --- [1/9] Bundle structure -------------------------------------------------
if [[ ! -d "$app_path" ]]; then
    print -r -- "  FAIL: app bundle not found: $app_path" >&2
    exit 1
fi
# Keep exports and Xcode archives intact while retiring their search entries.
trap '/usr/bin/python3 -I -B "$PWD/scripts/cleanup_app_copies.py" unregister --archives "$app_path" || exit 1' EXIT
if [[ -x "$app_path/Contents/MacOS/Veyra" && -f "$app_path/Contents/Info.plist" ]]; then
    pass "bundle structure (executable + Info.plist)"
else
    fail "bundle structure: missing executable or Info.plist"
fi

# --- [2/9] Version, build, identity, category, menu-bar mode ----------------
pbxproj="Veyra.xcodeproj/project.pbxproj"
if [[ -z "$expected_version" ]]; then
    pbx_versions=()
    pbx_raw="$(grep -oE 'MARKETING_VERSION = [0-9.]+' "$pbxproj" | sed 's/.*= //' | sort -u)" || true
    [[ -n "$pbx_raw" ]] && pbx_versions=("${(@f)pbx_raw}")
    if (( ${#pbx_versions} == 1 )); then
        expected_version="${pbx_versions[1]}"
    fi
fi
if [[ -z "$expected_build" ]]; then
    pbx_builds=()
    pbx_raw="$(grep -oE 'CURRENT_PROJECT_VERSION = [0-9]+' "$pbxproj" | sed 's/.*= //' | sort -u)" || true
    [[ -n "$pbx_raw" ]] && pbx_builds=("${(@f)pbx_raw}")
    if (( ${#pbx_builds} == 1 )); then
        expected_build="${pbx_builds[1]}"
    fi
fi

# Capture every probe with `|| true`: `set -e` must not abort the run before the
# matching check prints its FAIL (spctl/stapler/lipo/codesign and PlistBuddy all
# exit non-zero for exactly the conditions this script exists to report).
app_version="$(plist CFBundleShortVersionString)" || true
app_build="$(plist CFBundleVersion)" || true
app_bundle_id="$(plist CFBundleIdentifier)" || true
app_category="$(plist LSApplicationCategoryType)" || true
app_ui_element="$(plist LSUIElement)" || true
min_system="$(plist LSMinimumSystemVersion)" || true
team_id="$(codesign -dv --verbose=4 "$app_path" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -1)" || true

print -r -- "  info: version=${app_version:-<missing>} build=${app_build:-<missing>} bundle-id=${app_bundle_id:-<missing>} team=${team_id:-<missing>}"
# An underivable expectation is a failure, never a silent pass: the version and
# build checks must not degrade into no-ops when project.pbxproj is ambiguous.
if [[ -z "$expected_version" ]]; then
    fail "cannot derive expected version from $pbxproj; pass --version"
elif [[ "$app_version" == "$expected_version" ]]; then
    pass "CFBundleShortVersionString = $app_version (expected $expected_version)"
else
    fail "CFBundleShortVersionString is '$app_version', expected '$expected_version'"
fi
if [[ -z "$expected_build" ]]; then
    fail "cannot derive expected build from $pbxproj; pass --build"
elif [[ "$app_build" == "$expected_build" ]]; then
    pass "CFBundleVersion = $app_build (expected $expected_build)"
else
    fail "CFBundleVersion is '$app_build', expected '$expected_build'"
fi
if [[ "$app_bundle_id" == "$expected_bundle_id" ]]; then
    pass "CFBundleIdentifier = $app_bundle_id"
else
    fail "CFBundleIdentifier is '$app_bundle_id', expected '$expected_bundle_id'"
fi
if [[ "$app_category" == "public.app-category.developer-tools" ]]; then
    pass "LSApplicationCategoryType = $app_category"
else
    fail "LSApplicationCategoryType is '$app_category', expected public.app-category.developer-tools"
fi
if [[ "$app_ui_element" == "true" ]]; then
    pass "LSUIElement = true (menu-bar only, no Dock icon)"
else
    fail "LSUIElement is '$app_ui_element', expected true"
fi

# --- [3/9] Minimum system version -------------------------------------------
if [[ "$(printf '%s\n14.0\n' "${min_system:-0.0}" | sort -V | head -1)" == "14.0" ]]; then
    pass "LSMinimumSystemVersion = ${min_system:-<missing>} (>= 14.0)"
else
    fail "LSMinimumSystemVersion is '$min_system', expected >= 14.0"
fi

# --- [4/9] Universal binary ---------------------------------------------------
archs="$(lipo -archs "$app_path/Contents/MacOS/Veyra" 2>/dev/null)" || true
archs="${archs:-<unreadable>}"
arch_words=(${=archs})
if (( ${arch_words[(I)arm64]} && ${arch_words[(I)x86_64]} )); then
    pass "universal binary: $archs"
else
    fail "binary architectures are '$archs', expected both arm64 and x86_64"
fi

# --- [5/9] Code signature integrity -------------------------------------------
if codesign --verify --deep --strict --verbose=0 "$app_path" >/dev/null 2>&1; then
    pass "codesign --verify --deep --strict"
else
    fail "codesign --verify --deep --strict did not pass"
fi

# --- [6/9] Distribution signing identity and Hardened Runtime -----------------
signature="$(codesign -dv --verbose=4 "$app_path" 2>&1)" || true
if grep -q '^Authority=Developer ID Application:' <<< "$signature"; then
    pass "signed with Developer ID Application"
else
    authority="$(sed -n 's/^Authority=//p' <<< "$signature" | head -1)"
    fail "signing authority is '${authority:-<none>}', expected Developer ID Application"
fi
if grep -q 'flags=0x[0-9a-f]*(runtime)' <<< "$signature"; then
    pass "Hardened Runtime enabled"
else
    fail "Hardened Runtime flag not present in code directory"
fi
if [[ -n "$team_id" ]]; then
    pass "TeamIdentifier = $team_id"
else
    fail "TeamIdentifier missing from signature"
fi

# --- [7/9] Gatekeeper notarization assessment ---------------------------------
spctl_output="$(spctl --assess --type execute --verbose=4 "$app_path" 2>&1)" || true
if grep -q 'accepted' <<< "$spctl_output" && grep -q 'Notarized Developer ID' <<< "$spctl_output"; then
    pass "Gatekeeper assessment accepted (Notarized Developer ID)"
else
    fail "Gatekeeper assessment: $spctl_output"
fi

# --- [8/9] Stapled notarization ticket ----------------------------------------
stapler_output="$(xcrun stapler validate "$app_path" 2>&1)" || true
if grep -qi 'The validate action worked' <<< "$stapler_output"; then
    pass "stapler validate (offline notarization ticket present)"
else
    fail "stapler validate: $stapler_output"
fi

# --- [9/9] Optional ZIP packaging ----------------------------------------------
if [[ -n "$zip_path" ]]; then
    if (( failures )); then
        print -r -- "  skip: not packaging because verification failed" >&2
    elif [[ -e "$zip_path" ]]; then
        fail "ZIP output already exists, refusing to overwrite: $zip_path"
    else
        # Package to a sibling temporary path so a failed ditto never leaves a
        # half-written ZIP that the next run would refuse to overwrite.
        partial_zip="${zip_path}.partial.$$"
        if ! mkdir -p "${zip_path:h}"; then
            fail "cannot create the output directory for $zip_path"
        elif ditto -c -k --sequesterRsrc --keepParent "$app_path" "$partial_zip" \
            && mv -f "$partial_zip" "$zip_path"; then
            checksum="$(shasum -a 256 "$zip_path" | awk '{print $1}')" || true
            pass "packaged $zip_path"
            print -r -- ""
            print -r -- "SHA-256: ${checksum:-<unavailable>}"
            print -r -- "  copy this value into the release notes for ${app_version:-<version>}"
        else
            rm -f "$partial_zip"
            fail "ditto failed to package $zip_path"
        fi
    fi
fi

print -r -- ""
if (( failures )); then
    print -r -- "verify_release_app.sh: $failures check(s) FAILED for $app_path" >&2
    exit 1
fi
print -r -- "verify_release_app.sh: all checks passed for $app_path"
print -r -- "reminder: launch the app once and check the menu bar (light/dark, both languages) before publishing."
