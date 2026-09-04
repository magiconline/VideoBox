#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
source "$script_dir/ffmpeg_versions.sh"

build_root=${VIDEOBOX_FFMPEG_BUILD_ROOT:-"$project_root/.build/ffmpeg-runtime"}
architecture_string=${VIDEOBOX_FFMPEG_ARCHS:-${VIDEOBOX_ARCHS:-"arm64"}}
architectures=(${=architecture_string})
deployment_target=${VIDEOBOX_DEPLOYMENT_TARGET:-13.0}
build_jobs=${VIDEOBOX_BUILD_JOBS:-$(sysctl -n hw.logicalcpu)}
force_build=${VIDEOBOX_FFMPEG_FORCE_BUILD:-0}
download_only=${VIDEOBOX_FFMPEG_DOWNLOAD_ONLY:-0}
provided_source_root=${VIDEOBOX_FFMPEG_SOURCE_ROOT:-}

download_dir="$build_root/downloads"
if [[ -n "$provided_source_root" ]]; then
    source_root=${provided_source_root:A}
else
    source_root="$build_root/sources"
fi
build_dir="$build_root/build"
prefix_root="$build_root/prefix"

if (( ${#architectures[@]} == 0 )); then
    print -u2 "VIDEOBOX_FFMPEG_ARCHS must contain at least one architecture"
    exit 2
fi

for architecture in "${architectures[@]}"; do
    case "$architecture" in
        arm64|x86_64) ;;
        *)
            print -u2 "Unsupported FFmpeg architecture: $architecture"
            exit 2
            ;;
    esac
done

if (( ${#architectures[@]} == 1 )); then
    runtime_architecture_label=${architectures[1]}
else
    runtime_architecture_label=universal
fi
runtime_root="$build_root/$runtime_architecture_label"

for required_tool in curl shasum tar make cmake nasm pkg-config xcrun lipo libtool otool; do
    if ! command -v "$required_tool" >/dev/null 2>&1; then
        print -u2 "Missing FFmpeg build tool: $required_tool"
        print -u2 "Install local build prerequisites with: brew install cmake nasm pkgconf"
        exit 1
    fi
done

mkdir -p "$download_dir" "$source_root" "$build_dir" "$prefix_root"

download_source() {
    local archive_name=$1
    local source_url=$2
    local expected_sha=$3
    local archive_path="$download_dir/$archive_name"
    local actual_sha=""

    if [[ -f "$archive_path" ]]; then
        actual_sha=$(shasum -a 256 "$archive_path" | awk '{print $1}')
    fi

    if [[ "$actual_sha" != "$expected_sha" ]]; then
        rm -f "$archive_path"
        print "Downloading $archive_name"
        curl -fL --retry 3 --output "$archive_path" "$source_url"
        actual_sha=$(shasum -a 256 "$archive_path" | awk '{print $1}')
    fi

    if [[ "$actual_sha" != "$expected_sha" ]]; then
        print -u2 "Checksum mismatch for $archive_name"
        print -u2 "Expected: $expected_sha"
        print -u2 "Actual:   $actual_sha"
        exit 1
    fi
}

extract_source() {
    local archive_name=$1
    local source_directory=$2
    local destination="$source_root/$source_directory"

    if [[ -d "$destination" ]]; then
        return
    fi

    print "Extracting $archive_name"
    tar -xf "$download_dir/$archive_name" -C "$source_root"
    if [[ ! -d "$destination" ]]; then
        print -u2 "Archive $archive_name did not create $source_directory"
        exit 1
    fi
}

source_directories=(
    "$FFMPEG_SOURCE_DIR"
    "$X264_SOURCE_DIR"
    "$X265_SOURCE_DIR"
    "$OPUS_SOURCE_DIR"
    "$SVT_AV1_SOURCE_DIR"
    "$LIBASS_SOURCE_DIR"
    "$FREETYPE_SOURCE_DIR"
    "$FRIBIDI_SOURCE_DIR"
    "$HARFBUZZ_SOURCE_DIR"
    "$LIBUNIBREAK_SOURCE_DIR"
)

if [[ -z "$provided_source_root" ]]; then
    download_source "$FFMPEG_ARCHIVE" "$FFMPEG_URL" "$FFMPEG_SHA256"
    download_source "$X264_ARCHIVE" "$X264_URL" "$X264_SHA256"
    download_source "$X265_ARCHIVE" "$X265_URL" "$X265_SHA256"
    download_source "$OPUS_ARCHIVE" "$OPUS_URL" "$OPUS_SHA256"
    download_source "$SVT_AV1_ARCHIVE" "$SVT_AV1_URL" "$SVT_AV1_SHA256"
    download_source "$LIBASS_ARCHIVE" "$LIBASS_URL" "$LIBASS_SHA256"
    download_source "$FREETYPE_ARCHIVE" "$FREETYPE_URL" "$FREETYPE_SHA256"
    download_source "$FRIBIDI_ARCHIVE" "$FRIBIDI_URL" "$FRIBIDI_SHA256"
    download_source "$HARFBUZZ_ARCHIVE" "$HARFBUZZ_URL" "$HARFBUZZ_SHA256"
    download_source "$LIBUNIBREAK_ARCHIVE" "$LIBUNIBREAK_URL" "$LIBUNIBREAK_SHA256"

    extract_source "$FFMPEG_ARCHIVE" "$FFMPEG_SOURCE_DIR"
    extract_source "$X264_ARCHIVE" "$X264_SOURCE_DIR"
    extract_source "$X265_ARCHIVE" "$X265_SOURCE_DIR"
    extract_source "$OPUS_ARCHIVE" "$OPUS_SOURCE_DIR"
    extract_source "$SVT_AV1_ARCHIVE" "$SVT_AV1_SOURCE_DIR"
    extract_source "$LIBASS_ARCHIVE" "$LIBASS_SOURCE_DIR"
    extract_source "$FREETYPE_ARCHIVE" "$FREETYPE_SOURCE_DIR"
    extract_source "$FRIBIDI_ARCHIVE" "$FRIBIDI_SOURCE_DIR"
    extract_source "$HARFBUZZ_ARCHIVE" "$HARFBUZZ_SOURCE_DIR"
    extract_source "$LIBUNIBREAK_ARCHIVE" "$LIBUNIBREAK_SOURCE_DIR"
else
    for source_directory in "${source_directories[@]}"; do
        if [[ ! -d "$source_root/$source_directory" ]]; then
            print -u2 "Provided source directory is missing: $source_root/$source_directory"
            exit 1
        fi
    done
fi

if [[ "$download_only" == "1" ]]; then
    print "$source_root"
    exit 0
fi

sdk_path=$(xcrun --sdk macosx --show-sdk-path)
clang_path=$(xcrun --find clang)
clangxx_path=$(xcrun --find clang++)
ar_path=$(xcrun --find ar)
ranlib_path=$(xcrun --find ranlib)
strip_path=$(xcrun --find strip)

host_for_architecture() {
    case "$1" in
        arm64) print "aarch64-apple-darwin" ;;
        x86_64) print "x86_64-apple-darwin" ;;
    esac
}

build_architecture() {
    local architecture=$1
    local host
    host=$(host_for_architecture "$architecture")
    local prefix="$prefix_root/$architecture"
    local architecture_build_dir="$build_dir/$architecture"
    local stamp_dir="$prefix/.videobox-stamps"
    local common_cflags="-arch $architecture -isysroot $sdk_path -mmacosx-version-min=$deployment_target -O3 -fPIC"
    local common_ldflags="-arch $architecture -isysroot $sdk_path -mmacosx-version-min=$deployment_target"

    if [[ "$force_build" == "1" ]]; then
        rm -rf "$architecture_build_dir" "$prefix"
    fi

    mkdir -p "$architecture_build_dir" "$prefix" "$stamp_dir"

    (
        export CC="$clang_path"
        export CXX="$clangxx_path"
        export AR="$ar_path"
        export RANLIB="$ranlib_path"
        export STRIP="$strip_path"
        export CFLAGS="$common_cflags"
        export CXXFLAGS="$common_cflags"
        export CPPFLAGS="-I$prefix/include"
        export LDFLAGS="$common_ldflags -L$prefix/lib"
        export PKG_CONFIG_PATH="$prefix/lib/pkgconfig:$prefix/share/pkgconfig"
        export PKG_CONFIG_LIBDIR="$PKG_CONFIG_PATH"
        export MACOSX_DEPLOYMENT_TARGET="$deployment_target"

        if [[ ! -f "$stamp_dir/opus-$OPUS_VERSION" ]]; then
            local opus_build="$architecture_build_dir/opus"
            rm -rf "$opus_build"
            mkdir -p "$opus_build"
            cd "$opus_build"
            "$source_root/$OPUS_SOURCE_DIR/configure" \
                --prefix="$prefix" \
                --host="$host" \
                --enable-static \
                --disable-shared \
                --disable-doc \
                --disable-extra-programs
            make -j "$build_jobs"
            make install
            touch "$stamp_dir/opus-$OPUS_VERSION"
        fi

        if [[ ! -f "$stamp_dir/freetype-$FREETYPE_VERSION" ]]; then
            local freetype_build="$architecture_build_dir/freetype"
            rm -rf "$freetype_build"
            mkdir -p "$freetype_build"
            cd "$freetype_build"
            "$source_root/$FREETYPE_SOURCE_DIR/configure" \
                --prefix="$prefix" \
                --host="$host" \
                --enable-static \
                --disable-shared \
                --with-bzip2=no \
                --with-png=no \
                --with-harfbuzz=no \
                --with-brotli=no
            make -j "$build_jobs"
            make install
            touch "$stamp_dir/freetype-$FREETYPE_VERSION"
        fi

        if [[ ! -f "$stamp_dir/fribidi-$FRIBIDI_VERSION" ]]; then
            local fribidi_build="$architecture_build_dir/fribidi"
            rm -rf "$fribidi_build"
            mkdir -p "$fribidi_build"
            cd "$fribidi_build"
            "$source_root/$FRIBIDI_SOURCE_DIR/configure" \
                --prefix="$prefix" \
                --host="$host" \
                --enable-static \
                --disable-shared
            make -j "$build_jobs"
            make install
            touch "$stamp_dir/fribidi-$FRIBIDI_VERSION"
        fi

        if [[ ! -f "$stamp_dir/libunibreak-$LIBUNIBREAK_VERSION" ]]; then
            local libunibreak_build="$architecture_build_dir/libunibreak"
            rm -rf "$libunibreak_build"
            mkdir -p "$libunibreak_build"
            cd "$libunibreak_build"
            "$source_root/$LIBUNIBREAK_SOURCE_DIR/configure" \
                --prefix="$prefix" \
                --host="$host" \
                --enable-static \
                --disable-shared
            make -j "$build_jobs"
            make install
            touch "$stamp_dir/libunibreak-$LIBUNIBREAK_VERSION"
        fi

        if [[ ! -f "$stamp_dir/harfbuzz-$HARFBUZZ_VERSION" ]]; then
            local harfbuzz_build="$architecture_build_dir/harfbuzz"
            rm -rf "$harfbuzz_build"
            cmake \
                -S "$source_root/$HARFBUZZ_SOURCE_DIR" \
                -B "$harfbuzz_build" \
                -DCMAKE_BUILD_TYPE=Release \
                -DCMAKE_INSTALL_PREFIX="$prefix" \
                -DCMAKE_INSTALL_LIBDIR=lib \
                -DCMAKE_OSX_ARCHITECTURES="$architecture" \
                -DCMAKE_OSX_DEPLOYMENT_TARGET="$deployment_target" \
                -DCMAKE_OSX_SYSROOT="$sdk_path" \
                -DCMAKE_PREFIX_PATH="$prefix" \
                -DCMAKE_C_COMPILER="$clang_path" \
                -DCMAKE_CXX_COMPILER="$clangxx_path" \
                -DCMAKE_C_FLAGS="$common_cflags" \
                -DCMAKE_CXX_FLAGS="$common_cflags" \
                -DBUILD_SHARED_LIBS=OFF \
                -DHB_HAVE_FREETYPE=ON \
                -DHB_HAVE_CORETEXT=ON \
                -DHB_HAVE_CAIRO=OFF \
                -DHB_HAVE_GLIB=OFF \
                -DHB_HAVE_ICU=OFF \
                -DHB_HAVE_GRAPHITE2=OFF \
                -DHB_BUILD_UTILS=OFF \
                -DHB_BUILD_SUBSET=OFF \
                -DHB_BUILD_RASTER=OFF \
                -DHB_BUILD_VECTOR=OFF \
                -DHB_BUILD_GPU=OFF
            cmake --build "$harfbuzz_build" --parallel "$build_jobs"
            cmake --install "$harfbuzz_build"
            touch "$stamp_dir/harfbuzz-$HARFBUZZ_VERSION"
        fi

        if [[ ! -f "$stamp_dir/libass-$LIBASS_VERSION" ]]; then
            local libass_build="$architecture_build_dir/libass"
            rm -rf "$libass_build"
            mkdir -p "$libass_build"
            cd "$libass_build"
            LIBS="-lc++" "$source_root/$LIBASS_SOURCE_DIR/configure" \
                --prefix="$prefix" \
                --host="$host" \
                --enable-static \
                --disable-shared \
                --disable-fontconfig \
                --enable-coretext \
                --enable-libunibreak \
                --disable-test
            make -j "$build_jobs"
            make install
            touch "$stamp_dir/libass-$LIBASS_VERSION"
        fi

        if [[ ! -f "$stamp_dir/svt-av1-$SVT_AV1_VERSION" ]]; then
            local svt_build="$architecture_build_dir/svt-av1"
            rm -rf "$svt_build"
            cmake \
                -S "$source_root/$SVT_AV1_SOURCE_DIR" \
                -B "$svt_build" \
                -DCMAKE_BUILD_TYPE=Release \
                -DCMAKE_INSTALL_PREFIX="$prefix" \
                -DCMAKE_INSTALL_LIBDIR=lib \
                -DCMAKE_OSX_ARCHITECTURES="$architecture" \
                -DCMAKE_OSX_DEPLOYMENT_TARGET="$deployment_target" \
                -DCMAKE_OSX_SYSROOT="$sdk_path" \
                -DCMAKE_C_COMPILER="$clang_path" \
                -DCMAKE_CXX_COMPILER="$clangxx_path" \
                -DCMAKE_C_FLAGS="$common_cflags" \
                -DCMAKE_CXX_FLAGS="$common_cflags" \
                -DBUILD_SHARED_LIBS=OFF \
                -DBUILD_APPS=OFF \
                -DBUILD_TESTING=OFF \
                -DEXCLUDE_HASH=ON \
                -DSVT_AV1_LTO=OFF \
                -DENABLE_SVE=OFF \
                -DENABLE_SVE2=OFF
            cmake --build "$svt_build" --parallel "$build_jobs"
            cmake --install "$svt_build"
            touch "$stamp_dir/svt-av1-$SVT_AV1_VERSION"
        fi

        if [[ ! -f "$stamp_dir/x264-$X264_REVISION" ]]; then
            local x264_build="$architecture_build_dir/x264"
            rm -rf "$x264_build"
            mkdir -p "$x264_build"
            cd "$x264_build"
            "$source_root/$X264_SOURCE_DIR/configure" \
                --prefix="$prefix" \
                --host="$host" \
                --enable-static \
                --disable-cli \
                --disable-opencl \
                --enable-pic \
                --bit-depth=all \
                --chroma-format=all \
                --extra-cflags="$common_cflags" \
                --extra-ldflags="$common_ldflags"
            make -j "$build_jobs"
            make install-lib-static
            touch "$stamp_dir/x264-$X264_REVISION"
        fi

        if [[ ! -f "$stamp_dir/x265-$X265_VERSION" ]]; then
            local x265_build="$architecture_build_dir/x265"
            local x265_source="$source_root/$X265_SOURCE_DIR/source"
            rm -rf "$x265_build"
            mkdir -p "$x265_build/8bit" "$x265_build/10bit" "$x265_build/12bit"

            cmake \
                -S "$x265_source" \
                -B "$x265_build/12bit" \
                -DCMAKE_BUILD_TYPE=Release \
                -DCMAKE_INSTALL_PREFIX="$prefix" \
                -DCMAKE_INSTALL_LIBDIR=lib \
                -DCMAKE_OSX_ARCHITECTURES="$architecture" \
                -DCMAKE_OSX_DEPLOYMENT_TARGET="$deployment_target" \
                -DCMAKE_OSX_SYSROOT="$sdk_path" \
                -DCMAKE_C_COMPILER="$clang_path" \
                -DCMAKE_CXX_COMPILER="$clangxx_path" \
                -DCMAKE_C_FLAGS="$common_cflags" \
                -DCMAKE_CXX_FLAGS="$common_cflags" \
                -DENABLE_SHARED=OFF \
                -DENABLE_CLI=OFF \
                -DENABLE_PIC=ON \
                -DHIGH_BIT_DEPTH=ON \
                -DMAIN12=ON \
                -DEXPORT_C_API=OFF
            cmake --build "$x265_build/12bit" --parallel "$build_jobs"

            cmake \
                -S "$x265_source" \
                -B "$x265_build/10bit" \
                -DCMAKE_BUILD_TYPE=Release \
                -DCMAKE_INSTALL_PREFIX="$prefix" \
                -DCMAKE_INSTALL_LIBDIR=lib \
                -DCMAKE_OSX_ARCHITECTURES="$architecture" \
                -DCMAKE_OSX_DEPLOYMENT_TARGET="$deployment_target" \
                -DCMAKE_OSX_SYSROOT="$sdk_path" \
                -DCMAKE_C_COMPILER="$clang_path" \
                -DCMAKE_CXX_COMPILER="$clangxx_path" \
                -DCMAKE_C_FLAGS="$common_cflags" \
                -DCMAKE_CXX_FLAGS="$common_cflags" \
                -DENABLE_SHARED=OFF \
                -DENABLE_CLI=OFF \
                -DENABLE_PIC=ON \
                -DHIGH_BIT_DEPTH=ON \
                -DEXPORT_C_API=OFF
            cmake --build "$x265_build/10bit" --parallel "$build_jobs"

            ln -sf ../10bit/libx265.a "$x265_build/8bit/libx265_main10.a"
            ln -sf ../12bit/libx265.a "$x265_build/8bit/libx265_main12.a"
            cmake \
                -S "$x265_source" \
                -B "$x265_build/8bit" \
                -DCMAKE_BUILD_TYPE=Release \
                -DCMAKE_INSTALL_PREFIX="$prefix" \
                -DCMAKE_INSTALL_LIBDIR=lib \
                -DCMAKE_OSX_ARCHITECTURES="$architecture" \
                -DCMAKE_OSX_DEPLOYMENT_TARGET="$deployment_target" \
                -DCMAKE_OSX_SYSROOT="$sdk_path" \
                -DCMAKE_C_COMPILER="$clang_path" \
                -DCMAKE_CXX_COMPILER="$clangxx_path" \
                -DCMAKE_C_FLAGS="$common_cflags" \
                -DCMAKE_CXX_FLAGS="$common_cflags" \
                -DENABLE_SHARED=OFF \
                -DENABLE_CLI=OFF \
                -DENABLE_PIC=ON \
                -DEXTRA_LIB="x265_main10.a;x265_main12.a" \
                -DEXTRA_LINK_FLAGS=-L. \
                -DLINKED_10BIT=ON \
                -DLINKED_12BIT=ON
            cmake --build "$x265_build/8bit" --parallel "$build_jobs"
            mv "$x265_build/8bit/libx265.a" "$x265_build/8bit/libx265_main.a"
            libtool -static \
                -o "$x265_build/8bit/libx265.a" \
                "$x265_build/8bit/libx265_main.a" \
                "$x265_build/8bit/libx265_main10.a" \
                "$x265_build/8bit/libx265_main12.a"
            cmake --install "$x265_build/8bit"
            touch "$stamp_dir/x265-$X265_VERSION"
        fi

        if [[ ! -f "$stamp_dir/ffmpeg-$FFMPEG_VERSION" ]]; then
            local ffmpeg_build="$architecture_build_dir/ffmpeg"
            rm -rf "$ffmpeg_build"
            mkdir -p "$ffmpeg_build"
            cd "$ffmpeg_build"
            "$source_root/$FFMPEG_SOURCE_DIR/configure" \
                --prefix="$prefix" \
                --arch="$architecture" \
                --target-os=darwin \
                --enable-cross-compile \
                --sysroot="$sdk_path" \
                --cc="$clang_path" \
                --cxx="$clangxx_path" \
                --ar="$ar_path" \
                --ranlib="$ranlib_path" \
                --strip="$strip_path" \
                --pkg-config=pkg-config \
                --pkg-config-flags=--static \
                --extra-cflags="$common_cflags -I$prefix/include" \
                --extra-ldflags="$common_ldflags -L$prefix/lib" \
                --extra-libs=-lc++ \
                --enable-static \
                --disable-shared \
                --disable-autodetect \
                --disable-network \
                --disable-doc \
                --disable-debug \
                --disable-ffplay \
                --enable-pthreads \
                --enable-zlib \
                --enable-bzlib \
                --enable-iconv \
                --enable-audiotoolbox \
                --enable-videotoolbox \
                --enable-avfoundation \
                --enable-gpl \
                --enable-libass \
                --enable-libopus \
                --enable-libsvtav1 \
                --enable-libx264 \
                --enable-libx265
            make -j "$build_jobs"
            make install
            touch "$stamp_dir/ffmpeg-$FFMPEG_VERSION"
        fi
    )
}

for architecture in "${architectures[@]}"; do
    print "Building FFmpeg runtime for $architecture"
    build_architecture "$architecture"
done

staging_root=$(mktemp -d "$build_root/runtime-stage.XXXXXX")
cleanup_staging() {
    rm -rf "$staging_root"
}
trap cleanup_staging EXIT

mkdir -p "$staging_root/bin" "$staging_root/licenses" "$staging_root/metadata"

for executable in ffmpeg ffprobe; do
    inputs=()
    for architecture in "${architectures[@]}"; do
        input="$prefix_root/$architecture/bin/$executable"
        if [[ ! -x "$input" ]]; then
            print -u2 "Missing built executable: $input"
            exit 1
        fi
        inputs+=("$input")
    done
    lipo -create "${inputs[@]}" -output "$staging_root/bin/$executable"
    chmod 755 "$staging_root/bin/$executable"
done

ditto "$project_root/ThirdParty/FFmpeg/THIRD_PARTY_NOTICES.md" "$staging_root/licenses/THIRD_PARTY_NOTICES.md"
ditto "$source_root/$FFMPEG_SOURCE_DIR/COPYING.GPLv2" "$staging_root/licenses/FFmpeg-GPL-2.0.txt"
ditto "$source_root/$FFMPEG_SOURCE_DIR/LICENSE.md" "$staging_root/licenses/FFmpeg-LICENSE.md"
ditto "$source_root/$X264_SOURCE_DIR/COPYING" "$staging_root/licenses/x264-GPL-2.0.txt"
ditto "$source_root/$X265_SOURCE_DIR/COPYING" "$staging_root/licenses/x265-GPL-2.0.txt"
ditto "$source_root/$OPUS_SOURCE_DIR/COPYING" "$staging_root/licenses/Opus-COPYING.txt"
ditto "$source_root/$SVT_AV1_SOURCE_DIR/LICENSE.md" "$staging_root/licenses/SVT-AV1-BSD-3-Clause-Clear.txt"
ditto "$source_root/$SVT_AV1_SOURCE_DIR/PATENTS.md" "$staging_root/licenses/SVT-AV1-PATENTS.md"
ditto "$source_root/$LIBASS_SOURCE_DIR/COPYING" "$staging_root/licenses/libass-COPYING.txt"
ditto "$source_root/$FREETYPE_SOURCE_DIR/LICENSE.TXT" "$staging_root/licenses/FreeType-LICENSE.txt"
ditto "$source_root/$FREETYPE_SOURCE_DIR/docs/GPLv2.TXT" "$staging_root/licenses/FreeType-GPL-2.0.txt"
ditto "$source_root/$FRIBIDI_SOURCE_DIR/COPYING" "$staging_root/licenses/FriBidi-COPYING.txt"
ditto "$source_root/$HARFBUZZ_SOURCE_DIR/COPYING" "$staging_root/licenses/HarfBuzz-COPYING.txt"
ditto "$source_root/$LIBUNIBREAK_SOURCE_DIR/LICENCE" "$staging_root/licenses/libunibreak-LICENCE.txt"

{
    print "VideoBox bundled FFmpeg runtime"
    print "FFmpeg $FFMPEG_VERSION"
    print "x264 $X264_REVISION"
    print "x265 $X265_VERSION"
    print "Opus $OPUS_VERSION"
    print "SVT-AV1 $SVT_AV1_VERSION"
    print "libass $LIBASS_VERSION"
    print "FreeType $FREETYPE_VERSION"
    print "FriBidi $FRIBIDI_VERSION"
    print "HarfBuzz $HARFBUZZ_VERSION"
    print "libunibreak $LIBUNIBREAK_VERSION"
    print "Architectures: ${architectures[*]}"
    print "Minimum macOS: $deployment_target"
} > "$staging_root/metadata/COMPONENTS.txt"

"$staging_root/bin/ffmpeg" -hide_banner -version > "$staging_root/metadata/ffmpeg-version.txt"
"$staging_root/bin/ffmpeg" -hide_banner -buildconf > "$staging_root/metadata/ffmpeg-buildconf.txt"
"$staging_root/bin/ffmpeg" -hide_banner -L > "$staging_root/metadata/ffmpeg-license.txt"
"$staging_root/bin/ffmpeg" -hide_banner -encoders > "$staging_root/metadata/ffmpeg-encoders.txt" 2>&1
"$staging_root/bin/ffmpeg" -hide_banner -filters > "$staging_root/metadata/ffmpeg-filters.txt" 2>&1

if ! grep -q -- '--enable-gpl' "$staging_root/metadata/ffmpeg-buildconf.txt" \
    || grep -Eq -- '--enable-(nonfree|version3)' "$staging_root/metadata/ffmpeg-buildconf.txt"; then
    print -u2 "Bundled FFmpeg does not match the approved GPLv2-or-later configuration"
    exit 1
fi

if ! grep -q 'GNU General Public License' "$staging_root/metadata/ffmpeg-license.txt"; then
    print -u2 "Bundled FFmpeg did not report the expected GPL license"
    exit 1
fi

for required_encoder in libx264 libx265 libsvtav1 libopus h264_videotoolbox hevc_videotoolbox prores_ks; do
    if ! grep -q " $required_encoder " "$staging_root/metadata/ffmpeg-encoders.txt"; then
        print -u2 "Bundled FFmpeg is missing encoder: $required_encoder"
        exit 1
    fi
done

for required_filter in subtitles ass; do
    if ! grep -Eq "[[:space:]]${required_filter}[[:space:]]" "$staging_root/metadata/ffmpeg-filters.txt"; then
        print -u2 "Bundled FFmpeg is missing filter: $required_filter"
        exit 1
    fi
done

for executable in ffmpeg ffprobe; do
    dependencies=$(otool -L "$staging_root/bin/$executable")
    non_system_dependencies=$(print "$dependencies" \
        | awk '/^[[:space:]]/ {print $1}' \
        | grep -Ev '^(/System/Library/|/usr/lib/)' || true)
    if [[ -n "$non_system_dependencies" ]]; then
        print -u2 "Non-portable dependency detected in $executable"
        print -u2 "$non_system_dependencies"
        exit 1
    fi
done

VIDEOBOX_FFMPEG_RUNTIME_DIR="$staging_root" "$script_dir/verify_ffmpeg_runtime.sh"

if [[ -e "$runtime_root" ]]; then
    rm -rf "$runtime_root"
fi
ditto "$staging_root" "$runtime_root"

print "Built FFmpeg runtime (${architectures[*]})"
print "$runtime_root"
