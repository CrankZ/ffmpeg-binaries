#!/usr/bin/env bash
# =============================================================================
# 公共函数：源码获取、configure 封装、全量参考构建、打包（LICENSE + BUILD.txt）
# 由 build-msys2.sh / build-macos.sh source，不单独执行。
# =============================================================================

FFMPEG_MIRROR="${FFMPEG_MIRROR:-https://ffmpeg.org/releases}"

ffmpeg_min_log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ffmpeg_min_warn() { printf '\033[1;33mWARNING: %s\033[0m\n' "$*" >&2; }
ffmpeg_min_die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

ffmpeg_min_jobs() {
    if [ -n "${JOBS:-}" ]; then
        echo "$JOBS"
    elif command -v nproc >/dev/null 2>&1; then
        nproc
    elif command -v sysctl >/dev/null 2>&1; then
        sysctl -n hw.ncpu
    else
        echo 4
    fi
}

ffmpeg_min_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

# -----------------------------------------------------------------------------
# 下载 + 解压源码，设置全局变量：
#   FFMPEG_TARBALL / FFMPEG_SOURCE_SHA256 / FFMPEG_SRC
# -----------------------------------------------------------------------------
ffmpeg_min_source() {
    local version="$1" work="$2"
    [ -n "$version" ] || ffmpeg_min_die "FFMPEG_VERSION 为空"

    local dl="$work/dl" srcroot="$work/src"
    mkdir -p "$dl" "$srcroot"

    FFMPEG_TARBALL="$dl/ffmpeg-$version.tar.xz"
    if [ ! -s "$FFMPEG_TARBALL" ]; then
        ffmpeg_min_log "下载 FFmpeg $version 源码"
        curl -fsSL --retry 5 --retry-delay 3 --connect-timeout 20 \
            -o "$FFMPEG_TARBALL.part" "$FFMPEG_MIRROR/ffmpeg-$version.tar.xz" ||
            ffmpeg_min_die "下载失败: $FFMPEG_MIRROR/ffmpeg-$version.tar.xz"
        mv "$FFMPEG_TARBALL.part" "$FFMPEG_TARBALL"
    fi

    FFMPEG_SOURCE_SHA256="$(ffmpeg_min_sha256 "$FFMPEG_TARBALL")"
    FFMPEG_SRC="$srcroot/ffmpeg-$version"
    if [ ! -d "$FFMPEG_SRC" ]; then
        ffmpeg_min_log "解压源码"
        tar -xf "$FFMPEG_TARBALL" -C "$srcroot"
    fi
    [ -x "$FFMPEG_SRC/configure" ] || ffmpeg_min_die "源码目录异常: $FFMPEG_SRC"

    ffmpeg_min_log "源码: $FFMPEG_SRC"
    ffmpeg_min_log "源码 sha256: $FFMPEG_SOURCE_SHA256"
    export FFMPEG_SRC FFMPEG_TARBALL FFMPEG_SOURCE_SHA256
}

# -----------------------------------------------------------------------------
# 用白名单 + 通用参数调用 configure（out-of-tree，绝不在源码树里就地构建）
#   $1 = 构建目录，$2 = 平台标签，其余 = 平台相关参数
# 结果：全局数组 CONFIGURE_ARGS，并写出 <builddir>/configure.cmd
# -----------------------------------------------------------------------------
ffmpeg_min_configure() {
    local builddir="$1" label="$2"
    shift 2

    ffmpeg_min_components_args
    ffmpeg_min_common_args

    CONFIGURE_ARGS=(
        "${FFMPEG_MIN_COMPONENT_ARGS[@]}"
        "${FFMPEG_MIN_COMMON_ARGS[@]}"
        "--extra-version=$FFMPEG_MIN_EXTRA_VERSION"
        "$@"
    )

    mkdir -p "$builddir"
    printf '# %s\n./configure %s\n' "$label" "${CONFIGURE_ARGS[*]}" > "$builddir/configure.cmd"
    CONFIGURE_CMD_TEXT="$(cat "$builddir/configure.cmd")"

    ffmpeg_min_log "configure ($label)"
    CONFIGURE_CMD_TEXT="$CONFIGURE_CMD_TEXT" sh -c 'printf "%s\n" "$CONFIGURE_CMD_TEXT"'

    ( cd "$builddir" && "$FFMPEG_SRC/configure" "${CONFIGURE_ARGS[@]}" ) ||
        ffmpeg_min_die "configure 失败 ($label)，日志见 $builddir/ffbuild/config.log"
}

ffmpeg_min_make() {
    local builddir="$1" jobs
    jobs="$(ffmpeg_min_jobs)"
    ffmpeg_min_log "make -j$jobs ($builddir)"
    make -C "$builddir" -j"$jobs" || ffmpeg_min_die "make 失败 ($builddir)"
}

# -----------------------------------------------------------------------------
# 全量参考构建：只用于"同版本官方全量构建"对照（PCM 一致性 + 解码耗时），
# 不启用白名单，保留 FFmpeg 默认优化等级，产物不随 Release 发布。
#   $1 = 构建目录，其余 = 平台相关参数
# -----------------------------------------------------------------------------
ffmpeg_min_build_reference() {
    local builddir="$1"
    shift

    local ref_args=(
        --disable-doc
        --disable-debug
        --disable-autodetect
        --disable-network
        --disable-programs
        --enable-ffmpeg
        --enable-static
        --disable-shared
        --disable-gpl
        --disable-nonfree
        --disable-version3
        "$@"
    )

    mkdir -p "$builddir"
    ffmpeg_min_log "参考构建（全量组件）$builddir"
    ( cd "$builddir" && "$FFMPEG_SRC/configure" "${ref_args[@]}" ) ||
        ffmpeg_min_die "参考构建 configure 失败"
    ffmpeg_min_make "$builddir"
}

# -----------------------------------------------------------------------------
# 打包：<zip> 内包含 可执行文件 + LICENSE(LGPL 全文) + BUILD.txt
#   $1 = 可执行文件，$2 = 构建目录（读 configure.cmd），$3 = 输出目录，
#   $4 = zip 文件名，$5 = 平台标签
# -----------------------------------------------------------------------------
ffmpeg_min_package() {
    local bin="$1" builddir="$2" outdir="$3" zipname="$4" platform="$5"
    local stage="$builddir/stage" name
    name="$(basename "$bin")"

    rm -rf "$stage"
    mkdir -p "$stage" "$outdir"
    cp "$bin" "$stage/$name"
    cp "$FFMPEG_SRC/COPYING.LGPLv2.1" "$stage/LICENSE"
    ffmpeg_min_write_build_txt "$stage/BUILD.txt" "$builddir" "$platform"

    rm -f "$outdir/$zipname"
    ( cd "$stage" && zip -q -9 -X "$outdir/$zipname" "$name" LICENSE BUILD.txt ) ||
        ffmpeg_min_die "打包失败: $outdir/$zipname"

    ffmpeg_min_log "产物: $outdir/$zipname ($(ffmpeg_min_size_mb "$outdir/$zipname") MB)"
}

ffmpeg_min_size_mb() {
    local bytes
    if [ "$(uname -s)" = "Darwin" ]; then
        bytes="$(stat -f %z "$1")"
    else
        bytes="$(stat -c %s "$1")"
    fi
    awk -v b="$bytes" 'BEGIN { printf "%.2f", b/1048576 }'
}

ffmpeg_min_write_build_txt() {
    local out="$1" builddir="$2" platform="$3"
    local cc_ver nasm_ver
    cc_ver="$("${CC:-cc}" --version 2>/dev/null | head -n 1)"
    nasm_ver="$(nasm -v 2>/dev/null | head -n 1)"

    {
        echo "FFmpeg minimal build — LGPL-2.1-or-later"
        echo "========================================"
        echo
        echo "ffmpeg version : ${FFMPEG_VERSION:?}"
        echo "source tarball : $FFMPEG_MIRROR/ffmpeg-$FFMPEG_VERSION.tar.xz"
        echo "source sha256  : $FFMPEG_SOURCE_SHA256"
        echo "platform       : $platform"
        echo "build date     : $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        echo "build host     : $(uname -s -m)"
        echo "compiler       : ${cc_ver:-unknown}"
        echo "assembler      : ${nasm_ver:-n/a (arm64/非 x86 使用 clang 内建汇编)}"
        echo
        echo "组件白名单唯一来源: scripts/ffmpeg-minimal/components.sh"
        echo
        echo "configure 命令:"
        if [ -f "$builddir/configure.cmd" ]; then
            sed 's/^/  /' "$builddir/configure.cmd"
        else
            echo "  ./configure ${CONFIGURE_ARGS[*]}"
        fi
        echo
        echo "说明: 静态链接，无第三方运行时依赖；--disable-gpl --disable-nonfree"
        echo "      --disable-version3，不含任何 GPL/非自由组件。"
    } > "$out"
}
