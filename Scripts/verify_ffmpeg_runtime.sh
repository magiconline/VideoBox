#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
runtime_root=${VIDEOBOX_FFMPEG_RUNTIME_DIR:-${1:-"$project_root/.build/ffmpeg-runtime/arm64"}}
ffmpeg="$runtime_root/bin/ffmpeg"
ffprobe="$runtime_root/bin/ffprobe"
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/VideoBox-ffmpeg-smoke.XXXXXX")

cleanup_temporary_directory() {
    rm -rf "$temporary_directory"
}
trap cleanup_temporary_directory EXIT

for executable in "$ffmpeg" "$ffprobe"; do
    if [[ ! -x "$executable" ]]; then
        print -u2 "Missing runtime executable: $executable"
        exit 1
    fi
done

"$ffmpeg" -v error \
    -f lavfi -i "testsrc2=size=160x96:rate=12" \
    -frames:v 4 -threads 2 -c:v libx264 -preset ultrafast -pix_fmt yuv420p \
    "$temporary_directory/x264.mp4"

"$ffmpeg" -v error \
    -f lavfi -i "testsrc2=size=160x96:rate=12" \
    -frames:v 4 -threads 2 -c:v libx265 -preset ultrafast \
    -x265-params "log-level=error" -pix_fmt yuv420p \
    "$temporary_directory/x265.mp4"

"$ffmpeg" -v error \
    -f lavfi -i "testsrc2=size=160x96:rate=12" \
    -frames:v 4 -threads 2 -vf "format=yuv420p10le" \
    -c:v libx265 -preset ultrafast -profile:v main10 \
    -x265-params "log-level=error" -pix_fmt yuv420p10le \
    "$temporary_directory/x265-10bit.mp4"

"$ffmpeg" -v error \
    -f lavfi -i "testsrc2=size=160x96:rate=12" \
    -frames:v 4 -threads 2 -c:v libsvtav1 -preset 11 -pix_fmt yuv420p \
    "$temporary_directory/av1.mkv"

"$ffmpeg" -v error \
    -f lavfi -i "sine=frequency=1000:sample_rate=48000" \
    -t 0.25 -threads 2 -c:a libopus \
    "$temporary_directory/opus.ogg"

printf '1\n00:00:00,000 --> 00:00:00,250\nVideoBox\n' \
    > "$temporary_directory/subtitle.srt"
"$ffmpeg" -v error \
    -f lavfi -i "color=size=160x96:rate=12:color=black" \
    -frames:v 2 -vf "subtitles=$temporary_directory/subtitle.srt" -f null -

for output in x264.mp4 x265.mp4 x265-10bit.mp4 av1.mkv opus.ogg; do
    "$ffprobe" -v error -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 "$temporary_directory/$output" >/dev/null
done

print "Verified x264, x265 (8/10-bit), AV1, Opus, subtitle burn-in, and ffprobe"
