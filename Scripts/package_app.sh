#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
configuration=${1:-release}
architecture_string=${VIDEOBOX_ARCHS:-"arm64 x86_64"}
architectures=(${=architecture_string})
signing_identity=${VIDEOBOX_SIGNING_IDENTITY:--}

if [[ "$configuration" != "release" && "$configuration" != "debug" ]]; then
    print -u2 "Usage: $0 [release|debug]"
    exit 2
fi

if (( ${#architectures[@]} == 0 )); then
    print -u2 "VIDEOBOX_ARCHS must contain at least one architecture"
    exit 2
fi

build_arguments=(-c "$configuration")
for architecture in "${architectures[@]}"; do
    case "$architecture" in
        arm64|x86_64)
            build_arguments+=(--arch "$architecture")
            ;;
        *)
            print -u2 "Unsupported architecture: $architecture"
            exit 2
            ;;
    esac
done

cd "$project_root"

swift build "${build_arguments[@]}"
binary_dir=$(swift build "${build_arguments[@]}" --show-bin-path)

source_binary="$binary_dir/VideoBox"
source_icon="$project_root/Assets/AppIcon.icns"
source_plist="$project_root/Packaging/Info.plist"
distribution_dir="$project_root/dist"
destination_app="$distribution_dir/VideoBox.app"
staging_root=$(mktemp -d "${TMPDIR:-/tmp}/VideoBox-package.XXXXXX")
staging_app="$staging_root/VideoBox.app"
version=${VIDEOBOX_VERSION:-$(plutil -extract CFBundleShortVersionString raw "$source_plist")}
build_number=${VIDEOBOX_BUILD_NUMBER:-$(plutil -extract CFBundleVersion raw "$source_plist")}

cleanup_staging() {
    rm -rf "$staging_root"
}
trap cleanup_staging EXIT

for required_file in "$source_binary" "$source_icon" "$source_plist"; do
    if [[ ! -f "$required_file" ]]; then
        print -u2 "Missing packaging input: $required_file"
        exit 1
    fi
done

mkdir -p "$staging_app/Contents/MacOS" "$staging_app/Contents/Resources"
ditto "$source_binary" "$staging_app/Contents/MacOS/VideoBox"
ditto "$source_icon" "$staging_app/Contents/Resources/AppIcon.icns"
ditto "$source_plist" "$staging_app/Contents/Info.plist"
chmod 755 "$staging_app/Contents/MacOS/VideoBox"

plutil -replace CFBundleShortVersionString -string "$version" "$staging_app/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$build_number" "$staging_app/Contents/Info.plist"
plutil -lint "$staging_app/Contents/Info.plist"

codesign_arguments=(--force --deep --sign "$signing_identity")
if [[ "$signing_identity" != "-" ]]; then
    codesign_arguments+=(--options runtime --timestamp)
fi
codesign "${codesign_arguments[@]}" "$staging_app"
codesign --verify --deep --strict --verbose=2 "$staging_app"

mkdir -p "$distribution_dir"
if [[ -e "$destination_app" ]]; then
    if [[ "$destination_app" != "$project_root/dist/VideoBox.app" ]]; then
        print -u2 "Refusing to replace unexpected path: $destination_app"
        exit 1
    fi
    rm -rf "$destination_app"
fi
ditto "$staging_app" "$destination_app"
touch "$destination_app"

print "Packaged VideoBox $version ($(lipo -archs "$destination_app/Contents/MacOS/VideoBox"))"
print "$destination_app"
