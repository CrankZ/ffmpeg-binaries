#!/usr/bin/env bash
# =============================================================================
# 白名单组件名校验：确保 components.sh 里的每个名字在目标 FFmpeg 版本里真实存在。
# 组件名拼错 / 被上游改名（例如 FFmpeg 9.0 去掉了独立的 eac3、truehd parser）
# 时 configure 会直接失败或静默跳过，这里提前给出明确报错。
#
# 用法: check-components.sh <FFmpeg 源码目录>
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/components.sh"

SRC="${1:-}"
[ -n "$SRC" ] || { echo "用法: $0 <FFmpeg 源码目录>" >&2; exit 2; }
[ -x "$SRC/configure" ] || { echo "ERROR: 不是 FFmpeg 源码目录: $SRC" >&2; exit 2; }

AVAILABLE_CACHE=""
available_of() {  # $1 = decoders|encoders|demuxers|muxers|parsers|protocols|filters
    ( cd "$SRC" && ./configure --list-"$1" 2>/dev/null )
}

check_kind() {  # $1 = 种类，$2 = 逗号分隔的名字列表
    local kind="$1" names="$2" avail name missing="" count=0
    avail=" $(available_of "$kind" | tr '\n' ' ') "
    for name in ${names//,/ }; do
        count=$((count + 1))
        case "$avail" in
            *" $name "*) ;;
            *) missing="$missing $name" ;;
        esac
    done
    if [ -n "$missing" ]; then
        printf 'FAIL  %-10s 不存在的组件:%s\n' "$kind" "$missing" >&2
        return 1
    fi
    printf 'ok    %-10s %2d 个组件全部存在\n' "$kind" "$count"
}

echo "校验白名单组件名（源码: $SRC）"
rc=0
check_kind protocols "$FFMPEG_MIN_PROTOCOLS" || rc=1
check_kind demuxers  "$FFMPEG_MIN_DEMUXERS"  || rc=1
check_kind muxers    "$FFMPEG_MIN_MUXERS"    || rc=1
check_kind encoders  "$FFMPEG_MIN_ENCODERS"  || rc=1
check_kind decoders  "$FFMPEG_MIN_DECODERS"  || rc=1
check_kind parsers   "$FFMPEG_MIN_PARSERS"   || rc=1
check_kind filters   "$FFMPEG_MIN_FILTERS"   || rc=1

if [ "$rc" -ne 0 ]; then
    echo "ERROR: 白名单与当前 FFmpeg 版本不匹配，请修正 components.sh" >&2
    exit 1
fi
echo "全部组件名校验通过"
