#!/usr/bin/env python3
"""Generate Tone's small, dependency-free Xcode project. Run after adding Swift files."""
from pathlib import Path
import hashlib
import json

ROOT = Path(__file__).resolve().parent.parent

def uid(value):
    return hashlib.sha1(value.encode()).hexdigest()[:24].upper()

def quote(value):
    return json.dumps(str(value), ensure_ascii=False)

objects = []

def obj(key, body):
    objects.append(f"{uid(key)} = {{ {body} }};")

sources = sorted((ROOT / "Tone").rglob("*.swift"))
for source in sources:
    relative = source.relative_to(ROOT / "Tone").as_posix()
    obj("ref:" + relative, f"isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {quote(relative)}; sourceTree = \"<group>\";")
    obj("build:" + relative, f"isa = PBXBuildFile; fileRef = {uid('ref:' + relative)};")

obj("product", 'isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Tone.app; sourceTree = BUILT_PRODUCTS_DIR;')
obj("signingConfig", 'isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = Configuration.xcconfig; sourceTree = "<group>";')
source_refs = ", ".join(uid("ref:" + s.relative_to(ROOT / "Tone").as_posix()) for s in sources)
build_refs = ", ".join(uid("build:" + s.relative_to(ROOT / "Tone").as_posix()) for s in sources)
obj("sourcesGroup", f'isa = PBXGroup; children = ({source_refs}, {uid("signingConfig")},); path = Tone; sourceTree = "<group>";')
obj("productsGroup", f'isa = PBXGroup; children = ({uid("product")},); name = Products; sourceTree = "<group>";')
obj("mainGroup", f'isa = PBXGroup; children = ({uid("sourcesGroup")}, {uid("productsGroup")},); sourceTree = "<group>";')
obj("sourcesPhase", f"isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({build_refs},); runOnlyForDeploymentPostprocessing = 0;")
obj("frameworksPhase", "isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;")
obj("resourcesPhase", "isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;")

for configuration in ["Debug", "Release"]:
    project_settings = {
        "ALWAYS_SEARCH_USER_PATHS": "NO", "CLANG_ENABLE_MODULES": "YES",
        "CLANG_ENABLE_OBJC_ARC": "YES", "SDKROOT": "iphoneos",
        "IPHONEOS_DEPLOYMENT_TARGET": "17.0", "SWIFT_VERSION": "5.0",
        "SWIFT_OPTIMIZATION_LEVEL": "-Onone" if configuration == "Debug" else "-O",
        "DEBUG_INFORMATION_FORMAT": "dwarf" if configuration == "Debug" else "dwarf-with-dsym",
        "ENABLE_TESTABILITY": "YES" if configuration == "Debug" else "NO",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG" if configuration == "Debug" else "",
    }
    target_settings = {
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "CODE_SIGN_STYLE": "Automatic", "GENERATE_INFOPLIST_FILE": "YES",
        "INFOPLIST_KEY_CFBundleDisplayName": "Tone",
        "INFOPLIST_KEY_NSMicrophoneUsageDescription": "Tone 使用麦克风实时检测你唱出或弹奏的音高。音频不会保存或上传。",
        "INFOPLIST_KEY_UILaunchScreen_Generation": "YES",
        "INFOPLIST_KEY_UIApplicationSceneManifest_Generation": "YES",
        "INFOPLIST_KEY_UISupportedInterfaceOrientations": "UIInterfaceOrientationPortrait",
        "TARGETED_DEVICE_FAMILY": "1", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
        "SUPPORTS_MACCATALYST": "NO", "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "NO",
        "MARKETING_VERSION": "0.1.2", "CURRENT_PROJECT_VERSION": "3",
        "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks",
    }
    for scope, settings in [("project", project_settings), ("target", target_settings)]:
        body = " ".join(f"{key} = {quote(value)};" for key, value in settings.items())
        base = f"baseConfigurationReference = {uid('signingConfig')};" if scope == "target" else ""
        obj(scope + configuration, f"isa = XCBuildConfiguration; {base} buildSettings = {{ {body} }}; name = {configuration};")

for scope in ["project", "target"]:
    obj(scope + "Configurations", f"isa = XCConfigurationList; buildConfigurations = ({uid(scope + 'Debug')}, {uid(scope + 'Release')},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;")

obj("target", f'isa = PBXNativeTarget; buildConfigurationList = {uid("targetConfigurations")}; buildPhases = ({uid("sourcesPhase")}, {uid("frameworksPhase")}, {uid("resourcesPhase")},); buildRules = (); dependencies = (); name = Tone; productName = Tone; productReference = {uid("product")}; productType = "com.apple.product-type.application";')
obj("project", f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 1600; TargetAttributes = {{ {uid("target")} = {{ CreatedOnToolsVersion = 16.0; }}; }}; }}; buildConfigurationList = {uid("projectConfigurations")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base, "zh-Hans",); mainGroup = {uid("mainGroup")}; productRefGroup = {uid("productsGroup")}; projectDirPath = ""; projectRoot = ""; targets = ({uid("target")},);')

project = ROOT / "Tone.xcodeproj"
project.mkdir(exist_ok=True)
(project / "project.pbxproj").write_text(
    "// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n"
    + "\n".join(objects) + f"\n}}; rootObject = {uid('project')}; }}\n"
)
scheme_dir = project / "xcshareddata" / "xcschemes"
scheme_dir.mkdir(parents=True, exist_ok=True)
reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid("target")}" BuildableName="Tone.app" BlueprintName="Tone" ReferencedContainer="container:Tone.xcodeproj"/>'
(scheme_dir / "Tone.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
    <BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference}</BuildActionEntry></BuildActionEntries>
  </BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables/></TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print(f"Generated Tone.xcodeproj ({len(sources)} Swift files).")
