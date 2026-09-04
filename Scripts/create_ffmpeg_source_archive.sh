#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
source "$script_dir/ffmpeg_versions.sh"

build_root=${VIDEOBOX_FFMPEG_BUILD_ROOT:-"$project_root/.build/ffmpeg-runtime"}
source_root=$(VIDEOBOX_FFMPEG_BUILD_ROOT="$build_root" VIDEOBOX_FFMPEG_DOWNLOAD_ONLY=1 \
    "$script_dir/build_ffmpeg_runtime.sh" | tail -n 1)
version=${VIDEOBOX_VERSION:-$(plutil -extract CFBundleShortVersionString raw "$project_root/Packaging/Info.plist")}
distribution_dir="$project_root/dist"
archive_name="VideoBox-${version}-ffmpeg-corresponding-source.tar.xz"
destination_archive="$distribution_dir/$archive_name"
checksum_path="$destination_archive.sha256"
staging_root=$(mktemp -d "${TMPDIR:-/tmp}/VideoBox-ffmpeg-source.XXXXXX")
archive_root="$staging_root/VideoBox-${version}-ffmpeg-corresponding-source"

cleanup_staging() {
    rm -rf "$staging_root"
}
trap cleanup_staging EXIT

mkdir -p \
    "$archive_root/Sources" \
    "$archive_root/Scripts" \
    "$archive_root/ThirdParty/FFmpeg" \
    "$distribution_dir"

for source_directory in \
    "$FFMPEG_SOURCE_DIR" \
    "$X264_SOURCE_DIR" \
    "$X265_SOURCE_DIR" \
    "$OPUS_SOURCE_DIR" \
    "$SVT_AV1_SOURCE_DIR" \
    "$LIBASS_SOURCE_DIR" \
    "$FREETYPE_SOURCE_DIR" \
    "$FRIBIDI_SOURCE_DIR" \
    "$HARFBUZZ_SOURCE_DIR" \
    "$LIBUNIBREAK_SOURCE_DIR"; do
    ditto "$source_root/$source_directory" "$archive_root/Sources/$source_directory"
done

ditto "$project_root/ThirdParty/FFmpeg/BUILDING.md" "$archive_root/BUILDING.md"
ditto "$project_root/ThirdParty/FFmpeg/BUILDING.md" "$archive_root/ThirdParty/FFmpeg/BUILDING.md"
ditto "$project_root/ThirdParty/FFmpeg/THIRD_PARTY_NOTICES.md" "$archive_root/ThirdParty/FFmpeg/THIRD_PARTY_NOTICES.md"
ditto "$script_dir/build_ffmpeg_runtime.sh" "$archive_root/Scripts/build_ffmpeg_runtime.sh"
ditto "$script_dir/ffmpeg_versions.sh" "$archive_root/Scripts/ffmpeg_versions.sh"
ditto "$script_dir/verify_ffmpeg_runtime.sh" "$archive_root/Scripts/verify_ffmpeg_runtime.sh"

(
    cd "$staging_root"
    COPYFILE_DISABLE=1 tar -cJf "$destination_archive" "${archive_root:t}"
)

(
    cd "$distribution_dir"
    shasum -a 256 "$archive_name" > "$archive_name.sha256"
)

print "Created corresponding-source archive: $destination_archive"
print "SHA-256: $(awk '{print $1}' "$checksum_path")"
print "$destination_archive"
