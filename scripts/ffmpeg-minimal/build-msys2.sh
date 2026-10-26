#!/usr/bin/env bash
# =============================================================================
# Windows x64 minimal FFmpeg 构建（在 MSYS2 MINGW64 shell 内运行）
#   * 静态链接：产物只依赖 KERNEL32/msvcrt 等系统 DLL
#   * 保留 pthreads + 运行时 CPU 检测，使用官方默认的 -O3（禁止 --enable-small / --disable-asm）
#   * x86 SIMD 需要 nasm，缺失时 configure 会静默关闭汇编 —— 这里显式检查
#
# 产物: work/dist/ffmpeg-win-x64.zip  (ffmpeg.exe + LICENSE + BUILD.txt)
# 环境变量:
#   FFMPEG_VERSION     默认 9.0.2
#   FFMPEG_SHA256      可选，源码 tar.xz 的 sha256（设置后强校验）
#   WORK               默认 ./work
#   BUILD_TARGET       minimal | reference | all（默认 all，本地一次跑完）
#   BUILD_REFERENCE    true 时也构建参考版（兼容旧用法，等价于把 reference 目标加进来）
#   REUSE_REFERENCE    true 且已存在同版本参考产物时跳过全量编译（CI 缓存用）
#   CCACHE_DIR         设置后自动用 ccache 包装 gcc（CI 缓存用）
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

BUILD_TARGET="${BUILD_TARGET:-all}"
case "$BUILD_TARGET" in
    all|minimal|reference) ;;
    *) ffmpeg_min_die "BUILD_TARGET 只能是 all | minimal | reference（当前: $BUILD_TARGET）" ;;
esac

DO_MINIMAL=0
DO_REFERENCE=0
case "$BUILD_TARGET" in
    all)       DO_MINIMAL=1; DO_REFERENCE=1 ;;
    minimal)   DO_MINIMAL=1 ;;
    reference) DO_REFERENCE=1 ;;
esac
[ "${BUILD_REFERENCE:-false}" = "true" ] && DO_REFERENCE=1

command -v nasm >/dev/null 2>&1 ||
    ffmpeg_min_die "找不到 nasm —— x86_64 必须有 nasm，否则汇编路径被关闭、解码性能大幅下降"

ffmpeg_min_source "$FFMPEG_VERSION" "$WORK"

BUILD="$WORK/build/win-x64"
REF_BUILD="$WORK/build/ref-win-x64"

if [ "$DO_MINIMAL" -eq 1 ]; then
    bash "$HERE/check-components.sh" "$FFMPEG_SRC"

    ffmpeg_min_cc_args gcc

    # --enable-pthreads / --disable-w32threads: 与官方 Windows 构建保持一致（pthreads 线程模型）
    # --extra-ldflags=-static: 把 libwinpthread / libgcc 也静态链进来，避免出现第三方 DLL 依赖
    ffmpeg_min_configure "$BUILD" "windows-x64 (MSYS2 MINGW64)" \
        --arch=x86_64 \
        --target-os=mingw32 \
        --enable-pthreads \
        --disable-w32threads \
        --x86asmexe=nasm \
        --extra-ldflags="-static" \
        ${FFMPEG_MIN_CC_ARGS[@]+"${FFMPEG_MIN_CC_ARGS[@]}"}

    grep -q 'HAVE_X86ASM 1' "$BUILD/config.h" ||
        ffmpeg_min_die "configure 未启用 x86 汇编（HAVE_X86ASM=0），性能不可接受"

    ffmpeg_min_make "$BUILD"

    ffmpeg_min_log "strip"
    "${STRIP:-strip}" "$BUILD/ffmpeg.exe"

    ffmpeg_min_package "$BUILD/ffmpeg.exe" "$BUILD" "$DIST" \
        "ffmpeg-win-x64.zip" "windows-x64 (MSYS2 MINGW64)"
fi

if [ "$DO_REFERENCE" -eq 1 ]; then
    if ! ffmpeg_min_reference_reuse "$REF_BUILD" "$FFMPEG_VERSION"; then
        ffmpeg_min_cc_args gcc
        ffmpeg_min_build_reference "$REF_BUILD" \
            --arch=x86_64 \
            --target-os=mingw32 \
            --enable-pthreads \
            --disable-w32threads \
            --x86asmexe=nasm \
            --extra-ldflags="-static" \
            ${FFMPEG_MIN_CC_ARGS[@]+"${FFMPEG_MIN_CC_ARGS[@]}"}
    fi
fi

if [ "$DO_MINIMAL" -eq 1 ]; then
    ffmpeg_min_log "完成: $DIST/ffmpeg-win-x64.zip"
else
    ffmpeg_min_log "完成: $REF_BUILD/ffmpeg.exe（参考构建）"
fi
