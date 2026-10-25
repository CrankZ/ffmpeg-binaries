#!/usr/bin/env bash
# =============================================================================
# Windows x64 minimal FFmpeg 构建（在 MSYS2 MINGW64 shell 内运行）
#   * 静态链接：产物只依赖 KERNEL32/msvcrt 等系统 DLL
#   * 保留 pthreads + 运行时 CPU 检测，使用 -O2（禁止 --enable-small / --disable-asm）
#   * x86 SIMD 需要 nasm，缺失时 configure 会静默关闭汇编 —— 这里显式检查
#
# 产物: work/dist/ffmpeg-win-x64.zip  (ffmpeg.exe + LICENSE + BUILD.txt)
# 环境变量:
#   FFMPEG_VERSION     默认 9.0.2
#   WORK               默认 ./work
#   BUILD_REFERENCE    true 时额外构建全量参考版（用于 PCM/性能对比，不发布）
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/components.sh"
# shellcheck source=/dev/null
. "$HERE/common.sh"

export FFMPEG_VERSION="${FFMPEG_VERSION:-9.0.2}"
WORK="${WORK:-$PWD/work}"
DIST="$WORK/dist"

case "$(uname -s)" in
    MINGW*|MSYS*) ;;
    *) ffmpeg_min_die "本脚本必须在 MSYS2 MINGW64 shell 中运行（当前: $(uname -s)）" ;;
esac

command -v nasm >/dev/null 2>&1 ||
    ffmpeg_min_die "找不到 nasm —— x86_64 必须有 nasm，否则汇编路径被关闭、解码性能大幅下降"

ffmpeg_min_source "$FFMPEG_VERSION" "$WORK"
bash "$HERE/check-components.sh" "$FFMPEG_SRC"

BUILD="$WORK/build/win-x64"
PLATFORM_LABEL="windows-x64 (MSYS2 MINGW64)"

# --enable-pthreads / --disable-w32threads: 与官方 Windows 构建保持一致（pthreads 线程模型）
# --extra-ldflags=-static: 把 libwinpthread / libgcc 也静态链进来，避免出现第三方 DLL 依赖
ffmpeg_min_configure "$BUILD" "$PLATFORM_LABEL" \
    --arch=x86_64 \
    --target-os=mingw32 \
    --enable-pthreads \
    --disable-w32threads \
    --x86asmexe=nasm \
    --extra-ldflags="-static"

grep -q 'HAVE_X86ASM 1' "$BUILD/config.h" ||
    ffmpeg_min_die "configure 未启用 x86 汇编（HAVE_X86ASM=0），性能不可接受"

ffmpeg_min_make "$BUILD"

ffmpeg_min_log "strip"
"${STRIP:-strip}" "$BUILD/ffmpeg.exe"

ffmpeg_min_package "$BUILD/ffmpeg.exe" "$BUILD" "$DIST" \
    "ffmpeg-win-x64.zip" "$PLATFORM_LABEL"

if [ "${BUILD_REFERENCE:-false}" = "true" ]; then
    ffmpeg_min_build_reference "$WORK/build/ref-win-x64" \
        --arch=x86_64 \
        --target-os=mingw32 \
        --enable-pthreads \
        --disable-w32threads \
        --x86asmexe=nasm \
        --extra-ldflags="-static"
fi

ffmpeg_min_log "完成: $DIST/ffmpeg-win-x64.zip"
