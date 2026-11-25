#!/usr/bin/env python3
"""Build a local, ad-hoc signed native app; no installation/network/device I/O."""
import argparse
import hashlib
import json
import plistlib
import platform
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parent
RESOURCES = BASE / 'Resources'
HOST_FILES = ('CalibrationModel.json', 'CFLOOKS.BIN', 'COPYING', 'FilmProfiles.icns')
LOCAL_CAMERA_FILES = (
    'AUTOEXEC.BIN', 'FirmwareSupport.json', 'NativeProfileTemplate.BIN', 'NativeProfileSupport.json',
    'NativeUserDefBootTemplate.bin', 'NativeUserDefSessionSupport.json',
)

def validate_camera_resources():
    """Validate the existing maintainer-only camera bundle inputs before building."""
    support = json.loads((RESOURCES / 'FirmwareSupport.json').read_text())
    payload = (RESOURCES / 'AUTOEXEC.BIN').read_bytes()
    if (support['payloadFile'] != 'AUTOEXEC.BIN' or len(payload) != 130640 or
            hashlib.sha256(payload).hexdigest() != support['payloadSHA256']):
        raise SystemExit('Bundled firmware does not match FirmwareSupport.json')
    native_support = json.loads((RESOURCES / 'NativeProfileSupport.json').read_text())
    native_payload = (RESOURCES / 'NativeProfileTemplate.BIN').read_bytes()
    if (len(native_payload) != 130280 or hashlib.sha256(native_payload).hexdigest() != native_support['sha256'] or
            native_support.get('interface') != 'native-embedded-profile-bank-v1' or
            ('public static let templateSHA256 = "' + native_support['sha256'] + '"') not in
            (BASE / 'Sources/ProfileCore/NativeBootPackageExporter.swift').read_text()):
        raise SystemExit('Bundled native template does not match the source-pinned export interface')
    userdef_support = json.loads((RESOURCES / 'NativeUserDefSessionSupport.json').read_text())
    userdef_payload = (RESOURCES / 'NativeUserDefBootTemplate.bin').read_bytes()
    userdef_source = (BASE / 'Sources/ProfileCore/NativeUserDefSessionPackageExporter.swift').read_text()
    expected_userdef_capabilities = {'capturedSingleDriveGuard': True, 'onCameraAssignmentNames': {'meaning': 'recipe-assignment-only', 'indicatesCaptureApplied': False, 'canonFallbackIfUnavailable': True, 'scopes': ['picture-style-main-menu-list', 'picture-style-shortcut-initial', 'picture-style-shortcut-move'], 'labelFormat': {'maxSourceBytes': 10, 'truncationMarker': '~', 'truncationMarkerOnlyIfLonger': True, 'literalASCII': True, 'slotIdentity': 'stock Canon icons', 'fullBankNamePreserved': True}}, 'sleepWakeQualified': False}
    if (userdef_support.get('sha256') == 'PENDING_FIRMWARE_TEMPLATE_PIN' or
            'PENDING_NATIVE_ROUTE_QUALIFICATION' in expected_userdef_capabilities['onCameraAssignmentNames']['scopes']):
        raise SystemExit('Captured-User-Def runtime pin/naming scope is pending qualification')
    if (userdef_support['payloadFile'] != 'NativeUserDefBootTemplate.bin' or
            len(userdef_payload) != userdef_support['bytes'] or
            hashlib.sha256(userdef_payload).hexdigest() != userdef_support['sha256'] or
            userdef_support.get('interface') != 'native-captured-userdef-session-v1' or
            userdef_support.get('sessionMagic') != 0x53465333 or
            userdef_support.get('selectionPolicy') != 2 or
            json.dumps(userdef_support.get('runtimeCapabilities'), sort_keys=True) != json.dumps(expected_userdef_capabilities, sort_keys=True) or
            ('public static let assignmentNameScopes = ' + json.dumps(expected_userdef_capabilities['onCameraAssignmentNames']['scopes'])) not in userdef_source or
            ('public static let assignmentNameMaxSourceBytes = ' + str(expected_userdef_capabilities['onCameraAssignmentNames']['labelFormat']['maxSourceBytes'])) not in userdef_source or
            ('public static let assignmentNameTruncationMarker = ' + json.dumps(expected_userdef_capabilities['onCameraAssignmentNames']['labelFormat']['truncationMarker'])) not in userdef_source or
            ('public static let templateSHA256 = "' + userdef_support['sha256'] + '"') not in userdef_source or
            ('public static let templateFile = "' + userdef_support['payloadFile'] + '"') not in userdef_source):
        raise SystemExit('Bundled captured-User-Def template does not match its separate source-pinned interface')
    return dict(firmware=support, nativeFirmware=native_support, nativeUserDefSession=userdef_support)


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, default=BASE / 'dist/Canon Film Profiles 0.6.4.app')
parser.add_argument('--scratch-path', type=Path, default=BASE / '.build')
parser.add_argument('--include-local-camera-resources', action='store_true',
                    help='opt in to bundling the pinned camera files in a maintainer workspace')
args = parser.parse_args()
scratch_path = args.scratch_path.resolve()
app = args.output.absolute()
if app.exists() or app.is_symlink():
    raise SystemExit('Refusing to overwrite an existing app bundle: ' + str(app))
camera_builds = {}
if args.include_local_camera_resources:
    missing = [name for name in LOCAL_CAMERA_FILES if not (RESOURCES / name).is_file()]
    if missing:
        raise SystemExit('Local camera resources are missing: ' + ', '.join(missing))
    camera_builds = validate_camera_resources()
swift_build = ['swift', 'build', '--package-path', str(BASE), '--scratch-path', str(scratch_path), '-c', 'release']
subprocess.run(swift_build + ['--product', 'CanonFilmProfiles'], check=True)
bin_path = Path(subprocess.check_output(swift_build + ['--show-bin-path'], text=True).strip())
app.parent.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='.canon-app-', dir=app.parent) as folder:
    staged_app = Path(folder) / app.name
    contents = staged_app / 'Contents'
    mac = contents / 'MacOS'
    res = contents / 'Resources'
    mac.mkdir(parents=True, exist_ok=True)
    res.mkdir(exist_ok=True)
    shutil.copyfile(bin_path / 'CanonFilmProfiles', mac / 'CanonFilmProfiles')
    (mac / 'CanonFilmProfiles').chmod(0o755)
    bundled_files = HOST_FILES + LOCAL_CAMERA_FILES if args.include_local_camera_resources else HOST_FILES
    for name in bundled_files:
        shutil.copyfile(RESOURCES / name, res / name)

    helper = contents / 'Helpers/CanonBatchHost'
    helper.parent.mkdir()
    host_builder = BASE / 'HostBatch/build.py'
    if not host_builder.is_file():
        host_builder = BASE.parents[1] / 'experiments/film-native-idle-batch-v1/host/build.py'
    with tempfile.TemporaryDirectory(prefix='canon-batch-helper.', dir='/private/tmp') as helper_folder:
        scratch = Path(helper_folder) / 'build'
        subprocess.run([sys.executable, str(host_builder), str(scratch)], check=True)
        shutil.copyfile(scratch / 'batch_host', helper)
        helper.chmod(0o755)
        helper_provenance = json.loads((scratch / 'source-pins.json').read_text())
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(helper)], check=True)
    helper_sha = hashlib.sha256(helper.read_bytes()).hexdigest()
    (res / 'HostBatchHelper.json').write_text(json.dumps({
        'protocolVersion': 1,
        'helperSHA256': helper_sha,
        'provenance': helper_provenance,
    }, indent=2, sort_keys=True) + '\n')

    catalog = RESOURCES / 'Assets.xcassets'
    shutil.copytree(catalog, res / catalog.name, ignore=shutil.ignore_patterns('.DS_Store', '._*'))
    # Full Xcode can compile the same catalog. Command Line Tools-only builds
    # resolve its appearance variants directly in FilmProfilesBrand.swift.
    asset_mode = 'appearance-aware-source-catalog'
    actool = subprocess.run(['/usr/bin/xcrun', '--find', 'actool'],
                            capture_output=True, text=True)
    if actool.returncode == 0:
        partial = scratch_path / 'BrandAssetInfo.plist'
        subprocess.run([actool.stdout.strip(), str(catalog), '--compile', str(res),
                        '--platform', 'macosx', '--minimum-deployment-target', '14.0',
                        '--target-device', 'mac', '--app-icon', 'AppIcon',
                        '--accent-color', 'AccentColor',
                        '--output-partial-info-plist', str(partial)], check=True)
        asset_mode = 'compiled-asset-catalog'

    info = dict(
        CFBundleName='Canon Film Profiles', CFBundleDisplayName='Canon Film Profiles',
        CFBundleIdentifier='local.canonfilmprofiles.editor', CFBundleExecutable='CanonFilmProfiles',
        CFBundlePackageType='APPL', CFBundleShortVersionString='0.6.4', CFBundleVersion='1',
        CFBundleIconFile='FilmProfiles', NSAccentColorName='AccentColor',
        LSMinimumSystemVersion='14.0', NSHighResolutionCapable=True,
        NSHumanReadableCopyright='Canon Film Profiles. Components use GPLv2; see Resources/COPYING.'
    )
    if args.include_local_camera_resources:
        info['NSAppleEventsUsageDescription'] = 'Authenticate a checked upload to the camera SD card.'
    if asset_mode == 'compiled-asset-catalog':
        info.update(plistlib.loads(partial.read_bytes()))
    (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(staged_app)], check=True)
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(staged_app)], check=True)
    if app.exists() or app.is_symlink():
        raise SystemExit('Refusing to overwrite an existing app bundle: ' + str(app))
    staged_app.rename(app)
(app.parent / 'build.json').write_text(json.dumps(dict(
    status='PASS_LOCAL_BUILD', app=str(app), architecture=platform.machine(), brandAssets=asset_mode,
    includesLocalCameraResources=args.include_local_camera_resources, **camera_builds,
    batchHelperSHA256=helper_sha,
    executableSHA256=hashlib.sha256((app / 'Contents/MacOS/CanonFilmProfiles').read_bytes()).hexdigest()
), indent=2) + '\n')
print(app)
