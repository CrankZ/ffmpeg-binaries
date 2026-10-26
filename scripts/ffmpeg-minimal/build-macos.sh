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
#   FFMPEG_VERSION           默认 9.0.2
#   FFMPEG_SHA256            可选，源码 tar.xz 的 sha256（设置后强校验）
#   MACOSX_DEPLOYMENT_TARGET 默认 13.0
#   WORK                     默认 ./work
#   BUILD_TARGET             all | arm64 | x86_64 | universal | reference（默认 all）
#   BUILD_REFERENCE          true 时额外构建全量参考版（arm64，不发布）
#   REUSE_REFERENCE          true 且已存在同版本参考产物时跳过全量编译（CI 缓存用）
#   CCACHE_DIR               设置后自动用 ccache 包装 clang（CI 缓存用）
#
# 拆分目标供 CI 并行：arm64 / x86_64 各跑一个 runner，universal 只做 lipo，
# reference 只做全量对照构建。
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

BUILD_TARGET="${BUILD_TARGET:-all}"
case "$BUILD_TARGET" in
    all|arm64|x86_64|universal|reference) ;;
    *) ffmpeg_min_die "BUILD_TARGET 只能是 all | arm64 | x86_64 | universal | reference（当前: $BUILD_TARGET）" ;;
esac

DO_ARM=0
DO_X64=0
DO_UNIV=0
DO_REF=0
case "$BUILD_TARGET" in
    all)       DO_ARM=1; DO_X64=1; DO_UNIV=1 ;;
    arm64)     DO_ARM=1 ;;
    x86_64)    DO_X64=1 ;;
    universal) DO_UNIV=1 ;;
    reference) DO_REF=1 ;;
esac
[ "${BUILD_REFERENCE:-false}" = "true" ] && DO_REF=1

# 源码始终需要：LICENSE / BUILD.txt / 组件校验都来自源码目录
ffmpeg_min_source "$FFMPEG_VERSION" "$WORK"

if [ "$DO_ARM" -eq 1 ] || [ "$DO_X64" -eq 1 ]; then
    bash "$HERE/check-components.sh" "$FFMPEG_SRC"
fi

if [ "$DO_X64" -eq 1 ]; then
    command -v nasm >/dev/null 2>&1 ||
        ffmpeg_min_die "找不到 nasm —— 构建 x86_64 切片必须有 nasm"
fi

# -----------------------------------------------------------------------------
build_arch() {
    local arch="$1"
    local builddir="$WORK/build/macos-$arch"
    local platform_label="macos-$arch (deployment target $MIN_OS)"
    local extra=()

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

    ffmpeg_min_cc_args clang
    ffmpeg_min_configure "$builddir" "$platform_label" "${extra[@]}" \
        ${FFMPEG_MIN_CC_ARGS[@]+"${FFMPEG_MIN_CC_ARGS[@]}"}

    if [ "$arch" = "x86_64" ]; then
        grep -q 'HAVE_X86ASM 1' "$builddir/config.h" ||
            ffmpeg_min_die "configure 未启用 x86 汇编（HAVE_X86ASM=0），性能不可接受"
    fi

    ffmpeg_min_make "$builddir"

    ffmpeg_min_log "strip + ad-hoc 签名 ($arch)"
    strip -x "$builddir/ffmpeg"
    codesign --force --sign - "$builddir/ffmpeg"
}

# -----------------------------------------------------------------------------
# universal = lipo(arm64, x86_64)；两个切片可由 CI 从各自的 artifact 下载，
# 因此这里只依赖 work/build/macos-{arm64,x86_64}/ffmpeg 已存在。
build_universal() {
    local arm="$WORK/build/macos-arm64/ffmpeg"
    local x86="$WORK/build/macos-x86_64/ffmpeg"
    local univ="$WORK/build/macos-universal"

    [ -x "$arm" ] || ffmpeg_min_die "缺少 arm64 切片: $arm"
    [ -x "$x86" ] || ffmpeg_min_die "缺少 x86_64 切片: $x86"

    mkdir -p "$univ"
    ffmpeg_min_log "lipo 合并 universal"
    rm -f "$univ/ffmpeg"
    lipo -create "$arm" "$x86" -output "$univ/ffmpeg"
    codesign --force --sign - "$univ/ffmpeg"

    if [ -f "$WORK/build/macos-arm64/configure.cmd" ] &&
       [ -f "$WORK/build/macos-x86_64/configure.cmd" ]; then
        {
            echo "# macos-universal = lipo(arm64, x86_64)"
            echo "#"
            sed 's/^/# --- arm64 ---/;1d' "$WORK/build/macos-arm64/configure.cmd"
            echo "#"
            sed 's/^/# --- x86_64 ---/;1d' "$WORK/build/macos-x86_64/configure.cmd"
        } > "$univ/configure.cmd"
    else
        printf '# macos-universal = lipo(arm64, x86_64)\n# 各架构 configure 命令见对应的 BUILD_TARGET 构建日志\n' \
            > "$univ/configure.cmd"
    fi

    ffmpeg_min_package "$univ/ffmpeg" "$univ" \
        "$DIST" "ffmpeg-macos-universal.zip" \
        "macos-universal arm64+x86_64 (deployment target $MIN_OS)"
}

# -----------------------------------------------------------------------------
if [ "$DO_ARM" -eq 1 ]; then
    build_arch arm64
    ffmpeg_min_package "$WORK/build/macos-arm64/ffmpeg" "$WORK/build/macos-arm64" \
        "$DIST" "ffmpeg-macos-arm64.zip" "macos-arm64 (deployment target $MIN_OS)"
fi

if [ "$DO_X64" -eq 1 ]; then
    build_arch x86_64
    ffmpeg_min_package "$WORK/build/macos-x86_64/ffmpeg" "$WORK/build/macos-x86_64" \
        "$DIST" "ffmpeg-macos-x64.zip" "macos-x86_64 (deployment target $MIN_OS)"
fi

if [ "$DO_UNIV" -eq 1 ]; then
    build_universal
fi

if [ "$DO_REF" -eq 1 ]; then
    REF_BUILD="$WORK/build/ref-macos-arm64"
    if ! ffmpeg_min_reference_reuse "$REF_BUILD" "$FFMPEG_VERSION"; then
        ffmpeg_min_cc_args clang
        ffmpeg_min_build_reference "$REF_BUILD" \
            --arch=arm64 \
            --cc=clang \
            --extra-cflags="-mmacosx-version-min=$MIN_OS" \
            --extra-ldflags="-mmacosx-version-min=$MIN_OS" \
            ${FFMPEG_MIN_CC_ARGS[@]+"${FFMPEG_MIN_CC_ARGS[@]}"}
    fi
fi

if [ "$DO_UNIV" -eq 1 ] || [ "$DO_ARM" -eq 1 ] || [ "$DO_X64" -eq 1 ]; then
    ffmpeg_min_log "完成: $DIST"
else
    ffmpeg_min_log "完成: $REF_BUILD/ffmpeg（参考构建）"
fi
