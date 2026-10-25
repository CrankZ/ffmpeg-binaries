#!/usr/bin/env bash
# =============================================================================
# macOS minimal FFmpeg 构建
#   * arm64 (Apple Silicon) 与 x86_64 (Intel) 分别 out-of-tree 构建
#   * universal 用 lipo 合并（一次 configure 不可能直接产出 universal）
#   * 最低系统版本 13.0（-mmacosx-version-min=13.0，两个架构都要）
#   * 静态可执行：只依赖 /usr/lib/libSystem 等系统库
#   * arm64 上必须重新 ad-hoc 签名（strip / lipo 会破坏原签名，否则无法运行）
#
# 产物: work/dist/ffmpeg-macos-{arm64,x64,universal}.zip
# 环境变量:
#   FFMPEG_VERSION        默认 9.0.2
#   MACOSX_DEPLOYMENT_TARGET 默认 13.0
#   WORK                  默认 ./work
#   BUILD_REFERENCE       true 时额外构建全量参考版（arm64，不发布）
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/components.sh"
# shellcheck source=/dev/null
. "$HERE/common.sh"

export FFMPEG_VERSION="${FFMPEG_VERSION:-9.0.2}"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
WORK="${WORK:-$PWD/work}"
DIST="$WORK/dist"
MIN_OS="$MACOSX_DEPLOYMENT_TARGET"
HOST_ARCH="$(uname -m)"

[ "$(uname -s)" = "Darwin" ] || ffmpeg_min_die "本脚本只在 macOS 上运行"

ffmpeg_min_source "$FFMPEG_VERSION" "$WORK"
bash "$HERE/check-components.sh" "$FFMPEG_SRC"

command -v nasm >/dev/null 2>&1 ||
    ffmpeg_min_die "找不到 nasm —— 构建 x86_64 切片必须有 nasm"

# -----------------------------------------------------------------------------
build_arch() {
    local arch="$1"
    local builddir="$WORK/build/macos-$arch"
    local platform_label="macos-$arch (deployment target $MIN_OS)"
    local extra

    if [ "$arch" = "arm64" ]; then
        extra=(
            --arch=arm64
            --cc=clang
            --extra-cflags="-mmacosx-version-min=$MIN_OS"
            --extra-ldflags="-mmacosx-version-min=$MIN_OS"
        )
    else
        extra=(
            --arch=x86_64
            --target-os=darwin
            --cc=clang
            --host-cc=clang
            --host-cflags="-arch x86_64"
            --host-ldflags="-arch x86_64"
            --x86asmexe=nasm
            --extra-cflags="-arch x86_64 -mmacosx-version-min=$MIN_OS"
            --extra-ldflags="-arch x86_64 -mmacosx-version-min=$MIN_OS"
        )
        # 在 Apple Silicon 上为 Intel 目标构建 = 交叉编译
        if [ "$HOST_ARCH" != "x86_64" ]; then
            extra+=(--enable-cross-compile)
        fi
    fi

    ffmpeg_min_configure "$builddir" "$platform_label" "${extra[@]}"

    if [ "$arch" = "x86_64" ]; then
        grep -q 'HAVE_X86ASM 1' "$builddir/config.h" ||
            ffmpeg_min_die "configure 未启用 x86 汇编（HAVE_X86ASM=0），性能不可接受"
    fi

    ffmpeg_min_make "$builddir"

    ffmpeg_min_log "strip + ad-hoc 签名 ($arch)"
    strip -x "$builddir/ffmpeg"
    codesign --force --sign - "$builddir/ffmpeg"
}

build_arch arm64
build_arch x86_64

# -----------------------------------------------------------------------------
# universal = lipo(arm64, x86_64)
# -----------------------------------------------------------------------------
UNIV="$WORK/build/macos-universal"
mkdir -p "$UNIV"
ffmpeg_min_log "lipo 合并 universal"
rm -f "$UNIV/ffmpeg"
lipo -create \
    "$WORK/build/macos-arm64/ffmpeg" \
    "$WORK/build/macos-x86_64/ffmpeg" \
    -output "$UNIV/ffmpeg"
codesign --force --sign - "$UNIV/ffmpeg"

{
    echo "# macos-universal = lipo(arm64, x86_64)"
    echo "#"
    sed 's/^/# --- arm64 ---/;1d' "$WORK/build/macos-arm64/configure.cmd"
    echo "#"
    sed 's/^/# --- x86_64 ---/;1d' "$WORK/build/macos-x86_64/configure.cmd"
} > "$UNIV/configure.cmd"

# -----------------------------------------------------------------------------
ffmpeg_min_package "$WORK/build/macos-arm64/ffmpeg" "$WORK/build/macos-arm64" \
    "$DIST" "ffmpeg-macos-arm64.zip" "macos-arm64 (deployment target $MIN_OS)"
ffmpeg_min_package "$WORK/build/macos-x86_64/ffmpeg" "$WORK/build/macos-x86_64" \
    "$DIST" "ffmpeg-macos-x64.zip" "macos-x86_64 (deployment target $MIN_OS)"
ffmpeg_min_package "$UNIV/ffmpeg" "$UNIV" \
    "$DIST" "ffmpeg-macos-universal.zip" "macos-universal arm64+x86_64 (deployment target $MIN_OS)"

if [ "${BUILD_REFERENCE:-false}" = "true" ]; then
    ffmpeg_min_build_reference "$WORK/build/ref-macos-arm64" \
        --arch=arm64 \
        --cc=clang \
        --extra-cflags="-mmacosx-version-min=$MIN_OS" \
        --extra-ldflags="-mmacosx-version-min=$MIN_OS"
fi

ffmpeg_min_log "完成: $DIST"
