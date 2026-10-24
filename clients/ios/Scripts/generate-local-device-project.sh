#!/bin/sh
# A local-only device build with a real Share Extension. Uses Keychain Sharing,
# supported by wildcard development profiles; no App Group entitlement is needed.
# The regular project.yml keeps the production App Group / cloud configuration.
set -eu
ios_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
team_id=${1:?Usage: generate-local-device-project.sh DEVELOPMENT_TEAM [output-directory]}
output_dir=${2:-/tmp/mynah-local-device}
generator_binary="${TMPDIR:-/tmp}/mymah-xcodegen-2.46.0/xcodegen/bin/xcodegen"
if [ ! -x "$generator_binary" ]; then
    sh "$ios_root/Scripts/generate-project.sh"
fi
mkdir -p "$output_dir"
python3 - "$ios_root" "$team_id" "$output_dir" <<'PY'
import json, pathlib, sys
root, team, output = pathlib.Path(sys.argv[1]), sys.argv[2], pathlib.Path(sys.argv[3])
shared_info = {'CommonThreadKeychainGroup': '$(AppIdentifierPrefix)com.aigrandprix.mymahfinds.shared'}
shared_entitlements = {'keychain-access-groups': ['$(AppIdentifierPrefix)com.aigrandprix.mymahfinds.shared']}
project = {
    'name': 'Mynah Finds Local',
    'options': {'deploymentTarget': {'iOS': '18.0'}},
    'packages': {'CommonThreadKit': {'path': str(root)}},
    'settings': {'base': {'SWIFT_VERSION': '5.0', 'DEVELOPMENT_TEAM': team, 'CODE_SIGN_STYLE': 'Automatic', 'CURRENT_PROJECT_VERSION': 2, 'MARKETING_VERSION': '0.2.0'}},
    'targets': {
        'CommonThread': {
            'type': 'application', 'platform': 'iOS',
            'sources': [str(root / 'Examples/CommonThreadApp'), str(root / 'Examples/Shared')],
            'settings': {'base': {'PRODUCT_BUNDLE_IDENTIFIER': 'com.aigrandprix.mymahfinds', 'TARGETED_DEVICE_FAMILY': '1'}},
            'info': {'path': 'App-Info.plist', 'properties': {**shared_info,
                'CFBundleDisplayName': 'Mynah Finds', 'UILaunchScreen': {},
                'NSMicrophoneUsageDescription': 'Record your voice to add an editable note to a saved find.',
                'NSSpeechRecognitionUsageDescription': 'Turn your voice into an editable note about why you are saving this find.',
                'NSCameraUsageDescription': 'Take a photo to save something that caught your eye.',
                'UIApplicationSceneManifest': {'UIApplicationSupportsMultipleScenes': False}}},
            'entitlements': {'path': 'App.entitlements', 'properties': shared_entitlements},
            'dependencies': [{'package': 'CommonThreadKit'}, {'target': 'CommonThreadShare', 'embed': True}]},
        'CommonThreadShare': {
            'type': 'app-extension', 'platform': 'iOS',
            'sources': [str(root / 'Examples/ShareExtension'), str(root / 'Examples/Shared')],
            'settings': {'base': {'PRODUCT_BUNDLE_IDENTIFIER': 'com.aigrandprix.mymahfinds.share', 'APPLICATION_EXTENSION_API_ONLY': 'YES', 'SKIP_INSTALL': 'YES', 'TARGETED_DEVICE_FAMILY': '1'}},
            'info': {'path': 'Share-Info.plist', 'properties': {**shared_info,
                'CFBundleDisplayName': 'Mynah Finds',
                'NSExtension': {'NSExtensionPointIdentifier': 'com.apple.share-services',
                    'NSExtensionPrincipalClass': '$(PRODUCT_MODULE_NAME).ShareViewController',
                    'NSExtensionAttributes': {'NSExtensionActivationRule': {
                        'NSExtensionActivationSupportsWebURLWithMaxCount': 1,
                        'NSExtensionActivationSupportsText': True,
                        'NSExtensionActivationSupportsImageWithMaxCount': 10,
                        'NSExtensionActivationSupportsMovieWithMaxCount': 10,
                        'NSExtensionActivationSupportsFileWithMaxCount': 10}}}}},
            'entitlements': {'path': 'Share.entitlements', 'properties': shared_entitlements},
            'dependencies': [{'package': 'CommonThreadKit'}]}
    },
    'schemes': {'Mynah Finds': {'build': {'targets': {'CommonThread': 'all'}}, 'run': {'config': 'Debug'}}}
}
(output / 'project.json').write_text(json.dumps(project, indent=2))
PY
"$generator_binary" generate --spec "$output_dir/project.json" --project "$output_dir"
