#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
configuration=${1:-release}
architecture_string=${VIDEOBOX_ARCHS:-"arm64"}
architectures=(${=architecture_string})
signing_identity=${VIDEOBOX_SIGNING_IDENTITY:--}
runtime_root=${VIDEOBOX_FFMPEG_RUNTIME_DIR:-}
default_destination_app="$project_root/dist/VideoBox.app"
destination_app=${VIDEOBOX_APP_OUTPUT_PATH:-"$default_destination_app"}

if [[ "$destination_app" != /* || "${destination_app:t}" != "VideoBox.app" ]]; then
    print -u2 "VIDEOBOX_APP_OUTPUT_PATH must be an absolute path ending in VideoBox.app"
    exit 2
fi

destination_directory=${destination_app:h}

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

if [[ -z "$runtime_root" ]]; then
    if (( ${#architectures[@]} == 1 )); then
        runtime_architecture_label=${architectures[1]}
    else
        runtime_architecture_label=universal
    fi
    VIDEOBOX_FFMPEG_ARCHS="${architectures[*]}" "$script_dir/build_ffmpeg_runtime.sh"
    runtime_root="${VIDEOBOX_FFMPEG_BUILD_ROOT:-$project_root/.build/ffmpeg-runtime}/$runtime_architecture_label"
fi

swift build "${build_arguments[@]}"
binary_dir=$(swift build "${build_arguments[@]}" --show-bin-path)

source_binary="$binary_dir/VideoBox"
source_icon="$project_root/Assets/AppIcon.icns"
source_plist="$project_root/Packaging/Info.plist"
source_license="$project_root/LICENSE"
source_credits="$project_root/Packaging/Credits.rtf"
source_ffmpeg="$runtime_root/bin/ffmpeg"
source_ffprobe="$runtime_root/bin/ffprobe"
source_runtime_licenses="$runtime_root/licenses"
source_runtime_metadata="$runtime_root/metadata"
staging_root=$(mktemp -d "${TMPDIR:-/tmp}/VideoBox-package.XXXXXX")
staging_app="$staging_root/VideoBox.app"
version=${VIDEOBOX_VERSION:-$(plutil -extract CFBundleShortVersionString raw "$source_plist")}
build_number=${VIDEOBOX_BUILD_NUMBER:-$(plutil -extract CFBundleVersion raw "$source_plist")}

cleanup_staging() {
    rm -rf "$staging_root"
}
trap cleanup_staging EXIT

for required_file in \
    "$source_binary" \
    "$source_icon" \
    "$source_plist" \
    "$source_license" \
    "$source_credits" \
    "$source_ffmpeg" \
    "$source_ffprobe"; do
    if [[ ! -f "$required_file" ]]; then
        print -u2 "Missing packaging input: $required_file"
        exit 1
    fi
done

for required_directory in "$source_runtime_licenses" "$source_runtime_metadata"; do
    if [[ ! -d "$required_directory" ]]; then
        print -u2 "Missing packaging input: $required_directory"
        exit 1
    fi
done

mkdir -p \
    "$staging_app/Contents/MacOS" \
    "$staging_app/Contents/Helpers" \
    "$staging_app/Contents/Resources/Licenses" \
    "$staging_app/Contents/Resources/FFmpegMetadata"
ditto "$source_binary" "$staging_app/Contents/MacOS/VideoBox"
ditto "$source_ffmpeg" "$staging_app/Contents/Helpers/ffmpeg"
ditto "$source_ffprobe" "$staging_app/Contents/Helpers/ffprobe"
ditto "$source_icon" "$staging_app/Contents/Resources/AppIcon.icns"
ditto "$source_license" "$staging_app/Contents/Resources/Licenses/VideoBox-MIT.txt"
ditto "$source_credits" "$staging_app/Contents/Resources/Credits.rtf"
ditto "$source_runtime_licenses" "$staging_app/Contents/Resources/Licenses/FFmpegRuntime"
ditto "$source_runtime_metadata" "$staging_app/Contents/Resources/FFmpegMetadata"
ditto "$source_plist" "$staging_app/Contents/Info.plist"
chmod 755 \
    "$staging_app/Contents/MacOS/VideoBox" \
    "$staging_app/Contents/Helpers/ffmpeg" \
    "$staging_app/Contents/Helpers/ffprobe"

plutil -replace CFBundleShortVersionString -string "$version" "$staging_app/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$build_number" "$staging_app/Contents/Info.plist"
plutil -lint "$staging_app/Contents/Info.plist"

for packaged_executable in \
    "$staging_app/Contents/MacOS/VideoBox" \
    "$staging_app/Contents/Helpers/ffmpeg" \
    "$staging_app/Contents/Helpers/ffprobe"; do
    for architecture in "${architectures[@]}"; do
        if ! lipo "$packaged_executable" -verify_arch "$architecture"; then
            print -u2 "${packaged_executable:t} is missing required architecture: $architecture"
            exit 1
        fi
    done
done

codesign_arguments=(--force --sign "$signing_identity")
if [[ "$signing_identity" != "-" ]]; then
    codesign_arguments+=(--options runtime --timestamp)
fi
codesign "${codesign_arguments[@]}" "$staging_app/Contents/Helpers/ffmpeg"
codesign "${codesign_arguments[@]}" "$staging_app/Contents/Helpers/ffprobe"
codesign "${codesign_arguments[@]}" "$staging_app"
codesign --verify --deep --strict --verbose=2 "$staging_app"

mkdir -p "$destination_directory"
if [[ -e "$destination_app" ]]; then
    if [[ "$destination_app" != "$default_destination_app" ]]; then
        print -u2 "Refusing to replace unexpected path: $destination_app"
        exit 1
    fi
    rm -rf "$destination_app"
fi
ditto "$staging_app" "$destination_app"
touch "$destination_app"

print "Packaged VideoBox $version ($(lipo -archs "$destination_app/Contents/MacOS/VideoBox"))"
print "$destination_app"
