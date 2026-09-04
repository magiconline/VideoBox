# Third-party notices for the bundled media runtime

VideoBox application source code is licensed under the MIT License. The separately executable `ffmpeg` and `ffprobe` programs bundled with the macOS distribution are not covered by the VideoBox MIT License.

The bundled FFmpeg runtime is built with GPL components and is distributed under the GNU General Public License, version 2 or (at your option) any later version. In particular, it contains x264 and x265 software encoders. It does not use FFmpeg's `--enable-version3` or `--enable-nonfree` build options.

Exact corresponding source code, including the build scripts and configuration needed to reproduce the binaries, is published beside every VideoBox DMG as `VideoBox-<version>-ffmpeg-corresponding-source.tar.xz` on the [VideoBox GitHub Releases page](https://github.com/magiconline/VideoBox/releases).

| Component | Version | Upstream | License |
| --- | --- | --- | --- |
| FFmpeg | 9.0.1 | <https://ffmpeg.org/> | GPL-2.0-or-later for this configured build |
| x264 | b35605ace3ddf7c1a5d67a2eb553f034aef41d55 | <https://code.videolan.org/videolan/x264> | GPL-2.0-or-later |
| x265 | 4.3 | <https://github.com/Multicorewareinc/x265> | GPL-2.0-or-later (a commercial alternative is available upstream) |
| Opus | 1.6.1 | <https://opus-codec.org/> | BSD-3-Clause |
| SVT-AV1 | 4.2.0 | <https://gitlab.com/AOMediaCodec/SVT-AV1> | BSD-3-Clause-Clear and Alliance for Open Media Patent License 1.0 |
| libass | 0.17.5 | <https://github.com/libass/libass> | ISC |
| FreeType | 2.14.3 | <https://freetype.org/> | GPL-2.0-or-later selected here (FreeType License also offered upstream) |
| FriBidi | 1.0.16 | <https://github.com/fribidi/fribidi> | LGPL-2.1-or-later |
| HarfBuzz | 14.3.1 | <https://github.com/harfbuzz/harfbuzz> | MIT |
| libunibreak | 7.0 | <https://github.com/adah1972/libunibreak> | Zlib |

Copies of the applicable license texts are installed inside `VideoBox.app/Contents/Resources/Licenses`. Copyright notices in the upstream sources remain intact.

Codec-related patent rights are separate from copyright licenses and may vary by jurisdiction. Distributors are responsible for evaluating any patent licenses required for their use or distribution.
