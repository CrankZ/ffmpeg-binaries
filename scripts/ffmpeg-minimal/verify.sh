#!/usr/bin/env bash
# =============================================================================
# 产物验收（冒烟 + 依赖检查 + 组件面检查 + 体积）
#
# 用法:
#   verify.sh --binary PATH --platform win-x64|macos-arm64|macos-x64|macos-universal
#             [--fixtures DIR] [--archs arm64,x86_64] [--quick]
#
# --quick 只跑前 3 个 fixture（用于 x86_64 / universal 这类冒烟成本高的产物）
# 任何一项不通过 -> 退出码非 0（CI 里即整个 job 失败）
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/components.sh"
# shellcheck source=/dev/null
. "$HERE/lib/parse.sh"

BIN=""
PLATFORM=""
FIXTURES="$HERE/../../fixtures"
EXPECT_ARCHS=""
QUICK=0

while [ $# -gt 0 ]; do
    case "$1" in
        --binary)   BIN="$2"; shift 2 ;;
        --platform) PLATFORM="$2"; shift 2 ;;
        --fixtures) FIXTURES="$2"; shift 2 ;;
        --archs)    EXPECT_ARCHS="$2"; shift 2 ;;
        --quick)    QUICK=1; shift ;;
        -h|--help)  sed -n '2,15p' "$0"; exit 0 ;;
        *) echo "未知参数: $1" >&2; exit 2 ;;
    esac
done

[ -n "$BIN" ] && [ -f "$BIN" ] || { echo "ERROR: --binary 必须是存在的文件" >&2; exit 2; }
[ -n "$PLATFORM" ] || { echo "ERROR: 需要 --platform" >&2; exit 2; }
[ -d "$FIXTURES" ] || { echo "ERROR: fixtures 目录不存在: $FIXTURES" >&2; exit 2; }

PASS=0
FAILS=0
ok()   { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad()  { FAILS=$((FAILS + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
info() { printf '  ---- %s\n' "$*"; }
title() { printf '\n\033[1m[%s] %s\033[0m\n' "$1" "$2"; }

file_size() {
    if [ "$(uname -s)" = "Darwin" ]; then stat -f %z "$1"; else stat -c %s "$1"; fi
}
sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}';
    else shasum -a 256 "$1" | awk '{print $1}'; fi
}
size_mb() { awk -v b="$(file_size "$1")" 'BEGIN { printf "%.2f", b/1048576 }'; }
# 版本号比较: ver_ge 13.0 13.0 -> 0
ver_ge() { awk -v a="$1" -v b="$2" 'BEGIN{split(a,x,".");split(b,y,".");for(i=1;i<=3;i++){if((x[i]+0)>(y[i]+0))exit 0;if((x[i]+0)<(y[i]+0))exit 1}exit 0}'; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

BIN_DIR="$(cd "$(dirname "$BIN")" && pwd)"
BIN_ABS="$BIN_DIR/$(basename "$BIN")"

printf '\033[1m验收: %s\033[0m\n' "$BIN_ABS"
info "平台         : $PLATFORM"
info "文件大小     : $(size_mb "$BIN_ABS") MB ($(file_size "$BIN_ABS") bytes)"
info "sha256       : $(sha256 "$BIN_ABS")"

# =============================================================================
title 1/6 "ffmpeg -version 与构建配置"
# =============================================================================
if VERSION_OUT="$("$BIN_ABS" -version 2>&1)"; then
    ok "ffmpeg -version 正常退出"
else
    bad "ffmpeg -version 退出码非 0"
fi
info "$(printf '%s' "$VERSION_OUT" | head -n 1)"
CONFIG_LINE="$(printf '%s' "$VERSION_OUT" | grep -m1 '^configuration:' || true)"

# 版本号一致性：首行必须是 "ffmpeg version <ver>"，且带 -minimal 后缀；
# CI 里还会与输入 FFMPEG_VERSION 比对，防止缓存/源码串台后发布错版本。
if VER_TOKEN="$(ffmpeg_min_binary_version "$VERSION_OUT")"; then
    case "$VER_TOKEN" in
        *-minimal) ok "版本号带 -minimal 后缀（$VER_TOKEN）" ;;
        *) bad "版本号缺少 -minimal 后缀: $VER_TOKEN" ;;
    esac
    VER_CORE="${VER_TOKEN%-minimal}"
    if [ -n "${FFMPEG_VERSION:-}" ]; then
        if [ "$VER_CORE" = "$FFMPEG_VERSION" ]; then
            ok "版本号与预期一致（$FFMPEG_VERSION）"
        else
            bad "版本号不符: 期望 $FFMPEG_VERSION，实际 $VER_CORE"
        fi
    else
        info "未设置 FFMPEG_VERSION，跳过版本号比对"
    fi
else
    bad "无法从 -version 首行解析版本号"
fi

if printf '%s' "$CONFIG_LINE" | grep -q -- '--disable-everything'; then
    ok "配置含 --disable-everything（组件已裁剪）"
else
    bad "配置不含 --disable-everything，说明不是最小化构建"
fi

for flag in --disable-gpl --disable-nonfree --disable-version3; do
    if printf '%s' "$CONFIG_LINE" | grep -q -- "$flag"; then
        ok "许可证选项 $flag"
    else
        bad "缺少许可证选项 $flag"
    fi
done

for flag in --disable-swscale --disable-avdevice; do
    if printf '%s' "$CONFIG_LINE" | grep -q -- "$flag"; then
        ok "已关闭 $flag"
    else
        bad "未关闭 $flag（体积/依赖不应包含它）"
    fi
done

if printf '%s' "$CONFIG_LINE" | grep -q -- '--enable-small'; then
    bad "配置含 --enable-small（-Os，性能不可接受）"
else
    ok "未使用 --enable-small"
fi
if printf '%s' "$CONFIG_LINE" | grep -q -- '--disable-asm'; then
    bad "配置含 --disable-asm（SIMD 汇编被关闭，性能不可接受）"
else
    ok "未使用 --disable-asm"
fi

# =============================================================================
title 2/6 "静态依赖检查"
# =============================================================================
case "$PLATFORM" in
win-*)
    DEPS="$(objdump -p "$BIN_ABS" 2>/dev/null | awk '/DLL Name/ {print $3}' | sort -u)"
    if [ -z "$DEPS" ]; then
        bad "objdump 未解析出任何 DLL 依赖（objdump 可用？）"
    else
        info "导入 DLL: $(printf '%s' "$DEPS" | tr '\n' ' ')"
        ALLOWED="KERNEL32.dll msvcrt.dll USER32.dll ADVAPI32.dll SHELL32.dll bcrypt.dll ntdll.dll ole32.dll"
        UNEXPECTED=""
        for d in $DEPS; do
            lower="$(printf '%s' "$d" | tr 'A-Z' 'a-z')"
            found=0
            for a in $ALLOWED; do
                [ "$lower" = "$(printf '%s' "$a" | tr 'A-Z' 'a-z')" ] && found=1
            done
            # api-ms-win-* / ext-ms-* 是 Windows 自带的 API Set，不是第三方运行时
            case "$lower" in api-ms-win-*|ext-ms-*) found=1 ;; esac
            [ "$found" -eq 0 ] && UNEXPECTED="$UNEXPECTED $d"
        done
        if [ -z "$UNEXPECTED" ]; then
            ok "只依赖系统 DLL（无第三方运行时依赖）"
        else
            bad "存在非系统 DLL 依赖:$UNEXPECTED"
        fi
    fi
    ;;
macos-*)
    # fat 二进制（universal）的 otool -L 会多出 "path (architecture arm64):" 这类表头行，
    # 只保留真正的库路径（以 / 或 @ 开头、且不是以 : 结尾的表头）
    LIBS="$(otool -L "$BIN_ABS" | awk '!/:$/ && ($1 ~ /^\// || $1 ~ /^@/) {print $1}' | sort -u)"
    info "链接库: $(printf '%s' "$LIBS" | tr '\n' ' ')"
    UNEXPECTED=""
    for l in $LIBS; do
        case "$l" in
            /usr/lib/*|/System/Library/*|@rpath/libSystem*|/System/iOSSupport/*) ;;
            *) UNEXPECTED="$UNEXPECTED $l" ;;
        esac
    done
    if [ -z "$UNEXPECTED" ]; then
        ok "只依赖 /usr/lib 等系统库（无第三方运行时依赖）"
    else
        bad "存在非系统库依赖:$UNEXPECTED"
    fi
    ;;
esac

# =============================================================================
title 3/6 "架构 / 最低系统版本"
# =============================================================================
case "$PLATFORM" in
macos-*)
    ARCHS_LIPO="$(lipo -archs "$BIN_ABS" 2>/dev/null)"
    info "lipo -archs: $ARCHS_LIPO"
    if [ -n "$EXPECT_ARCHS" ]; then
        MISSING=""
        for a in ${EXPECT_ARCHS//,/ }; do
            case " $ARCHS_LIPO " in *" $a "*) ;; *) MISSING="$MISSING $a" ;; esac
        done
        if [ -z "$MISSING" ]; then
            ok "包含期望架构: $EXPECT_ARCHS"
        else
            bad "缺少架构:$MISSING"
        fi
    fi

    MINOS_LIST="$(otool -l "$BIN_ABS" | awk '/LC_BUILD_VERSION/{f=1} f && /minos/{print $2; f=0} /LC_VERSION_MIN_MACOSX/{g=1} g && /version/{print $2; g=0}')"
    info "minos: $(printf '%s' "$MINOS_LIST" | tr '\n' ' ')"
    MINOS_BAD=""
    for v in $MINOS_LIST; do
        ver_ge "$v" "13.0" || MINOS_BAD="$MINOS_BAD $v"
    done
    if [ -n "$MINOS_LIST" ] && [ -z "$MINOS_BAD" ]; then
        ok "最低系统版本 >= 13.0"
    elif [ -z "$MINOS_LIST" ]; then
        bad "未能解析 minos（LC_BUILD_VERSION 缺失？）"
    else
        bad "最低系统版本低于 13.0:$MINOS_BAD"
    fi

    if codesign -dv "$BIN_ABS" >/dev/null 2>&1; then
        ok "已签名（ad-hoc 或开发者签名），arm64 可执行"
    else
        bad "未签名：Apple Silicon 上会被内核直接杀掉"
    fi

    FILE_OUT="$(file -b "$BIN_ABS")"
    info "file: $FILE_OUT"
    ;;
win-*)
    info "架构假设 x86_64（MSYS2 MINGW64 产物）"
    FILE_OUT="$(file -b "$BIN_ABS")"
    info "file: $FILE_OUT"
    case "$FILE_OUT" in
        *PE32+*x86-64*|*PE32+*x86_64*) ok "PE32+ x86-64 可执行文件" ;;
        *) bad "不是预期的 x86-64 PE 文件: $FILE_OUT" ;;
    esac
    ;;
esac

# =============================================================================
title 4/6 "组件面：白名单全覆盖 + 无视频编解码器"
# =============================================================================
DECODERS="$("$BIN_ABS" -hide_banner -decoders 2>/dev/null)"
ENCODERS="$("$BIN_ABS" -hide_banner -encoders 2>/dev/null)"
DEMUXERS="$("$BIN_ABS" -hide_banner -demuxers 2>/dev/null)"
MUXERS="$("$BIN_ABS" -hide_banner -muxers 2>/dev/null)"
FILTERS="$("$BIN_ABS" -hide_banner -filters 2>/dev/null)"
PROTOCOLS="$("$BIN_ABS" -hide_banner -protocols 2>/dev/null)"

# 列表解析 / 组件名映射都在 lib/parse.sh（离线单测覆盖），这里只做断言。
#   * 第 2 列是名字，可能是 "mov,mp4,m4a" 这种逗号列表
#   * 图例行（" V..... = Video"）第 2 列是 "="，必须排除

check_names() {  # $1=列表文本 $2=逗号分隔白名单 $3=说明
    local text="$1" names="$2" what="$3" n real missing="" avail
    avail="$(ffmpeg_min_enabled_names "$text")"
    for n in ${names//,/ }; do
        real="$(ffmpeg_min_runtime_name "$n")"
        printf '%s\n' "$avail" | grep -qxF "$real" || missing="$missing $n"
    done
    if [ -z "$missing" ]; then
        ok "$what 全部可用"
    else
        bad "$what 缺失:$missing"
    fi
}

check_names "$PROTOCOLS" "$FFMPEG_MIN_PROTOCOLS" "协议"
check_names "$DEMUXERS"  "$FFMPEG_MIN_DEMUXERS"  "demuxer"
check_names "$MUXERS"    "$FFMPEG_MIN_MUXERS"    "muxer"
check_names "$ENCODERS"  "$FFMPEG_MIN_ENCODERS"  "encoder"
check_names "$DECODERS"  "$FFMPEG_MIN_DECODERS"  "decoder"
check_names "$FILTERS"   "$FFMPEG_MIN_FILTERS"   "filter"

VIDEO_DEC="$(printf '%s\n' "$DECODERS" | awk 'NF>=2 && $1 ~ /^V/ && $2 != "=" {print $2}' | tr '\n' ' ')"
if [ -z "$VIDEO_DEC" ]; then
    ok "无任何视频 decoder（与白名单一致）"
else
    bad "存在视频 decoder: $VIDEO_DEC"
fi
VIDEO_ENC="$(printf '%s\n' "$ENCODERS" | awk 'NF>=2 && $1 ~ /^V/ && $2 != "=" {print $2}' | tr '\n' ' ')"
if [ -z "$VIDEO_ENC" ]; then
    ok "无任何视频 encoder"
else
    bad "存在视频 encoder: $VIDEO_ENC"
fi
AUDIO_ENC="$(printf '%s\n' "$ENCODERS" | awk 'NF>=2 && $1 ~ /^A/ && $2 != "=" {print $2}' | tr '\n' ' ')"
if [ "$(printf '%s' "$AUDIO_ENC" | tr -d ' ')" = "pcm_s16le" ]; then
    ok "音频 encoder 仅有 pcm_s16le"
else
    bad "音频 encoder 不是仅 pcm_s16le: $AUDIO_ENC"
fi
if printf '%s\n' "$PROTOCOLS" | awk '$1 ~ /^(http|https|tcp|udp|rtmp|rtp|srt|hls|ftp|ssh|tls|quic)$/ {found=1} END {exit !found}'; then
    bad "存在网络协议（应当 --disable-network）"
else
    ok "无网络协议"
fi

# 校验 wav 头里的 mono / 16000。fmt 解析（含 fmt 不在固定偏移、LIST 块等）在
# lib/parse.sh，由 tests/run-tests.sh 离线覆盖；这里只负责把结果转成 PASS/FAIL。
wav_fmt_check() {  # $1=wav 文件 $2=说明；不通过时直接计入 FAILS
    local f="$1" label="$2" fields ch rate
    if ! fields="$(ffmpeg_min_wav_fmt_fields "$f")"; then
        bad "$label $fields"
        return 1
    fi
    ch="${fields%% *}"
    rate="${fields##* }"
    if [ "$ch" = "1" ] && [ "$rate" = "16000" ]; then
        return 0
    fi
    bad "$label -ac 1 -ar 16000 未生效（wav 头: ${ch}ch / ${rate}Hz）"
    return 1
}

# =============================================================================
title 5/6 "实际调用逐个 fixture 冒烟（管道 / 文件 / 时长 / 输入管道 / broken pipe / 截断）"
# =============================================================================
TOTAL_FIX=0
FIX_FAIL=0

for f in "$FIXTURES"/*; do
    [ -f "$f" ] || continue
    name="$(basename "$f")"
    case "$name" in
        tone*) ;;
        *) continue ;;
    esac
    if [ "$QUICK" -eq 1 ] && [ "$TOTAL_FIX" -ge 3 ]; then
        break
    fi
    TOTAL_FIX=$((TOTAL_FIX + 1))
    pcm1=""   # 每个 fixture 重新计算，避免提取失败时沿用上一个的值

    # ---- 1) 管道提取（主力路径）----
    out1="$TMP/$name.pipe.wav"
    if "$BIN_ABS" -hide_banner -loglevel error -i "$f" -vn -ac 1 -ar 16000 \
            -f wav -acodec pcm_s16le - > "$out1" 2>"$TMP/err1.txt"; then
        sz="$(file_size "$out1")"
        pcm1="$(ffmpeg_min_pcm_bytes "$out1" 2>/dev/null)" || pcm1=""
        # 5s 单声道 16k PCM ≈ 160000 字节；允许 ±35%
        if [ "$sz" -gt 32000 ] && [ "$sz" -lt 216000 ]; then
            ok "$name 管道提取 -> $sz bytes（PCM ${pcm1:-?} bytes）"
            wav_fmt_check "$out1" "$name 管道提取" || true
            if [ -z "$pcm1" ]; then
                bad "$name 管道提取的 wav 头无法解析 PCM 长度"
                FIX_FAIL=$((FIX_FAIL + 1))
            fi
        else
            bad "$name 管道提取输出大小异常: $sz bytes"
            FIX_FAIL=$((FIX_FAIL + 1))
        fi
    else
        bad "$name 管道提取失败: $(head -n 2 "$TMP/err1.txt" | tr '\n' ' ')"
        FIX_FAIL=$((FIX_FAIL + 1))
    fi

    # ---- 2) 预转 WAV 文件（带主程序额外参数）----
    out2="$TMP/$name.file.wav"
    if "$BIN_ABS" -hide_banner -loglevel error -y -err_detect ignore_err \
            -fflags +discardcorrupt+genpts -i "$f" -vn -ac 1 -ar 16000 \
            -f wav -acodec pcm_s16le "$out2" 2>"$TMP/err2.txt"; then
        sz2="$(file_size "$out2")"
        if [ "$sz2" -gt 32000 ]; then
            ok "$name 预转 WAV 文件 -> $sz2 bytes"
            wav_fmt_check "$out2" "$name 预转 WAV 文件" || true
        else
            bad "$name 预转 WAV 文件输出太小: $sz2 bytes"
            FIX_FAIL=$((FIX_FAIL + 1))
        fi
    else
        bad "$name 预转 WAV 文件失败: $(head -n 2 "$TMP/err2.txt" | tr '\n' ' ')"
        FIX_FAIL=$((FIX_FAIL + 1))
    fi

    # ---- 3) 时长探测（stderr 解析 Duration:）+ 与解码 PCM 长度交叉校验 ----
    if "$BIN_ABS" -hide_banner -i "$f" -vn -f null - >"$TMP/null.out" 2>"$TMP/err3.txt"; then
        dout="$(ffmpeg_min_parse_duration "$(cat "$TMP/err3.txt")")"
        drc=$?
        case "$drc" in
            0)
                if [ -z "$pcm1" ]; then
                    # 提取阶段的 PCM 长度不可用，只保留"能解析出时长"这一条
                    ok "$name 时长探测 -> ${dout}s（无 PCM 长度可交叉校验）"
                else
                    # 单声道 16-bit 16kHz：每秒 32000 字节
                    decoded="$(awk -v b="$pcm1" 'BEGIN { printf "%.2f", b / 32000 }')"
                    # 容器声明的时长应当与真正解码出的 PCM 长度吻合；容差 10% 且不小于 1s，
                    # 覆盖个别容器时间戳精度问题，但能抓住"解析到的是别的数字"这类 bug。
                    if awk -v a="$dout" -v b="$decoded" 'BEGIN {
                            d = a - b; if (d < 0) d = -d
                            lim = b * 0.10; if (lim < 1.0) lim = 1.0
                            exit !(d <= lim)
                        }'; then
                        ok "$name 时长探测 -> ${dout}s（解码 PCM ${decoded}s，一致）"
                    else
                        bad "$name 时长探测 ${dout}s 与解码 PCM ${decoded}s 不符"
                        FIX_FAIL=$((FIX_FAIL + 1))
                    fi
                fi
                ;;
            1)
                # AMR 这类容器本身没有时长元数据，ffmpeg 输出 Duration: N/A 属预期
                ok "$name 时长探测 -> N/A（容器无时长元数据，符合预期）"
                ;;
            *)
                bad "$name 时长探测没有可解析的 Duration: 行"
                FIX_FAIL=$((FIX_FAIL + 1))
                ;;
        esac
    else
        bad "$name 时长探测失败: $(head -n 2 "$TMP/err3.txt" | tr '\n' ' ')"
        FIX_FAIL=$((FIX_FAIL + 1))
    fi
done

# ---- 4) -t 截断 + 采样参数真实生效 ----
FIRST="$(ls "$FIXTURES"/*.mp4 2>/dev/null | head -n 1)"
[ -n "$FIRST" ] || FIRST="$(ls "$FIXTURES"/*.wav 2>/dev/null | head -n 1)"
if [ -n "$FIRST" ]; then
    t_out="$TMP/t.wav"
    if "$BIN_ABS" -hide_banner -loglevel error -i "$FIRST" -t 2 -vn -ac 1 -ar 16000 \
            -f wav -acodec pcm_s16le - > "$t_out" 2>/dev/null; then
        t_sz="$(file_size "$t_out")"
        if [ "$t_sz" -gt 40000 ] && [ "$t_sz" -lt 90000 ]; then
            ok "-t 2 截断生效（$(basename "$FIRST") -> $t_sz bytes，约 2s）"
            wav_fmt_check "$t_out" "-t 2 输出" || true
        else
            bad "-t 2 截断异常: $t_sz bytes"
        fi
    else
        bad "-t 2 截断调用失败"
    fi
fi
info "共 $TOTAL_FIX 个 fixture，失败 $FIX_FAIL 项"
FAILS=$((FAILS + FIX_FAIL))

# ---- 5) 输入管道 pipe:0（主程序可能把文件内容直接喂给 ffmpeg）----
# 用 mp3 而不是 mp4：moov 在文件尾部时无法从管道解封装，那是容器特性不是构建问题。
PIPE_SRC="$(ls "$FIXTURES"/tone.mp3 2>/dev/null | head -n 1)"
[ -n "$PIPE_SRC" ] || PIPE_SRC="$(ls "$FIXTURES"/*.wav 2>/dev/null | head -n 1)"
if [ -n "$PIPE_SRC" ]; then
    if cat "$PIPE_SRC" | "$BIN_ABS" -hide_banner -loglevel error -i pipe:0 \
            -vn -ac 1 -ar 16000 -f wav -acodec pcm_s16le - \
            > "$TMP/pipe_in.wav" 2>"$TMP/pipe_in.err"; then
        psz="$(file_size "$TMP/pipe_in.wav")"
        if [ "$psz" -gt 32000 ]; then
            ok "输入管道 pipe:0 可用（$(basename "$PIPE_SRC") -> $psz bytes）"
            wav_fmt_check "$TMP/pipe_in.wav" "输入管道" || true
        else
            bad "输入管道输出太小: $psz bytes"
        fi
    else
        bad "输入管道 pipe:0 解码失败: $(head -n 2 "$TMP/pipe_in.err" | tr '\n' ' ')"
    fi
fi

# ---- 6) 输出管道被消费者提前关闭（broken pipe）：必须退出，不能挂死 ----
# 真实集成里上游（播放器/上传器）会中途停止读 stdout，ffmpeg 必须报错退出而不是卡住。
if [ -n "$PIPE_SRC" ] && command -v mkfifo >/dev/null 2>&1; then
    FIFO="$TMP/out.fifo"
    if mkfifo "$FIFO" 2>/dev/null; then
        head -c 1024 < "$FIFO" >/dev/null &
        reader=$!
        "$BIN_ABS" -hide_banner -loglevel error -i "$PIPE_SRC" -vn -ac 1 -ar 16000 \
            -f wav -acodec pcm_s16le - > "$FIFO" 2>"$TMP/broken.err" &
        writer=$!
        ( sleep 30; kill -9 "$writer" 2>/dev/null; : > "$TMP/broken.timeout" ) &
        watchdog=$!
        wait "$writer"; brc=$?
        kill "$watchdog" 2>/dev/null
        wait "$watchdog" 2>/dev/null
        if [ -e "$TMP/broken.timeout" ]; then
            kill -9 "$reader" 2>/dev/null
            bad "输出管道提前关闭后 ffmpeg 30s 内没有退出（疑似挂死）"
        elif [ "$brc" -ne 0 ]; then
            ok "输出管道提前关闭时 ffmpeg 以非 0 退出（未挂死）"
        else
            bad "输出管道提前关闭但 ffmpeg 仍以 0 退出"
        fi
        wait "$reader" 2>/dev/null
        rm -f "$FIFO"
    else
        info "当前环境无法创建 FIFO，跳过 broken pipe 测试"
    fi
else
    info "缺少可用输入样本或 mkfifo，跳过 broken pipe 测试"
fi

# ---- 7) -t 截断（纯音频路径，避免只覆盖视频容器）----
AUDIO_SRC="$(ls "$FIXTURES"/tone.mp3 2>/dev/null | head -n 1)"
[ -n "$AUDIO_SRC" ] || AUDIO_SRC="$(ls "$FIXTURES"/tone.flac 2>/dev/null | head -n 1)"
if [ -n "$AUDIO_SRC" ]; then
    a_out="$TMP/t_audio.wav"
    if "$BIN_ABS" -hide_banner -loglevel error -i "$AUDIO_SRC" -t 2 -vn -ac 1 -ar 16000 \
            -f wav -acodec pcm_s16le - > "$a_out" 2>/dev/null; then
        a_sz="$(file_size "$a_out")"
        # 2s 单声道 16-bit 16kHz = 64000 字节 PCM + 44 字节头
        if [ "$a_sz" -gt 50000 ] && [ "$a_sz" -lt 80000 ]; then
            ok "-t 2 对纯音频生效（$(basename "$AUDIO_SRC") -> $a_sz bytes）"
            wav_fmt_check "$a_out" "-t 2 纯音频输出" || true
        else
            bad "-t 2 纯音频截断异常: $a_sz bytes"
        fi
    else
        bad "-t 2 纯音频调用失败"
    fi
fi

# ---- 8) 损坏 / 非媒体输入：必须非 0 退出，不能挂死 ----
printf 'this is definitely not a media file\n' > "$TMP/garbage.mp4"
if "$BIN_ABS" -hide_banner -loglevel error -i "$TMP/garbage.mp4" -vn -f null - \
        >"$TMP/garbage.out" 2>"$TMP/garbage.err"; then
    bad "损坏输入被当作成功（应非 0 退出）"
else
    ok "损坏输入以非 0 退出"
fi

# ---- 9) 路径含空格（用户选择的文件路径经常带空格）----
SPACE_SRC="$(ls "$FIXTURES"/tone.mp3 2>/dev/null | head -n 1)"
[ -n "$SPACE_SRC" ] || SPACE_SRC="$(ls "$FIXTURES"/*.wav 2>/dev/null | head -n 1)"
if [ -n "$SPACE_SRC" ]; then
    ext="${SPACE_SRC##*.}"
    SPACE_IN="$TMP/tone with spaces.$ext"
    cp "$SPACE_SRC" "$SPACE_IN"
    if "$BIN_ABS" -hide_banner -loglevel error -i "$SPACE_IN" -vn -ac 1 -ar 16000 \
            -f wav -acodec pcm_s16le - > "$TMP/space.wav" 2>"$TMP/space.err"; then
        sp_sz="$(file_size "$TMP/space.wav")"
        if [ "$sp_sz" -gt 32000 ]; then
            ok "路径含空格可用（$(basename "$SPACE_IN") -> $sp_sz bytes）"
            wav_fmt_check "$TMP/space.wav" "含空格路径" || true
        else
            bad "含空格路径输出太小: $sp_sz bytes"
        fi
    else
        bad "含空格路径解码失败: $(head -n 2 "$TMP/space.err" | tr '\n' ' ')"
    fi
fi

# =============================================================================
title 6/6 "体积与目标对比"
# =============================================================================
case "$PLATFORM" in
    win-x64)          RANGE="9-14" ;;
    macos-arm64)      RANGE="7-11" ;;
    macos-x64)        RANGE="7-12" ;;
    macos-universal)  RANGE="14-22" ;;
    *)                RANGE="" ;;
esac
if [ -n "$RANGE" ]; then
    MIN_MB="${RANGE%-*}"; MAX_MB="${RANGE#*-}"
    ACTUAL="$(size_mb "$BIN_ABS")"
    # 目标区间是"上限"约束：超出视为失败；比下限还小只是更好，不算失败
    if awk -v a="$ACTUAL" -v hi="$MAX_MB" 'BEGIN { exit !(a <= hi*1.15) }'; then
        if awk -v a="$ACTUAL" -v lo="$MIN_MB" 'BEGIN { exit !(a < lo) }'; then
            ok "体积 ${ACTUAL} MB 小于目标区间 ${RANGE} MB（更小，符合预期）"
        else
            ok "体积 ${ACTUAL} MB 在目标区间 ${RANGE} MB 内"
        fi
    else
        bad "体积 ${ACTUAL} MB 超出目标上限 ${MAX_MB} MB（+15% 容差）"
    fi
else
    info "未知平台的体积目标，跳过"
fi

# =============================================================================
printf '\n\033[1m结果: %d 项通过, %d 项失败\033[0m\n' "$PASS" "$FAILS"
[ "$FAILS" -eq 0 ] || exit 1
