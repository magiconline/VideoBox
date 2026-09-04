#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
configuration=${1:-release}
signing_identity=${VIDEOBOX_SIGNING_IDENTITY:--}
notary_profile=${VIDEOBOX_NOTARY_PROFILE:-}

app_path=$("$script_dir/package_app.sh" "$configuration" | tail -n 1)
version=$(plutil -extract CFBundleShortVersionString raw "$app_path/Contents/Info.plist")
binary_architectures=$(lipo -archs "$app_path/Contents/MacOS/VideoBox")

if [[ "$binary_architectures" == *arm64* && "$binary_architectures" == *x86_64* ]]; then
    architecture_label=universal
else
    architecture_label=${binary_architectures// /-}
fi

distribution_dir="$project_root/dist"
dmg_name="VideoBox-${version}-macOS-${architecture_label}.dmg"
destination_dmg="$distribution_dir/$dmg_name"
checksum_path="$destination_dmg.sha256"
staging_root=$(mktemp -d "${TMPDIR:-/tmp}/VideoBox-dmg.XXXXXX")
volume_source="$staging_root/VideoBox $version"
temporary_dmg="$staging_root/$dmg_name"
mount_point="$staging_root/mount"
is_mounted=0

cleanup_staging() {
    if (( is_mounted )); then
        hdiutil detach "$mount_point" -quiet || true
    fi
    rm -rf "$staging_root"
}
trap cleanup_staging EXIT

mkdir -p "$volume_source" "$mount_point" "$distribution_dir"
ditto "$app_path" "$volume_source/VideoBox.app"
ln -s /Applications "$volume_source/Applications"

hdiutil create \
    -volname "VideoBox $version" \
    -srcfolder "$volume_source" \
    -format UDZO \
    -ov \
    "$temporary_dmg"

if [[ -e "$destination_dmg" ]]; then
    rm -f "$destination_dmg"
fi
ditto "$temporary_dmg" "$destination_dmg"

if [[ "$signing_identity" != "-" ]]; then
    codesign --force --sign "$signing_identity" --timestamp "$destination_dmg"
    codesign --verify --verbose=2 "$destination_dmg"
fi

if [[ -n "$notary_profile" ]]; then
    if [[ "$signing_identity" == "-" ]]; then
        print -u2 "VIDEOBOX_NOTARY_PROFILE requires a Developer ID signing identity"
        exit 2
    fi
    xcrun notarytool submit "$destination_dmg" \
        --keychain-profile "$notary_profile" \
        --wait
    xcrun stapler staple "$destination_dmg"
    xcrun stapler validate "$destination_dmg"
fi

hdiutil attach "$destination_dmg" \
    -nobrowse \
    -readonly \
    -mountpoint "$mount_point" \
    -quiet
is_mounted=1

[[ -d "$mount_point/VideoBox.app" ]]
[[ -L "$mount_point/Applications" ]]
codesign --verify --deep --strict --verbose=2 "$mount_point/VideoBox.app"

hdiutil detach "$mount_point" -quiet
is_mounted=0

(
    cd "$distribution_dir"
    shasum -a 256 "$dmg_name" > "$dmg_name.sha256"
)

print "Created and verified: $destination_dmg"
print "SHA-256: $(awk '{print $1}' "$checksum_path")"
