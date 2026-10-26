#!/usr/bin/env bash
# =============================================================================
# 离线单测：只测 lib/parse.sh 里的纯解析逻辑与 components.sh 的白名单，
# 不需要 ffmpeg、编译器、网络，通常几秒内跑完。
#
#   bash scripts/ffmpeg-minimal/tests/run-tests.sh [-v]
#
# 覆盖的重点是"只在完整构建之后才会暴露"的那些解析边界：
#   * data 块前夹着 LIST/INFO 块
#   * chunk 长度为奇数时的 1 字节补齐
#   * 流式写出 / RF64 的 0xFFFFFFFF 大小字段
#   * 文件被截断（声明大小 > 实际可用字节）
#   * fmt 块缺失、非 RIFF/WAVE
#   * Duration: N/A / 缺失 / 无法解析
#   * 组件名映射与列表解析（图例行、"mov,mp4,m4a" 逗号列表、protocols 列格式）
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/../lib/parse.sh"
# shellcheck source=/dev/null
. "$HERE/../components.sh"

VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

PASS=0
FAILS=0
ok()    { PASS=$((PASS + 1)); [ "$VERBOSE" -eq 1 ] && printf '  ok   %s\n' "$*"; return 0; }
bad()   { FAILS=$((FAILS + 1)); printf '  FAIL %s\n' "$*"; return 0; }
group() { printf '\n[%s]\n' "$*"; }

expect_eq() {  # $1=期望 $2=实际 $3=说明
    if [ "$1" = "$2" ]; then
        ok "$3"
    else
        bad "$3（期望 '$1'，实际 '$2'）"
    fi
}

expect_rc() {  # $1=期望 $2=实际 $3=说明
    if [ "$1" = "$2" ]; then
        ok "$3"
    else
        bad "$3（期望退出码 $1，实际 $2）"
    fi
}

expect_contains() {  # $1=子串 $2=文本 $3=说明
    case "$2" in
        *"$1"*) ok "$3" ;;
        *)      bad "$3（'$2' 不含 '$1'）" ;;
    esac
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# 构造 wav 的小工具：用 printf 的 \x 转义直接写二进制，
# 不依赖 python/perl/base64，Windows(MSYS2)、macOS、Linux 行为一致。
# ---------------------------------------------------------------------------
le16() { printf '\\x%02x\\x%02x' $(( $1 % 256 )) $(( ($1 / 256) % 256 )); }
le32() {
    printf '\\x%02x\\x%02x\\x%02x\\x%02x' \
        $(( $1 % 256 )) $(( ($1 / 256) % 256 )) \
        $(( ($1 / 65536) % 256 )) $(( ($1 / 16777216) % 256 ))
}

# $1=字节数 -> 对应数量的 0x42 转义串
filler() {
    local i=0 s=""
    while [ "$i" -lt "$1" ]; do
        s="${s}\\x42"
        i=$((i + 1))
    done
    printf '%s' "$s"
}

# 构造一个完整 wav（fmt 后可选插入额外 chunk）
# $1=文件 $2=PCM 字节数 $3=声道 $4=采样率
# $5=额外 chunk 的转义文本 $6=额外 chunk 字节数（含补齐） $7=data 大小字段（默认 = $2）
build_wav() {
    local f="$1" n="$2" ch="${3:-1}" rate="${4:-16000}"
    local extra="${5:-}" elen="${6:-0}" dsize="${7:-$2}"
    local riff=$(( 36 + elen + n ))
    {
        printf 'RIFF'; printf '%b' "$(le32 "$riff")"; printf 'WAVE'
        printf 'fmt '; printf '%b' "$(le32 16)"
        printf '%b' "$(le16 1)$(le16 "$ch")$(le32 "$rate")$(le32 $(( rate * ch * 2 )))$(le16 $(( ch * 2 )))$(le16 16)"
        if [ -n "$extra" ]; then
            printf '%b' "$extra"
        fi
        printf 'data'; printf '%b' "$(le32 "$dsize")"
        printf '%b' "$(filler "$n")"
    } > "$f"
}

# LIST 块（奇数长度自动补 1 字节）；$1=payload 字节数
list_chunk() {
    local n="$1" out
    out="LIST$(le32 "$n")$(filler "$n")"
    if [ $(( n % 2 )) -eq 1 ]; then
        out="${out}$(filler 1)"
    fi
    printf '%s' "$out"
}

# ===========================================================================
group "基础工具"
# ===========================================================================
build_wav "$TMP/canon.wav" 100
expect_eq "144" "$(ffmpeg_min_file_size "$TMP/canon.wav")" "文件大小 = 44 字节头 + 100 字节 PCM"

# ===========================================================================
group "pcm_data_offset：定位 data 块"
# ===========================================================================
expect_eq "44" "$(ffmpeg_min_pcm_data_offset "$TMP/canon.wav")" "标准 44 字节头 -> 偏移 44"

build_wav "$TMP/list_odd.wav" 100 1 16000 "$(list_chunk 5)" 14
expect_eq "58" "$(ffmpeg_min_pcm_data_offset "$TMP/list_odd.wav")" \
    "data 前的 LIST 块（奇数 5 字节 + 1 补齐）-> 偏移 58"

build_wav "$TMP/list_even.wav" 100 1 16000 "$(list_chunk 4)" 12
expect_eq "56" "$(ffmpeg_min_pcm_data_offset "$TMP/list_even.wav")" \
    "data 前的 LIST 块（偶数 4 字节，不应多跳）-> 偏移 56"

printf 'not a riff file at all' > "$TMP/nope.bin"
ffmpeg_min_pcm_data_offset "$TMP/nope.bin" >/dev/null
expect_rc 1 "$?" "非 RIFF 文件 -> 返回 1"

printf 'RIFF\x04\x00\x00\x00AVI ' > "$TMP/avi.bin"
ffmpeg_min_pcm_data_offset "$TMP/avi.bin" >/dev/null
expect_rc 1 "$?" "RIFF 但不是 WAVE -> 返回 1"

{
    printf 'RIFF'; printf '%b' "$(le32 28)"; printf 'WAVEfmt '; printf '%b' "$(le32 16)"
    printf '%b' "$(le16 1)$(le16 1)$(le32 16000)$(le32 32000)$(le16 2)$(le16 16)"
} > "$TMP/nodata.wav"
ffmpeg_min_pcm_data_offset "$TMP/nodata.wav" >/dev/null
expect_rc 1 "$?" "没有 data 块 -> 返回 1"

# ===========================================================================
group "pcm_bytes：PCM 数据长度"
# ===========================================================================
expect_eq "100" "$(ffmpeg_min_pcm_bytes "$TMP/canon.wav")" "按 data 大小字段取 100"
expect_eq "100" "$(ffmpeg_min_pcm_bytes "$TMP/list_odd.wav")" "LIST + 奇数补齐后仍为 100"

build_wav "$TMP/stream.wav" 100 1 16000 "" 0 4294967295
expect_eq "100" "$(ffmpeg_min_pcm_bytes "$TMP/stream.wav")" \
    "流式/RF64 的 0xFFFFFFFF -> 退回按文件实际长度 100"

build_wav "$TMP/zero.wav" 100 1 16000 "" 0 0
expect_eq "100" "$(ffmpeg_min_pcm_bytes "$TMP/zero.wav")" \
    "data 大小为 0（非 seekable 写出的常见形式）-> 退回按文件实际长度 100"

build_wav "$TMP/trunc.wav" 100 1 16000 "" 0 200
expect_eq "100" "$(ffmpeg_min_pcm_bytes "$TMP/trunc.wav")" \
    "声明 200 但实际只有 100 -> 取实际可用 100"

# ===========================================================================
group "wav_fmt_fields：声道 / 采样率"
# ===========================================================================
expect_eq "1 16000" "$(ffmpeg_min_wav_fmt_fields "$TMP/canon.wav")" "单声道 16kHz"
build_wav "$TMP/stereo.wav" 100 2 44100
expect_eq "2 44100" "$(ffmpeg_min_wav_fmt_fields "$TMP/stereo.wav")" "立体声 44.1kHz"
expect_eq "1 16000" "$(ffmpeg_min_wav_fmt_fields "$TMP/list_odd.wav")" \
    "fmt 在 LIST 之后仍能解析（走 chunk 遍历而不是硬编码偏移）"

out="$(ffmpeg_min_wav_fmt_fields "$TMP/nodata.wav")"; rc=$?
expect_rc 0 "$rc" "有 fmt、无 data 时 fmt 仍可解析"
expect_eq "1 16000" "$out" "缺 data 不影响 fmt 解析"

{
    printf 'RIFF'; printf '%b' "$(le32 28)"; printf 'WAVE'
    printf 'data'; printf '%b' "$(le32 16)"; printf '%b' "$(filler 16)"
} > "$TMP/nofmt.wav"
out="$(ffmpeg_min_wav_fmt_fields "$TMP/nofmt.wav")"; rc=$?
expect_rc 1 "$rc" "缺少 fmt 块 -> 返回 1"
expect_contains "fmt" "$out" "缺少 fmt 块时给出可读原因"

out="$(ffmpeg_min_wav_fmt_fields "$TMP/nope.bin")"; rc=$?
expect_rc 1 "$rc" "非 RIFF -> 返回 1"
expect_contains "RIFF" "$out" "非 RIFF 时给出可读原因"

# ===========================================================================
group "clock / duration：时长解析"
# ===========================================================================
expect_eq "5.000" "$(ffmpeg_min_clock_to_seconds 00:00:05.00)" "00:00:05.00 -> 5.000"
expect_eq "3723.450" "$(ffmpeg_min_clock_to_seconds 01:02:03.45)" "01:02:03.45 -> 3723.450"
ffmpeg_min_clock_to_seconds 5 >/dev/null
expect_rc 1 "$?" "缺少冒号 -> 返回 1"
ffmpeg_min_clock_to_seconds 00:00 >/dev/null
expect_rc 1 "$?" "缺少秒 -> 返回 1"
ffmpeg_min_clock_to_seconds 00:0a:05 >/dev/null
expect_rc 1 "$?" "分钟非数字 -> 返回 1"

text="$(printf '%s\n' \
    "Input #0, wav, from 'tone.wav':" \
    '  Duration: 00:00:05.00, bitrate: 256 kb/s' \
    '  Stream #0:0: Audio: pcm_s16le')"
out="$(ffmpeg_min_parse_duration "$text")"; rc=$?
expect_rc 0 "$rc" "正常 Duration 行 -> 返回 0"
expect_eq "5.000" "$out" "正常 Duration 行 -> 5.000 秒"

out="$(ffmpeg_min_parse_duration '  Duration: 01:02:03.45, start: 0.0')"; rc=$?
expect_rc 0 "$rc" "带 start 的 Duration 行 -> 返回 0"
expect_eq "3723.450" "$out" "带 start 的 Duration 行 -> 3723.450 秒"

fake_na="$(printf '%s\n' 'Input #0, amr, from x:' '  Duration: N/A, bitrate: 12 kb/s')"
out="$(ffmpeg_min_parse_duration "$fake_na")"; rc=$?
expect_rc 1 "$rc" "Duration: N/A -> 返回 1（容器无时长元数据）"
expect_eq "" "$out" "Duration: N/A 不输出数字"

out="$(ffmpeg_min_parse_duration 'Input #0, wav, from x:')"; rc=$?
expect_rc 2 "$rc" "没有 Duration 行 -> 返回 2"

out="$(ffmpeg_min_parse_duration '  Duration: abc, bitrate: 1 kb/s')"; rc=$?
expect_rc 2 "$rc" "Duration 值无法解析 -> 返回 2"

out="$(ffmpeg_min_parse_duration '')"; rc=$?
expect_rc 2 "$rc" "空 stderr -> 返回 2"

# ===========================================================================
group "is_number：耗时解析"
# ===========================================================================
ffmpeg_min_is_number 1.23;   expect_rc 0 "$?" "'1.23' 是数字"
ffmpeg_min_is_number 12;     expect_rc 0 "$?" "'12' 是数字"
ffmpeg_min_is_number 1,23;   expect_rc 1 "$?" "'1,23'（locale 逗号）不是数字"
ffmpeg_min_is_number .5;     expect_rc 1 "$?" "'.5' 不算（要求整数部分）"
ffmpeg_min_is_number "12.3 "; expect_rc 1 "$?" "带尾随空格不是数字"
ffmpeg_min_is_number "";     expect_rc 1 "$?" "空串不是数字"

# ===========================================================================
group "runtime_name：configure 名 -> 运行时名"
# ===========================================================================
expect_eq "mpeg"        "$(ffmpeg_min_runtime_name mpegps)"    "mpegps -> mpeg"
expect_eq "atrac3plus"  "$(ffmpeg_min_runtime_name atrac3p)"   "atrac3p -> atrac3plus"
expect_eq "atrac3plusal" "$(ffmpeg_min_runtime_name atrac3pal)" "atrac3pal -> atrac3plusal"
expect_eq "aac"         "$(ffmpeg_min_runtime_name aac)"       "无映射的组件名原样返回"

# ===========================================================================
group "enabled_names：从 ffmpeg 列表输出抽名字"
# ===========================================================================
sample="$(printf '%s\n' \
    'Decoders:' \
    ' V..... = Video' \
    ' A..... = Audio' \
    ' ------' \
    ' A....D aac                  Advanced Audio Coding' \
    ' A....D mp3float             MP3 (floating-point)' \
    ' D....D mov,mp4,m4a,3gp,3g2,mj2  QuickTime / MOV' \
    'Protocols:' \
    '  file' \
    '  pipe')"
expected="$(printf '%s\n' 3g2 3gp aac file m4a mj2 mov mp3float mp4 pipe | sort -u)"
expect_eq "$expected" "$(ffmpeg_min_enabled_names "$sample")" \
    "排除图例行与分隔线，展开逗号列表，识别 protocols 列格式"

expect_eq "" "$(ffmpeg_min_enabled_names "$(printf '%s\n' 'Decoders:' ' V..... = Video')")" \
    "只有图例行时返回空"

# ===========================================================================
group "components.sh：白名单自身合法性"
# ===========================================================================
check_component_list() {  # $1=变量名 $2=逗号列表
    local var="$1" names="$2" seen="" name
    if [ -z "$names" ]; then
        bad "$var 为空"
        return
    fi
    for name in ${names//,/ }; do
        case "$name" in
            [!a-z0-9_]*) bad "$var 含非法组件名: '$name'" ;;
        esac
        case " $seen " in
            *" $name "*) bad "$var 含重复组件名: $name" ;;
        esac
        seen="$seen $name"
    done
    ok "$var 组件名合法且无重复"
}

check_component_list FFMPEG_MIN_PROTOCOLS "$FFMPEG_MIN_PROTOCOLS"
check_component_list FFMPEG_MIN_DEMUXERS  "$FFMPEG_MIN_DEMUXERS"
check_component_list FFMPEG_MIN_MUXERS    "$FFMPEG_MIN_MUXERS"
check_component_list FFMPEG_MIN_ENCODERS  "$FFMPEG_MIN_ENCODERS"
check_component_list FFMPEG_MIN_DECODERS  "$FFMPEG_MIN_DECODERS"
check_component_list FFMPEG_MIN_PARSERS   "$FFMPEG_MIN_PARSERS"
check_component_list FFMPEG_MIN_FILTERS   "$FFMPEG_MIN_FILTERS"

# ===========================================================================
printf '\n\033[1m结果: %d 项通过, %d 项失败\033[0m\n' "$PASS" "$FAILS"
[ "$FAILS" -eq 0 ] || exit 1
