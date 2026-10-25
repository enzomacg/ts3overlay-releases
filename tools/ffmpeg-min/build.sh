#!/usr/bin/env bash
# tools/ffmpeg-min/build.sh — ffmpeg + ffprobe mínimos para el editor de clips / soundboard /
# marca de agua del overlay. Cross-compila a win64 (mingw) en Ubuntu, estático.
# Solo lo que usa el overlay (ver docs en project_flow.md, sección 2026-10-25):
#   leer: H.264 / HEVC / AV1 / VP8 / VP9 (+alfa) / MPEG-4 / MJPEG / PNG / qtrle, NVDEC
#   audio: AAC / MP3 / Opus / Vorbis / FLAC / AC3 / E-AC3 / ALAC / PCM
#   codificar: x264, NVENC (H.264), AAC, PNG, qtrle, PCM
#   filtros: trim/atrim/concat/setpts, scale (+scale_cuda), overlay, volume(detect), showwavespic…
# Corre en GitHub Actions (.github/workflows/ffmpeg-min.yml). Salida: out/editor-min.zip
set -euo pipefail

FFMPEG_TAG=n8.1.3
NVHDR_TAG=n12.1.14.0
DAV1D_TAG=1.5.4
VPX_TAG=v1.15.2
ZLIB_VER=1.3.1
HOST=x86_64-w64-mingw32

ROOT=$(pwd)
PREFIX=$ROOT/build/prefix
SRC=$ROOT/build/src
OUT=$ROOT/out
mkdir -p "$PREFIX" "$SRC" "$OUT"
export PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig
export PKG_CONFIG_LIBDIR=$PREFIX/lib/pkgconfig
JOBS=$(nproc)
cd "$SRC"

echo "::group::zlib"
curl -fsSL "https://zlib.net/fossils/zlib-$ZLIB_VER.tar.gz" | tar xz
make -C "zlib-$ZLIB_VER" -f win32/Makefile.gcc PREFIX=$HOST- -j"$JOBS" libz.a
install -D "zlib-$ZLIB_VER/libz.a" "$PREFIX/lib/libz.a"
install -D -t "$PREFIX/include" "zlib-$ZLIB_VER/zlib.h" "zlib-$ZLIB_VER/zconf.h"
mkdir -p "$PREFIX/lib/pkgconfig"
cat > "$PREFIX/lib/pkgconfig/zlib.pc" <<EOF
prefix=$PREFIX
libdir=\${prefix}/lib
includedir=\${prefix}/include
Name: zlib
Description: zlib
Version: $ZLIB_VER
Libs: -L\${libdir} -lz
Cflags: -I\${includedir}
EOF
echo "::endgroup::"

echo "::group::nv-codec-headers"
git clone -q --depth 1 -b "$NVHDR_TAG" https://github.com/FFmpeg/nv-codec-headers.git
make -C nv-codec-headers PREFIX="$PREFIX" install
echo "::endgroup::"

echo "::group::x264"
git clone -q --depth 1 -b stable https://code.videolan.org/videolan/x264.git
( cd x264 && ./configure --host=$HOST --cross-prefix=$HOST- --prefix="$PREFIX" \
    --enable-static --disable-cli --enable-pic --disable-opencl --disable-avs --disable-swscale --disable-lavf --disable-ffms --disable-gpac --disable-lsmash \
  && make -j"$JOBS" && make install )
echo "::endgroup::"

echo "::group::dav1d"
git clone -q --depth 1 -b "$DAV1D_TAG" https://code.videolan.org/videolan/dav1d.git
cat > cross.txt <<EOF
[binaries]
c = '$HOST-gcc'
cpp = '$HOST-g++'
ar = '$HOST-ar'
strip = '$HOST-strip'
windres = '$HOST-windres'
pkg-config = 'pkg-config'
[host_machine]
system = 'windows'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF
meson setup dav1d/build dav1d --cross-file cross.txt --prefix="$PREFIX" --libdir=lib \
  --default-library=static --buildtype=release -Denable_tools=false -Denable_tests=false -Denable_examples=false
ninja -C dav1d/build install
echo "::endgroup::"

echo "::group::libvpx (solo decoder VP9, para el alfa de la marca)"
git clone -q --depth 1 -b "$VPX_TAG" https://chromium.googlesource.com/webm/libvpx
( cd libvpx && CROSS=$HOST- ./configure --target=x86_64-win64-gcc --prefix="$PREFIX" \
    --disable-examples --disable-tools --disable-docs --disable-unit-tests --disable-encoders --disable-vp8 \
    --enable-static --disable-shared --as=nasm \
  && make -j"$JOBS" && make install )
echo "::endgroup::"

echo "::group::ffmpeg"
git clone -q --depth 1 -b "$FFMPEG_TAG" https://github.com/FFmpeg/FFmpeg.git ffmpeg
cd ffmpeg
DEMUXERS=mov,matroska,avi,flv,mpegts,mp3,wav,ogg,flac,aac,ac3,eac3,concat,image2,png_pipe,mjpeg,h264,hevc,ivf,m4v
MUXERS=mp4,mov,ipod,wav,image2,null,matroska,adts
DECODERS=h264,hevc,av1,libdav1d,vp8,vp9,libvpx_vp9,mpeg4,mjpeg,png,qtrle,aac,aac_latm,mp3,mp3float,mp2,opus,vorbis,flac,ac3,eac3,alac,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s32le,pcm_f32le,pcm_f64le,pcm_u8,pcm_alaw,pcm_mulaw
ENCODERS=libx264,h264_nvenc,aac,png,qtrle,pcm_s16le
PARSERS=h264,hevc,av1,vp8,vp9,aac,aac_latm,mpegaudio,opus,vorbis,flac,ac3,png,mjpeg,mpeg4video
HWACCELS=h264_nvdec,hevc_nvdec,av1_nvdec,vp8_nvdec,vp9_nvdec
FILTERS=scale,scale_cuda,hwdownload,hwupload,hwupload_cuda,format,aformat,aresample,overlay,trim,atrim,concat,setpts,asetpts,volume,volumedetect,showwavespic,showwaves,null,anull,split,asplit,fps,select,aselect,crop,pad,copy,acopy,color,testsrc,anullsrc,nullsrc,colorchannelmixer,fade,afade,amix,apad,pan
./configure --prefix="$PREFIX" --arch=x86_64 --target-os=mingw32 --cross-prefix=$HOST- \
  --pkg-config=pkg-config --pkg-config-flags=--static \
  --enable-gpl --enable-version3 --enable-static --disable-shared --disable-debug --disable-doc --disable-ffplay \
  --disable-autodetect --disable-everything --disable-network \
  --enable-zlib --enable-libx264 --enable-libdav1d --enable-libvpx \
  --enable-ffnvcodec --enable-nvenc --enable-nvdec --enable-cuda --enable-cuda-llvm --nvcc=clang \
  --enable-protocol=file,pipe --enable-indev=lavfi \
  --enable-demuxer=$DEMUXERS --enable-muxer=$MUXERS \
  --enable-decoder=$DECODERS --enable-encoder=$ENCODERS \
  --enable-parser=$PARSERS --enable-bsfs --enable-hwaccel=$HWACCELS --enable-filter=$FILTERS \
  --extra-cflags="-O2 -I$PREFIX/include" --extra-ldflags="-static -L$PREFIX/lib"
make -j"$JOBS"
$HOST-strip ffmpeg.exe ffprobe.exe
cp ffmpeg.exe ffprobe.exe "$OUT/"
cd "$OUT"
{
  echo "ffmpeg $FFMPEG_TAG mínimo para TS3 Overlay (GPL). Fuentes: https://github.com/FFmpeg/FFmpeg/tree/$FFMPEG_TAG"
  echo "x264 (stable), dav1d $DAV1D_TAG, libvpx $VPX_TAG, zlib $ZLIB_VER, nv-codec-headers $NVHDR_TAG"
  echo "Script de build: https://github.com/enzomacg/ts3overlay-releases/blob/main/tools/ffmpeg-min/build.sh"
} > README.txt
cp "$SRC/ffmpeg/COPYING.GPLv3" LICENSE.txt
zip -9 -q editor-min.zip ffmpeg.exe ffprobe.exe README.txt LICENSE.txt
ls -la "$OUT"
echo "::endgroup::"
