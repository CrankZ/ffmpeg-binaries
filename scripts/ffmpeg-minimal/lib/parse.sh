#!/usr/bin/env bash
# =============================================================================
# 纯解析工具：不依赖 ffmpeg、不依赖构建产物，可以离线单测。
# 被 verify.sh / compare-pcm.sh source，用 tests/run-tests.sh 里构造的
# wav 头部字节逐项验证（含 LIST 块、奇数长度补齐、流式大小等边界情况）。
#
# 兼容 bash 3.2（macOS 自带），因此不使用关联数组 / ${var,,} / mapfile。
# 本文件不做任何 I/O 之外的动作，调用方负责输出成功/失败信息。
# =============================================================================

# 文件字节数
ffmpeg_min_file_size() {
    if [ "$(uname -s)" = "Darwin" ]; then
        stat -f %z "$1"
    else
        stat -c %s "$1"
    fi
}

# 文件开头 N 字节的十六进制串（默认 4096），去掉所有空白
ffmpeg_min_hex_prefix() {
    od -A n -t x1 -N "${2:-4096}" "$1" 2>/dev/null | tr -d ' \n\r'
}

# 8 个十六进制字符（小端 32 位）-> 十进制
ffmpeg_min_hex_le32() {
    local h="$1"
    [ "${#h}" -eq 8 ] || return 1
    printf '%d\n' $(( 0x${h:0:2} + 256 * 0x${h:2:2} \
        + 65536 * 0x${h:4:2} + 16777216 * 0x${h:6:2} ))
}

# 4 个十六进制字符（小端 16 位）-> 十进制
ffmpeg_min_hex_le16() {
    local h="$1"
    [ "${#h}" -eq 4 ] || return 1
    printf '%d\n' $(( 0x${h:0:2} + 256 * 0x${h:2:2} ))
}

# 遍历 RIFF 顶层 chunk，每行输出 "<id-hex> <chunk 起始偏移> <payload 大小>"。
# 不是 RIFF/WAVE、或连 12 字节头都不完整时返回 1。
# 只解析前 64KB：wav 头不会比这更大；遇到 RF64 的 0xFFFFFFFF 或异常大小时停止遍历。
ffmpeg_min_riff_chunks() {
    local f="$1" hex magic n pos id size
    hex="$(ffmpeg_min_hex_prefix "$f" 65536)"
    [ "${#hex}" -ge 24 ] || return 1
    magic="${hex:0:8}"
    case "$magic" in
        52494646|52463634) ;;       # "RIFF" / "RF64"
        *) return 1 ;;
    esac
    [ "${hex:16:8}" = "57415645" ] || return 1    # "WAVE"
    n=$(( ${#hex} / 2 ))
    pos=12
    while [ $(( pos + 8 )) -le "$n" ]; do
        id="${hex:$(( pos * 2 )):8}"
        size="$(ffmpeg_min_hex_le32 "${hex:$(( pos * 2 + 8 )):8}")" || return 1
        printf '%s %d %d\n' "$id" "$pos" "$size"
        # 0xFFFFFFFF（RF64 / 流式写出）及明显异常的大小不再继续走
        if [ "$size" -lt 0 ] || [ "$size" -gt 16777216 ]; then
            break
        fi
        pos=$(( pos + 8 + size + size % 2 ))    # RIFF 规定奇数长度补 1 字节
    done
    return 0
}

# PCM 数据起点（0-based 字节偏移）。成功输出偏移并返回 0；找不到 data 块返回 1。
ffmpeg_min_pcm_data_offset() {
    local id pos size
    while read -r id pos size; do
        [ "$id" = "64617461" ] || continue      # "data"
        printf '%s\n' $(( pos + 8 ))
        return 0
    done <<EOF
$(ffmpeg_min_riff_chunks "$1")
EOF
    return 1
}

# PCM 数据字节数（不含 wav 头）。
# data 大小字段为 0 / 0xFFFFFFFF（流式或非 seekable 写出）或大于文件实际长度时，
# 一律退回按文件长度计算，避免"两个空 PCM 互相比对也判一致"的盲区。
ffmpeg_min_pcm_bytes() {
    local f="$1" id pos size total avail
    total="$(ffmpeg_min_file_size "$f")" || return 1
    while read -r id pos size; do
        [ "$id" = "64617461" ] || continue
        avail=$(( total - pos - 8 ))
        if [ "$avail" -lt 0 ]; then
            return 1
        fi
        if [ "$size" -gt 0 ] && [ "$size" -le "$avail" ]; then
            printf '%s\n' "$size"
        else
            printf '%s\n' "$avail"
        fi
        return 0
    done <<EOF
$(ffmpeg_min_riff_chunks "$f")
EOF
    return 1
}

# wav 的声道数与采样率。成功输出 "<channels> <rate>" 并返回 0；
# 失败输出原因并返回 1（调用方直接展示原因）。
ffmpeg_min_wav_fmt_fields() {
    local f="$1" hex id pos size ch rate
    hex="$(ffmpeg_min_hex_prefix "$f" 4096)"
    if [ -z "$hex" ]; then
        echo "输出为空"
        return 1
    fi
    if [ "${#hex}" -lt 24 ]; then
        echo "头部不足 12 字节，无法解析"
        return 1
    fi
    case "${hex:0:8}" in
        52494646|52463634) ;;
        *) echo "不是 RIFF/WAVE"; return 1 ;;
    esac
    if [ "${hex:16:8}" != "57415645" ]; then
        echo "不是 RIFF/WAVE"
        return 1
    fi
    if [ "${#hex}" -lt 56 ]; then
        echo "头部不足 28 字节，无法解析 wav fmt"
        return 1
    fi
    while read -r id pos size; do
        [ "$id" = "666d7420" ] || continue       # "fmt "
        if [ "$size" -lt 16 ]; then
            echo "fmt 块过短（$size 字节）"
            return 1
        fi
        ch="$(ffmpeg_min_hex_le16 "${hex:$(( (pos + 10) * 2 )):4}")" || return 1
        rate="$(ffmpeg_min_hex_le32 "${hex:$(( (pos + 12) * 2 )):8}")" || return 1
        printf '%s %s\n' "$ch" "$rate"
        return 0
    done <<EOF
$(ffmpeg_min_riff_chunks "$f")
EOF
    echo "缺少 fmt 块"
    return 1
}

# "HH:MM:SS.ss" -> 秒（保留 3 位小数）；格式非法返回 1
ffmpeg_min_clock_to_seconds() {
    local clock="$1" h m s rest
    case "$clock" in
        *:*:*) ;;
        *) return 1 ;;
    esac
    h="${clock%%:*}"
    rest="${clock#*:}"
    m="${rest%%:*}"
    s="${rest#*:}"
    case "$h" in ""|*[!0-9]*) return 1 ;; esac
    case "$m" in ""|*[!0-9]*) return 1 ;; esac
    case "$s" in ""|*[!0-9.]*) return 1 ;; esac
    awk -v h="$h" -v m="$m" -v s="$s" 'BEGIN { printf "%.3f\n", h * 3600 + m * 60 + s }'
}

# 从 ffmpeg 的 stderr 文本里解析时长：
#   返回 0 并输出秒数
#   返回 1 表示 "Duration: N/A"（容器本身没有时长元数据）
#   返回 2 表示找不到 Duration 行，或值无法解析
ffmpeg_min_parse_duration() {
    local text="$1" line clock
    line="$(printf '%s\n' "$text" | grep -m1 'Duration:' || true)"
    [ -n "$line" ] || return 2
    clock="$(printf '%s' "$line" \
        | sed -n 's/.*Duration: *\([0-9][0-9]*:[0-9][0-9]*:[0-9][0-9.]*\).*/\1/p')"
    if [ -z "$clock" ]; then
        case "$line" in
            *"Duration: N/A"*|*"Duration: n/a"*) return 1 ;;
        esac
        return 2
    fi
    ffmpeg_min_clock_to_seconds "$clock" || return 2
}

# 是否是 "123" / "12.34" 这种正数（用于解析 time 内建输出的耗时）
ffmpeg_min_is_number() {
    printf '%s' "$1" | grep -qE '^[0-9]+([.][0-9]+)?$'
}

# 中位数（参数为任意个数字）；无参数返回 1。结果保留 4 位小数。
# 用于耗时对比：逐轮取 min/ref 比值的中位数，单个离群轮次不会让验收误判。
ffmpeg_min_median() {
    [ "$#" -gt 0 ] || return 1
    printf '%s\n' "$@" | sort -n | awk '
        { v[NR] = $1 }
        END {
            if (NR == 0) exit 1
            m = int((NR + 1) / 2)
            if (NR % 2) printf "%.4f", v[m]
            else printf "%.4f", (v[m] + v[m+1]) / 2
        }'
}

# 从 `ffmpeg -version` 输出解析版本 token（首行形如
# "ffmpeg version 9.0.2-minimal Copyright (c) ..."）。
# 成功输出 "9.0.2-minimal"；不是 ffmpeg 的版式或版本为空时返回 1。
ffmpeg_min_binary_version() {
    local first token
    first="${1%%$'\n'*}"
    case "$first" in
        "ffmpeg version "*) ;;
        *) return 1 ;;
    esac
    token="${first#ffmpeg version }"
    token="${token%% *}"
    token="${token%$'\r'}"
    [ -n "$token" ] || return 1
    printf '%s\n' "$token"
}

# configure 里的组件名 -> ffmpeg 运行时打印的名字
ffmpeg_min_runtime_name() {
    case "$1" in
        mpegps)    echo "mpeg" ;;
        atrac3p)   echo "atrac3plus" ;;
        atrac3pal) echo "atrac3plusal" ;;
        *)         echo "$1" ;;
    esac
}

# 从 -decoders/-encoders/-demuxers/-muxers/-filters/-protocols 的输出里抽出已启用的名字
#   * 第 2 列是名字，可能是 "mov,mp4,m4a" 这种逗号列表
#   * 图例行（" V..... = Video"）第 2 列是 "="，必须排除
ffmpeg_min_enabled_names() {
    printf '%s\n' "$1" | awk '
        $0 ~ /^[ ]*-+$/            { next }
        NF >= 2 && $1 ~ /^[A-Z.]{1,6}$/ && $2 != "=" {
            n = split($2, p, ",")
            for (i = 1; i <= n; i++) print p[i]
        }
        NF == 1 && $0 ~ /^[ ]{2}[a-z0-9]/ { print $1 }   # -protocols 的列格式
    ' | sort -u
}
