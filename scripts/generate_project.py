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


core = sorted(ROOT.glob('Veyra/Core/*.swift'))
app = sorted(ROOT.glob('Veyra/App/*.swift'))
tests = sorted(ROOT.glob('VeyraTests/*.swift'))
all_files = core + app + tests
for path in all_files:
    relative = str(path.relative_to(ROOT))
    add(relative, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {quoted(relative)}; sourceTree = "<group>";')
add('info', 'isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Veyra/Info.plist; sourceTree = "<group>";')
add('icon', 'isa = PBXFileReference; lastKnownFileType = image.icns; path = Veyra/AppIcon.icns; sourceTree = "<group>";')
add('icon-build', f'isa = PBXBuildFile; fileRef = {ident("icon")};')
resources = sorted(ROOT.glob('Veyra/Resources/*.png'))
resource_refs = []
resource_builds = [ident('icon-build')]
for path in resources:
    relative = str(path.relative_to(ROOT))
    resource_refs.append(add(relative, f'isa = PBXFileReference; lastKnownFileType = image.png; path = {quoted(relative)}; sourceTree = "<group>";'))
    resource_builds.append(add(f'resource-{relative}', f'isa = PBXBuildFile; fileRef = {ident(relative)};'))
add('product-app', 'isa = PBXFileReference; explicitFileType = wrapper.application; path = "Veyra.app"; sourceTree = BUILT_PRODUCTS_DIR;')
add('product-test', 'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = VeyraTests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
add('products', f'isa = PBXGroup; name = Products; children = ({ident("product-app")}, {ident("product-test")},); sourceTree = "<group>";')
children = ', '.join(ident(str(p.relative_to(ROOT))) for p in all_files)
add('main-group', f'isa = PBXGroup; children = ({children}, {ident("info")}, {ident("icon")}, {", ".join(resource_refs)}, {ident("products")},); sourceTree = "<group>";')

common = '''SDKROOT = macosx; MACOSX_DEPLOYMENT_TARGET = 14.0; SWIFT_VERSION = 6.0;
SWIFT_STRICT_CONCURRENCY = complete; CLANG_ENABLE_MODULES = YES; CLANG_ENABLE_OBJC_WEAK = YES;
CODE_SIGN_STYLE = Manual; CODE_SIGN_IDENTITY = "-"; ENABLE_APP_SANDBOX = NO;
DEAD_CODE_STRIPPING = YES;
OTHER_LDFLAGS = "$(inherited) -lsqlite3"; COMBINE_HIDPI_IMAGES = YES;'''

recommended_warnings = '''CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING = YES;
CLANG_WARN_BOOL_CONVERSION = YES; CLANG_WARN_COMMA = YES;
CLANG_WARN_CONSTANT_CONVERSION = YES; CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS = YES;
CLANG_WARN_DIRECT_OBJC_ISA_USAGE = YES_ERROR; CLANG_WARN_DOCUMENTATION_COMMENTS = YES;
CLANG_WARN_EMPTY_BODY = YES; CLANG_WARN_ENUM_CONVERSION = YES;
CLANG_WARN_INFINITE_RECURSION = YES; CLANG_WARN_INT_CONVERSION = YES;
CLANG_WARN_NON_LITERAL_NULL_CONVERSION = YES; CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF = YES;
CLANG_WARN_OBJC_LITERAL_CONVERSION = YES; CLANG_WARN_OBJC_ROOT_CLASS = YES_ERROR;
CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER = YES; CLANG_WARN_RANGE_LOOP_ANALYSIS = YES;
CLANG_WARN_STRICT_PROTOTYPES = YES; CLANG_WARN_SUSPICIOUS_MOVE = YES;
CLANG_WARN_UNGUARDED_AVAILABILITY = YES_AGGRESSIVE; CLANG_WARN_UNREACHABLE_CODE = YES;
CLANG_WARN__DUPLICATE_METHOD_MATCH = YES; ENABLE_STRICT_OBJC_MSGSEND = YES;
GCC_NO_COMMON_BLOCKS = YES; GCC_WARN_64_TO_32_BIT_CONVERSION = YES;
GCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR; GCC_WARN_UNDECLARED_SELECTOR = YES;
GCC_WARN_UNINITIALIZED_AUTOS = YES_AGGRESSIVE; GCC_WARN_UNUSED_FUNCTION = YES;
GCC_WARN_UNUSED_VARIABLE = YES;'''

for target, files in [('app', core + app), ('test', core + [ROOT / 'Veyra/App/MonitorStore.swift'] + tests)]:
    build_files = []
    for path in files:
        name = str(path.relative_to(ROOT))
        build_files.append(add(f'{target}-{name}', f'isa = PBXBuildFile; fileRef = {ident(name)};'))
    add(f'{target}-sources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({", ".join(build_files)},); runOnlyForDeploymentPostprocessing = 0;')
    add(f'{target}-frameworks', 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
    bundled_resources = ', '.join(resource_builds) + ',' if target == 'app' else ''
    add(f'{target}-resources', f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({bundled_resources}); runOnlyForDeploymentPostprocessing = 0;')
    hardened_runtime = 'ENABLE_HARDENED_RUNTIME = YES;' if target == 'app' else 'ENABLE_HARDENED_RUNTIME = NO;'
    for config in ['Debug', 'Release']:
        # Keep the existing bundle IDs so a rename preserves saved user preferences.
        flags = 'SWIFT_OPTIMIZATION_LEVEL = "-Onone"; ENABLE_TESTABILITY = YES; DEBUG_INFORMATION_FORMAT = dwarf; SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;' if config == 'Debug' else 'SWIFT_OPTIMIZATION_LEVEL = "-O"; DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";'
        settings = 'PRODUCT_NAME = "Veyra"; PRODUCT_BUNDLE_IDENTIFIER = local.codexmonitor.app; INFOPLIST_FILE = Veyra/Info.plist; INFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.developer-tools"; LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/../Frameworks";' if target == 'app' else 'PRODUCT_NAME = VeyraTests; PRODUCT_BUNDLE_IDENTIFIER = local.codexmonitor.tests; GENERATE_INFOPLIST_FILE = YES; TEST_HOST = ""; BUNDLE_LOADER = "";'
        add(f'{target}-{config}', f'isa = XCBuildConfiguration; buildSettings = {{ {common} {hardened_runtime} {flags} {settings} }}; name = {config};')
    add(f'{target}-configs', f'isa = XCConfigurationList; buildConfigurations = ({ident(f"{target}-Debug")}, {ident(f"{target}-Release")},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
    name = 'Veyra' if target == 'app' else 'VeyraTests'
    product_type = 'com.apple.product-type.application' if target == 'app' else 'com.apple.product-type.bundle.unit-test'
    phases = ', '.join(ident(f'{target}-{phase}') for phase in ['sources', 'frameworks', 'resources'])
    add(f'target-{target}', f'isa = PBXNativeTarget; buildConfigurationList = {ident(f"{target}-configs")}; buildPhases = ({phases},); buildRules = (); dependencies = (); name = {name}; productName = {name}; productReference = {ident(f"product-{target}")}; productType = {quoted(product_type)};')

for config in ['Debug', 'Release']:
    config_settings = 'ENABLE_TESTABILITY = YES; ONLY_ACTIVE_ARCH = YES;' if config == 'Debug' else 'SWIFT_COMPILATION_MODE = wholemodule;'
    add(f'project-{config}', f'''isa = XCBuildConfiguration; buildSettings = {{
CLANG_ENABLE_MODULES = YES; DEAD_CODE_STRIPPING = YES; ENABLE_USER_SCRIPT_SANDBOXING = YES;
{recommended_warnings}
{config_settings}
}}; name = {config};''')
add('project-configs', f'isa = XCConfigurationList; buildConfigurations = ({ident("project-Debug")}, {ident("project-Release")},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
add('project', f'''isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 2660; }};
buildConfigurationList = {ident('project-configs')}; compatibilityVersion = "Xcode 14.0";
developmentRegion = zh_CN; hasScannedForEncodings = 0; knownRegions = (zh_CN, en, Base,);
mainGroup = {ident('main-group')}; productRefGroup = {ident('products')}; projectDirPath = "";
projectRoot = ""; targets = ({ident('target-app')}, {ident('target-test')},);''')

project = ROOT / 'Veyra.xcodeproj'
project.mkdir(exist_ok=True)
(project / 'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56;\nobjects = {\n' + '\n'.join(objects) + f'\n}}; rootObject = {ident("project")};\n}}\n')

scheme = project / 'xcshareddata/xcschemes'
scheme.mkdir(parents=True, exist_ok=True)


def reference(target):
    name = 'Veyra' if target == 'app' else 'VeyraTests'
    product = 'Veyra.app' if target == 'app' else 'VeyraTests.xctest'
    return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident(f"target-{target}")}" BuildableName="{product}" BlueprintName="{name}" ReferencedContainer="container:Veyra.xcodeproj"/>'


(scheme / 'Veyra.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2660" version="1.3">
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
print('Generated Veyra.xcodeproj')
