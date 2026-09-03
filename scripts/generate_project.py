#!/usr/bin/env python3
"""Generate the dependency-free Xcode project after adding/removing Swift files."""
import hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def ident(name):
    return hashlib.sha1(name.encode()).hexdigest()[:24].upper()


def quoted(value):
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'


objects = []


def add(name, body):
    objects.append(f'{ident(name)} = {{ {body} }};')
    return ident(name)


core = sorted(ROOT.glob('CodexMonitor/Core/*.swift'))
app = sorted(ROOT.glob('CodexMonitor/App/*.swift'))
tests = sorted(ROOT.glob('CodexMonitorTests/*.swift'))
all_files = core + app + tests
for path in all_files:
    relative = str(path.relative_to(ROOT))
    add(relative, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {quoted(relative)}; sourceTree = "<group>";')
add('info', 'isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = CodexMonitor/Info.plist; sourceTree = "<group>";')
add('icon', 'isa = PBXFileReference; lastKnownFileType = image.icns; path = CodexMonitor/AppIcon.icns; sourceTree = "<group>";')
add('icon-build', f'isa = PBXBuildFile; fileRef = {ident("icon")};')
for variant in ['Light', 'Dark']:
    add(f'codex-mark-{variant}', f'isa = PBXFileReference; lastKnownFileType = image.png; path = CodexMonitor/Resources/CodexMark{variant}.png; sourceTree = "<group>";')
    add(f'codex-mark-build-{variant}', f'isa = PBXBuildFile; fileRef = {ident(f"codex-mark-{variant}")};')
add('product-app', 'isa = PBXFileReference; explicitFileType = wrapper.application; path = "Codex Monitor.app"; sourceTree = BUILT_PRODUCTS_DIR;')
add('product-test', 'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = CodexMonitorTests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
add('products', f'isa = PBXGroup; name = Products; children = ({ident("product-app")}, {ident("product-test")},); sourceTree = "<group>";')
children = ', '.join(ident(str(p.relative_to(ROOT))) for p in all_files)
add('main-group', f'isa = PBXGroup; children = ({children}, {ident("info")}, {ident("icon")}, {ident("codex-mark-Light")}, {ident("codex-mark-Dark")}, {ident("products")},); sourceTree = "<group>";')

common = '''SDKROOT = macosx; MACOSX_DEPLOYMENT_TARGET = 14.0; SWIFT_VERSION = 6.0;
SWIFT_STRICT_CONCURRENCY = complete; CLANG_ENABLE_MODULES = YES; CODE_SIGN_STYLE = Manual;
CODE_SIGN_IDENTITY = "-"; ENABLE_APP_SANDBOX = NO; ENABLE_HARDENED_RUNTIME = NO;
OTHER_LDFLAGS = "$(inherited) -lsqlite3"; COMBINE_HIDPI_IMAGES = YES;'''

for target, files in [('app', core + app), ('test', core + tests)]:
    build_files = []
    for path in files:
        name = str(path.relative_to(ROOT))
        build_files.append(add(f'{target}-{name}', f'isa = PBXBuildFile; fileRef = {ident(name)};'))
    add(f'{target}-sources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({", ".join(build_files)},); runOnlyForDeploymentPostprocessing = 0;')
    add(f'{target}-frameworks', 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
    resources = ', '.join(ident(name) for name in ['icon-build', 'codex-mark-build-Light', 'codex-mark-build-Dark']) + ',' if target == 'app' else ''
    add(f'{target}-resources', f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({resources}); runOnlyForDeploymentPostprocessing = 0;')
    for config in ['Debug', 'Release']:
        flags = 'SWIFT_OPTIMIZATION_LEVEL = "-Onone"; ENABLE_TESTABILITY = YES; DEBUG_INFORMATION_FORMAT = dwarf; SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;' if config == 'Debug' else 'SWIFT_OPTIMIZATION_LEVEL = "-O"; DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";'
        settings = 'PRODUCT_NAME = "Codex Monitor"; PRODUCT_BUNDLE_IDENTIFIER = local.codexmonitor.app; INFOPLIST_FILE = CodexMonitor/Info.plist; LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/../Frameworks";' if target == 'app' else 'PRODUCT_NAME = CodexMonitorTests; PRODUCT_BUNDLE_IDENTIFIER = local.codexmonitor.tests; GENERATE_INFOPLIST_FILE = YES; TEST_HOST = ""; BUNDLE_LOADER = "";'
        add(f'{target}-{config}', f'isa = XCBuildConfiguration; buildSettings = {{ {common} {flags} {settings} }}; name = {config};')
    add(f'{target}-configs', f'isa = XCConfigurationList; buildConfigurations = ({ident(f"{target}-Debug")}, {ident(f"{target}-Release")},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
    name = 'CodexMonitor' if target == 'app' else 'CodexMonitorTests'
    product_type = 'com.apple.product-type.application' if target == 'app' else 'com.apple.product-type.bundle.unit-test'
    phases = ', '.join(ident(f'{target}-{phase}') for phase in ['sources', 'frameworks', 'resources'])
    add(f'target-{target}', f'isa = PBXNativeTarget; buildConfigurationList = {ident(f"{target}-configs")}; buildPhases = ({phases},); buildRules = (); dependencies = (); name = {name}; productName = {name}; productReference = {ident(f"product-{target}")}; productType = {quoted(product_type)};')

for config in ['Debug', 'Release']:
    add(f'project-{config}', f'isa = XCBuildConfiguration; buildSettings = {{ CLANG_ENABLE_MODULES = YES; }}; name = {config};')
add('project-configs', f'isa = XCConfigurationList; buildConfigurations = ({ident("project-Debug")}, {ident("project-Release")},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
add('project', f'''isa = PBXProject; attributes = {{ LastUpgradeCheck = 2600; }};
buildConfigurationList = {ident('project-configs')}; compatibilityVersion = "Xcode 14.0";
developmentRegion = zh_CN; hasScannedForEncodings = 0; knownRegions = (zh_CN, en, Base,);
mainGroup = {ident('main-group')}; productRefGroup = {ident('products')}; projectDirPath = "";
projectRoot = ""; targets = ({ident('target-app')}, {ident('target-test')},);''')

project = ROOT / 'CodexMonitor.xcodeproj'
project.mkdir(exist_ok=True)
(project / 'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56;\nobjects = {\n' + '\n'.join(objects) + f'\n}}; rootObject = {ident("project")};\n}}\n')

scheme = project / 'xcshareddata/xcschemes'
scheme.mkdir(parents=True, exist_ok=True)


def reference(target):
    name = 'CodexMonitor' if target == 'app' else 'CodexMonitorTests'
    product = 'Codex Monitor.app' if target == 'app' else 'CodexMonitorTests.xctest'
    return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident(f"target-{target}")}" BuildableName="{product}" BlueprintName="{name}" ReferencedContainer="container:CodexMonitor.xcodeproj"/>'


(scheme / 'CodexMonitor.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
    <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference('app')}</BuildActionEntry>
    <BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{reference('test')}</BuildActionEntry>
  </BuildActionEntries></BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES">
    <Testables><TestableReference skipped="NO">{reference('test')}</TestableReference></Testables>
  </TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference('app')}</BuildableProductRunnable></LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference('app')}</BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print('Generated CodexMonitor.xcodeproj')
