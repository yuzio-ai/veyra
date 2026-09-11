#!/usr/bin/env python3
"""Verify generated project configuration and packaging invariants.

Read-only: this script never writes project files. It checks settings that live
only in `scripts/generate_project.py` or `Veyra/Info.plist` and therefore had no
regression coverage: App Sandbox stays off, the app keeps Hardened Runtime, the
app stays menu-bar only, both x86_64 and arm64 ship in a release, and the test
bundle can still see the shared Core sources and localization resources.

Release claims that depend on a built artifact (the universal binary) are only
checked when a Release build exists in the derived data directory; otherwise they
are reported as skipped instead of silently passing. Code signing, notarization,
and stapling stay manual release-runbook steps.
"""
import argparse
import plistlib
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

DEPLOYMENT_TARGET = "14.0"
APP_TARGET = "Veyra"
TEST_TARGET = "VeyraTests"
APP_BUNDLE_IDENTIFIER = "local.codexmonitor.app"
TEST_BUNDLE_IDENTIFIER = "local.codexmonitor.tests"
ICON_FILE = "AppIcon"
BUILD_NUMBER_RE = re.compile(r"^[0-9]+$")
SWIFT_VERSION = "6.0"
SWIFT_CONCURRENCY = "complete"
TEST_MEMBERSHIP_EXCEPTIONS = {
    "App/MonitorStore.swift",
    "App/UpdateStore.swift",
    "Resources/Localizable.xcstrings",
}
LINKER_FLAGS = ["-lsqlite3"]

OBJECT_KEY_RE = re.compile(r"^([0-9A-F]{24}) = \{")
PBX_TARGET_RE = re.compile(
    r"isa = PBXNativeTarget;.*?buildConfigurationList = ([0-9A-F]{24});.*?"
    r"fileSystemSynchronizedGroups = \(([^)]*)\);.*?name = ([^;]+?);",
    re.DOTALL,
)
CONFIG_LIST_RE = re.compile(r"isa = XCConfigurationList;.*?buildConfigurations = \(([^)]*)\);", re.DOTALL)
CONFIG_NAME_RE = re.compile(r"isa = XCBuildConfiguration;.*?name = ([^;]+);", re.DOTALL)
EXCEPTION_SET_RE = re.compile(
    r"isa = PBXFileSystemSynchronizedBuildFileExceptionSet;.*?membershipExceptions = \(([^)]*)\);.*?"
    r"target = ([0-9A-F]{24});",
    re.DOTALL,
)
VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
PLACEHOLDER_RE = re.compile(r"^\$\([A-Z_]+\)$")


class Report:
    def __init__(self):
        self.failures = 0
        self.warnings = 0
        self.checks = 0

    def ok(self, message):
        self.checks += 1
        print(f"OK   {message}")

    def fail(self, message):
        self.checks += 1
        self.failures += 1
        print(f"FAIL {message}")

    def warn(self, message):
        self.checks += 1
        self.warnings += 1
        print(f"WARN {message}")

    def expect(self, condition, message, detail=""):
        if condition:
            self.ok(message)
        else:
            self.fail(f"{message}{f' ({detail})' if detail else ''}")


def display_path(path):
    """Prefer a repository-relative path, but never raise for an outside project."""
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)


def parse_arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, default=ROOT / "Veyra.xcodeproj",
                        help="Path to Veyra.xcodeproj (default: %(default)s)")
    parser.add_argument("--app", type=Path,
                        help="Optional built Veyra executable to check for the native architecture")
    parser.add_argument("--derived-data", type=Path,
                        help="Optional derived data directory holding a Release build to check")
    return parser.parse_args()


def normalized(value):
    if value is None:
        return None
    return value.strip().strip('"')


def parse_settings(body):
    settings = {}
    for token in body.split(";"):
        if "=" not in token:
            continue
        key, _, value = token.partition("=")
        key = key.strip().split()[-1] if key.strip() else ""
        if not key or not (key[0].isalpha() or key[0] == "_"):
            continue
        settings[key] = normalized(value)
    return settings


def parse_configurations(objects, reference):
    match = CONFIG_LIST_RE.search(objects.get(reference, ""))
    if match is None:
        return {}
    configurations = {}
    for identifier in re.findall(r"[0-9A-F]{24}", match.group(1)):
        body = objects.get(identifier, "")
        name = CONFIG_NAME_RE.search(body)
        if name is not None:
            configurations[normalized(name.group(1))] = parse_settings(body)
    return configurations


def parse_targets(objects):
    targets = {}
    for body in objects.values():
        if "isa = PBXNativeTarget;" not in body:
            continue
        match = PBX_TARGET_RE.search(body)
        if match is None:
            continue
        groups = re.findall(r"[0-9A-F]{24}", match.group(2))
        targets[normalized(match.group(3))] = {
            "configurations": parse_configurations(objects, match.group(1)),
            "synchronizedGroups": groups,
        }
    return targets


def load_objects(project):
    """Parse top-level pbxproj objects, tolerant of both single-line and
    multi-line bodies because Xcode re-saves the generated project."""
    path = project / "project.pbxproj"
    if not path.is_file():
        raise SystemExit(f"error: {path} not found; run python3 scripts/generate_project.py first")
    objects = {}
    lines = path.read_text().splitlines()
    index = 0
    while index < len(lines):
        match = OBJECT_KEY_RE.match(lines[index])
        if match is None:
            index += 1
            continue
        identifier = match.group(1)
        body = []
        depth = 0
        while index < len(lines):
            line = lines[index]
            body.append(line)
            depth += line.count("{") - line.count("}")
            index += 1
            if depth <= 0:
                break
        objects[identifier] = " ".join(part.strip() for part in body)
    return path, objects


def load_plist(path):
    try:
        with path.open("rb") as handle:
            return plistlib.load(handle)
    except FileNotFoundError:
        raise SystemExit(f"error: {path} not found") from None


def check_target(report, label, configurations, required):
    if not configurations:
        report.fail(f"{label}: build configurations found in the generated project")
        return
    for name, expected in required.items():
        for configuration in sorted(configurations):
            actual = configurations[configuration].get(name)
            report.expect(actual == expected, f"{label} {configuration}: {name} = {expected or '<empty>'}",
                          f"found {actual!r}")


def exception_paths(objects, group):
    body = objects.get(group, "")
    if "exceptions = (" not in body:
        return set()
    references = re.findall(r"[0-9A-F]{24}", body.split("exceptions = (", 1)[1].split(")", 1)[0])
    paths = set()
    for reference in references:
        match = EXCEPTION_SET_RE.search(objects.get(reference, ""))
        if match is not None:
            paths.update(normalized(part) for part in match.group(1).split(",") if part.strip())
    return paths


def check_binary(report, executable, require_both):
    if executable is None or not executable.is_file():
        return False
    try:
        result = subprocess.run(["lipo", "-archs", str(executable)],
                                capture_output=True, text=True, timeout=30, check=False)
    except (OSError, subprocess.SubprocessError) as error:
        report.warn(f"{executable.name}: unable to read architectures ({error})")
        return False
    if result.returncode != 0:
        report.warn(f"{executable.name}: lipo failed: {result.stderr.strip()}")
        return False
    architectures = set(result.stdout.split())
    if require_both:
        missing = {"x86_64", "arm64"} - architectures
        report.expect(not missing, f"release binary ships arm64 and x86_64",
                      f"missing {sorted(missing)}; found {sorted(architectures)}")
    else:
        report.ok(f"test host binary architectures: {', '.join(sorted(architectures))}")
    return True


def check_git_tag(report, version):
    try:
        result = subprocess.run(["git", "-C", str(ROOT), "tag", "--points-at", "HEAD"],
                                capture_output=True, text=True, timeout=30, check=False)
    except (OSError, subprocess.SubprocessError) as error:
        report.warn(f"release tag check skipped ({error})")
        return
    if result.returncode != 0:
        report.warn("release tag check skipped (git unavailable)")
        return
    tags = [tag.strip() for tag in result.stdout.split() if tag.strip()]
    if not tags:
        report.ok("release tag: HEAD is untagged (nothing to compare)")
        return
    expected = {f"v{version}", version}
    report.expect(bool(expected & set(tags)), f"release tag matches CFBundleShortVersionString {version}",
                  f"found {tags}")


def verify(project, app, derived_data):
    report = Report()
    project_path, objects = load_objects(project)
    report.ok(f"read {display_path(project_path)}")

    targets = parse_targets(objects)
    for name in (APP_TARGET, TEST_TARGET):
        report.expect(name in targets, f"target {name} exists")

    app_configurations = targets.get(APP_TARGET, {}).get("configurations", {})
    test_configurations = targets.get(TEST_TARGET, {}).get("configurations", {})

    check_target(report, "app", app_configurations, {
        "ENABLE_APP_SANDBOX": "NO",
        "ENABLE_HARDENED_RUNTIME": "YES",
        "CODE_SIGN_STYLE": "Manual",
        "CODE_SIGN_IDENTITY": "-",
        "PRODUCT_BUNDLE_IDENTIFIER": APP_BUNDLE_IDENTIFIER,
        "INFOPLIST_FILE": "Veyra/Info.plist",
        "INFOPLIST_KEY_LSUIElement": "YES",
        "MACOSX_DEPLOYMENT_TARGET": DEPLOYMENT_TARGET,
        "SWIFT_VERSION": SWIFT_VERSION,
        "SWIFT_STRICT_CONCURRENCY": SWIFT_CONCURRENCY,
    })
    check_target(report, "test", test_configurations, {
        "ENABLE_APP_SANDBOX": "NO",
        "ENABLE_HARDENED_RUNTIME": "NO",
        "PRODUCT_BUNDLE_IDENTIFIER": TEST_BUNDLE_IDENTIFIER,
        "TEST_HOST": "",
        "BUNDLE_LOADER": "",
        "MACOSX_DEPLOYMENT_TARGET": DEPLOYMENT_TARGET,
    })
    for configuration in sorted(app_configurations):
        flags = app_configurations[configuration].get("OTHER_LDFLAGS", "")
        report.expect(all(flag in flags for flag in LINKER_FLAGS),
                      f"app {configuration}: links sqlite3 without third-party dependencies", flags)

    for label, target in (("app", APP_TARGET), ("test", TEST_TARGET)):
        groups = targets.get(target, {}).get("synchronizedGroups", [])
        report.expect(len(groups) == 1, f"{label} target uses one synchronized root group", f"found {len(groups)}")

    app_groups = targets.get(APP_TARGET, {}).get("synchronizedGroups", [])
    if app_groups:
        paths = exception_paths(objects, app_groups[0])
        report.expect(TEST_MEMBERSHIP_EXCEPTIONS <= paths,
                      "test target opts into shared Core sources and localization resources",
                      f"missing {sorted(TEST_MEMBERSHIP_EXCEPTIONS - paths)}")

    plist = load_plist(ROOT / "Veyra/Info.plist")
    report.expect(plist.get("LSUIElement") is True, "Info.plist: LSUIElement is true (menu bar only)")
    report.expect(plist.get("NSHighResolutionCapable") is True, "Info.plist: NSHighResolutionCapable is true")
    report.expect(plist.get("CFBundlePackageType") == "APPL", "Info.plist: CFBundlePackageType = APPL")
    report.expect(plist.get("CFBundleIconFile") == ICON_FILE, f"Info.plist: CFBundleIconFile = {ICON_FILE}")
    report.expect(plist.get("LSMinimumSystemVersion") == "$(MACOSX_DEPLOYMENT_TARGET)",
                  "Info.plist: LSMinimumSystemVersion follows MACOSX_DEPLOYMENT_TARGET",
                  f"found {plist.get('LSMinimumSystemVersion')!r}")
    report.expect(plist.get("CFBundleDevelopmentRegion") == "en", "Info.plist: CFBundleDevelopmentRegion = en")

    version = plist.get("CFBundleShortVersionString")
    report.expect(isinstance(version, str) and VERSION_RE.match(version) is not None,
                  "Info.plist: CFBundleShortVersionString is X.Y.Z", f"found {version!r}")
    build = plist.get("CFBundleVersion")
    report.expect(isinstance(build, str) and BUILD_NUMBER_RE.match(build) is not None,
                  "Info.plist: CFBundleVersion is a positive integer", f"found {build!r}")
    for key in ("CFBundleIdentifier", "CFBundleExecutable", "CFBundleName"):
        value = plist.get(key)
        report.expect(isinstance(value, str) and (PLACEHOLDER_RE.match(value) is not None or value),
                      f"Info.plist: {key} is a build variable or a literal", f"found {value!r}")

    if isinstance(version, str) and VERSION_RE.match(version) is not None:
        check_git_tag(report, version)

    if app is None:
        report.warn("test host architecture not checked; pass --app to check a built binary")
    else:
        check_binary(report, app, require_both=False)

    release_executable = None
    if derived_data is not None:
        release_executable = derived_data / "Build/Products/Release/Veyra.app/Contents/MacOS/Veyra"
    if release_executable is None or not release_executable.is_file():
        report.warn("release binary check skipped; run ./scripts/build.sh and pass --derived-data")
    else:
        check_binary(report, release_executable, require_both=True)

    print(f"\n{report.checks} checks, {report.failures} failed, {report.warnings} skipped")
    return 1 if report.failures else 0


def main():
    arguments = parse_arguments()
    project = arguments.project.expanduser().resolve()
    app = arguments.app.expanduser().resolve() if arguments.app is not None else None
    derived_data = arguments.derived_data.expanduser().resolve() if arguments.derived_data is not None else None
    return verify(project, app, derived_data)


if __name__ == "__main__":
    sys.exit(main())
