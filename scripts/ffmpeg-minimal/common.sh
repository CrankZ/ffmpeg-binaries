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
# ccache：仅当设置了 CCACHE_DIR 时启用（CI 里由 actions/cache 提供）
# 结果写入全局数组 FFMPEG_MIN_CC_ARGS；用 ${arr[@]+"${arr[@]}"} 展开以兼容
# macOS 自带的 bash 3.2（set -u 下展开空数组会报 unbound variable）。
#   $1 = 默认编译器（gcc / clang）
# -----------------------------------------------------------------------------
ffmpeg_min_cc_args() {
    local compiler="$1"
    FFMPEG_MIN_CC_ARGS=()
    if [ -n "${CCACHE_DIR:-}" ]; then
        command -v ccache >/dev/null 2>&1 ||
            ffmpeg_min_die "设置了 CCACHE_DIR 但找不到 ccache，请先安装 ccache"
        FFMPEG_MIN_CC_ARGS=(--cc="ccache $compiler")
        # CC 只记录真实编译器（不含 ccache 包装），供 BUILD.txt 取版本号
        export CC="$compiler"
    fi
}

# 可执行文件名（用于缓存的参考构建是否可直接复用）
ffmpeg_min_bin_name() {
    if [ "$(uname -s)" = "Darwin" ]; then
        echo "ffmpeg"
    else
        echo "ffmpeg.exe"
    fi
}

# 参考构建复用：CI 会缓存 ref-* 目录，命中且版本正确时跳过全量编译（最贵的一步）。
#   $1 = 构建目录，$2 = 期望版本；返回 0 表示可直接复用
# 需要 REUSE_REFERENCE=true 才启用，避免本地改配置后误用旧缓存。
ffmpeg_min_reference_reuse() {
    local builddir="$1" version="$2" bin
    [ "${REUSE_REFERENCE:-false}" = "true" ] || return 1
    bin="$builddir/$(ffmpeg_min_bin_name)"
    [ -x "$bin" ] || return 1
    "$bin" -version 2>/dev/null | grep -q "ffmpeg version $version" || {
        ffmpeg_min_warn "缓存的参考构建版本不符，重新构建: $bin"
        return 1
    }
    ffmpeg_min_log "复用缓存的参考构建: $bin"
}

# curl 公共参数：--retry-all-errors 才会重试 "Connection reset by peer" 这类网络错误
ffmpeg_min_fetch() {  # $1=url $2=输出文件
    curl -fsSL --http1.1 --retry 8 --retry-all-errors --retry-delay 5 \
        --connect-timeout 30 --max-time 600 -o "$2" "$1"
}

ffmpeg_min_download_official() {  # $1=version $2=输出文件；成功时记录实际 URL
    local version="$1" out="$2" url
    for url in \
        "$FFMPEG_MIRROR/ffmpeg-$version.tar.xz" \
        "https://www.ffmpeg.org/releases/ffmpeg-$version.tar.xz"
    do
        ffmpeg_min_log "下载源码: $url"
        rm -f "$out.part"
        if ffmpeg_min_fetch "$url" "$out.part"; then
            mv "$out.part" "$out"
            FFMPEG_SOURCE_URL="$url"
            return 0
        fi
        ffmpeg_min_warn "下载失败: $url"
    done
    return 1
}

ffmpeg_min_download_github() {  # $1=version $2=输出文件；GitHub tag 归档（与官方 tar.xz 内容等价）
    local version="$1" out="$2"
    local url="https://codeload.github.com/FFmpeg/FFmpeg/tar.gz/refs/tags/n$version"
    ffmpeg_min_log "下载源码（GitHub 归档回退）: $url"
    rm -f "$out.part"
    ffmpeg_min_fetch "$url" "$out.part" || return 1
    mv "$out.part" "$out"
    FFMPEG_SOURCE_URL="$url"
}

# -----------------------------------------------------------------------------
# 下载 + 解压源码，设置全局变量：
#   FFMPEG_TARBALL / FFMPEG_SOURCE_URL / FFMPEG_SOURCE_SHA256 / FFMPEG_SRC
# -----------------------------------------------------------------------------
ffmpeg_min_source() {
    local version="$1" work="$2"
    [ -n "$version" ] || ffmpeg_min_die "FFMPEG_VERSION 为空"
    # 版本号会参与 URL / 缓存 key / 解压路径，只允许常规版本文本
    case "$version" in
        *[!0-9A-Za-z._-]*|.*|*..*)
            ffmpeg_min_die "FFMPEG_VERSION 非法: ${version}（只允许字母数字 . _ -）" ;;
    esac

    local dl="$work/dl" srcroot="$work/src"
    local official="$dl/ffmpeg-$version.tar.xz"
    local github="$dl/ffmpeg-$version-github.tar.gz"
    local archive=""
    mkdir -p "$dl" "$srcroot"

    # 官方源在 GitHub runner 上偶发 "Connection reset by peer"；
    # --retry-all-errors 才会重试这类网络错误（普通 --retry 只重试超时/5xx）。
    if [ -s "$official" ]; then
        archive="$official"
        FFMPEG_SOURCE_URL="$FFMPEG_MIRROR/ffmpeg-$version.tar.xz"
    elif [ -s "$github" ]; then
        archive="$github"
        FFMPEG_SOURCE_URL="https://codeload.github.com/FFmpeg/FFmpeg/tar.gz/refs/tags/n$version"
    else
        if ffmpeg_min_download_official "$version" "$official"; then
            archive="$official"
        else
            # 官方 tar.xz 下载失败时回退到 GitHub tag 归档（内容等价的源码树）。
            # 设置了 FFMPEG_SHA256 则不能回退：归档字节与官方 tar.xz 不同，无法校验。
            [ -z "${FFMPEG_SHA256:-}" ] ||
                ffmpeg_min_die "官方源码下载失败，且设置了 FFMPEG_SHA256，不能用 GitHub 归档替代"
            ffmpeg_min_download_github "$version" "$github" ||
                ffmpeg_min_die "源码下载失败：官方源与 GitHub 归档均不可用"
            archive="$github"
        fi
    fi

    FFMPEG_TARBALL="$archive"
    FFMPEG_SOURCE_SHA256="$(ffmpeg_min_sha256 "$FFMPEG_TARBALL")"
    # 可选：强校验源码哈希，避免缓存/镜像被篡改导致产物不可复现
    if [ -n "${FFMPEG_SHA256:-}" ]; then
        local want actual
        want="$(printf '%s' "$FFMPEG_SHA256" | tr 'A-Z' 'a-z')"
        actual="$(printf '%s' "$FFMPEG_SOURCE_SHA256" | tr 'A-Z' 'a-z')"
        [ "$want" = "$actual" ] ||
            ffmpeg_min_die "源码 sha256 不匹配: 期望 $want, 实际 $actual"
        ffmpeg_min_log "源码 sha256 校验通过: $actual"
    fi
    FFMPEG_SRC="$srcroot/ffmpeg-$version"
    if [ ! -d "$FFMPEG_SRC" ]; then
        ffmpeg_min_log "解压源码: $(basename "$FFMPEG_TARBALL")"
        tar -xf "$FFMPEG_TARBALL" -C "$srcroot" ||
            ffmpeg_min_die "解压失败: $FFMPEG_TARBALL"
        # GitHub 归档解压出来是 FFmpeg-n<version>/，统一改名成 ffmpeg-<version>
        if [ ! -d "$FFMPEG_SRC" ] && [ -d "$srcroot/FFmpeg-n$version" ]; then
            mv "$srcroot/FFmpeg-n$version" "$FFMPEG_SRC"
        fi
    fi
    [ -x "$FFMPEG_SRC/configure" ] || ffmpeg_min_die "源码目录异常: $FFMPEG_SRC"

    ffmpeg_min_log "源码: $FFMPEG_SRC"
    ffmpeg_min_log "源码 sha256: $FFMPEG_SOURCE_SHA256"
    export FFMPEG_SRC FFMPEG_TARBALL FFMPEG_SOURCE_URL FFMPEG_SOURCE_SHA256
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
    # 机器可读的版本标记：Release 校验和运行时排查都直接读这一行
    {
        echo "ffmpeg ${FFMPEG_VERSION}-${FFMPEG_MIN_EXTRA_VERSION:-minimal}"
        echo "source sha256: $FFMPEG_SOURCE_SHA256"
    } > "$stage/VERSION"

    rm -f "$outdir/$zipname"
    ( cd "$stage" && zip -q -9 -X "$outdir/$zipname" "$name" LICENSE BUILD.txt VERSION ) ||
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
    # nasm 只在 x86 构建里必需；universal/release 这类只打包的 job 没有 nasm，
    # 这里必须容忍命令缺失（set -euo pipefail 下否则会直接退出 127）。
    cc_ver="$("${CC:-cc}" --version 2>/dev/null | head -n 1 || true)"
    nasm_ver="$(nasm -v 2>/dev/null | head -n 1 || true)"

    {
        echo "FFmpeg minimal build — LGPL-2.1-or-later"
        echo "========================================"
        echo
        echo "ffmpeg version : ${FFMPEG_VERSION:?}"
        echo "source tarball : ${FFMPEG_SOURCE_URL:-$FFMPEG_MIRROR/ffmpeg-$FFMPEG_VERSION.tar.xz}"
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
            echo "  ./configure ${CONFIGURE_ARGS[*]:-（见各架构 configure.cmd）}"
        fi
        echo
        echo "说明: 静态链接，无第三方运行时依赖；--disable-gpl --disable-nonfree"
        echo "      --disable-version3，不含任何 GPL/非自由组件。"
    } > "$out"
}
