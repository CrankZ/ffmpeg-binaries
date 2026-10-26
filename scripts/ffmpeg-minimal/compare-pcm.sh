#!/usr/bin/env bash
# =============================================================================
# 与"同版本官方全量构建"对比：
#   1) 同一输入解码成裸 PCM（单声道 16k）后采样数据必须完全一致
#   2) 解码耗时差异必须 < 5%（单线程墙钟；先预热丢弃一轮，再测偶数轮并交替顺序）
#      为什么这样测：
#        * -threads 1：多线程解码的调度抖动会让单轮波动达 20-30%，两个构建的线程实现
#          完全相同，单线程才能隔离出代码路径本身的差异；
#        * 测墙钟而不是 CPU 时间：Windows 的 Git Bash 不支持 TIMEFORMAT 的 %U；
#        * 预热 + 交替顺序 + 偶数轮累计耗时比值：实测"同一对里后跑的那个快约 30%"
#          （CPU 升频 / 页缓存），先跑一轮丢弃做预热；测量轮数取偶数，保证两个二进制
#          各占一半"先跑"名额，累计耗时比值恰好抵消顺序偏差。
#
# 说明：最小化构建的白名单里只有 wav/null 两个 muxer（多一个都不该有），
# 所以这里不用 `-f s16le`，而是统一输出 wav 后解析 RIFF 的 data chunk，
# 只比裸 PCM，效果等价于 `-f s16le`。
#
# 用法: compare-pcm.sh --minimal BIN --reference BIN --fixtures DIR
#                      [--tolerance 5] [--repeats 4]
# =============================================================================
set -uo pipefail
# 耗时解析依赖 "秒.毫秒" 这种数字格式，避免 locale 把小数点变成逗号
export LC_NUMERIC=C

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/lib/parse.sh"

MINIMAL=""
REFERENCE=""
FIXTURES="$HERE/../../fixtures"
TOLERANCE="5"
REPEATS="4"
# 性能对比只跑这几个代表性格式（PCM 一致性对全部 fixture 都跑）
PERF_FIXTURES="${PERF_FIXTURES:-tone.mp3,tone.aac,tone_alac.m4a,tone.mkv}"
# 用 -stream_loop 把工作量放大到秒级，抵消进程启动开销的影响
PERF_LOOP="${PERF_LOOP:-300}"

while [ $# -gt 0 ]; do
    case "$1" in
        --minimal)   MINIMAL="$2"; shift 2 ;;
        --reference) REFERENCE="$2"; shift 2 ;;
        --fixtures)  FIXTURES="$2"; shift 2 ;;
        --tolerance) TOLERANCE="$2"; shift 2 ;;
        --repeats)   REPEATS="$2"; shift 2 ;;
        --loop)      PERF_LOOP="$2"; shift 2 ;;
        -h|--help)   sed -n '2,15p' "$0"; exit 0 ;;
        *) echo "未知参数: $1" >&2; exit 2 ;;
    esac
done

[ -f "$MINIMAL" ]   || { echo "ERROR: --minimal 不存在: $MINIMAL" >&2; exit 2; }
[ -f "$REFERENCE" ] || { echo "ERROR: --reference 不存在: $REFERENCE" >&2; exit 2; }
[ -d "$FIXTURES" ]  || { echo "ERROR: fixtures 目录不存在" >&2; exit 2; }

# wav/pcm 的解析逻辑统一放在 lib/parse.sh：verify.sh 和离线单测用的是同一份实现，
# 避免"测试通过但真实脚本里另一份实现有 bug"。
sha256_of_pcm() {  # 只对 PCM 数据取 sha256
    local off
    off="$(ffmpeg_min_pcm_data_offset "$1")" || return 1
    tail -c +$((off + 1)) "$1" | { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; } | awk '{print $1}'
}

# 单次计时：$1=二进制，其余=参数；把墙钟秒数打印到 stdout，解析失败返回 1
time_one() {
    local bin="$1" t
    shift
    t=$( { time "$bin" "$@" >/dev/null 2>&1; } 2>&1 )
    ffmpeg_min_is_number "$t" || { printf 'time 输出无法解析: [%s]\n' "$t" >&2; return 1; }
    printf '%s\n' "$t"
}

# 先各跑一次做预热（结果丢弃），让 CPU 升频、页缓存进入稳定状态；
# 然后测偶数轮并交替顺序：奇数轮 minimal 先跑、偶数轮 reference 先跑，
# 两个二进制各占一半"先跑"名额，累计耗时比值恰好抵消顺序带来的系统性偏差。
# 判定用累计耗时比值，展示用每轮平均耗时。
# 结果写入 AVG_MIN / AVG_REF / RATIO / RATIOS。
time_both() {   # $1 = repeats, 其余 = 交给两个二进制共同的参数
    local n="$1" i=0 x y r s_min=0 s_ref=0
    shift
    AVG_MIN=""; AVG_REF=""; RATIOS=""; RATIO=""
    TIMEFORMAT=%R
    # 预热（丢弃）
    time_one "$MINIMAL" "$@" >/dev/null || return 1
    time_one "$REFERENCE" "$@" >/dev/null || return 1
    # 测量轮数必须为偶数，否则"先跑"名额不对等，顺序偏差无法抵消
    [ $((n % 2)) -eq 0 ] || n=$((n + 1))
    while [ "$i" -lt "$n" ]; do
        i=$((i + 1))
        if [ $((i % 2)) -eq 1 ]; then
            x="$(time_one "$MINIMAL" "$@")" || return 1
            y="$(time_one "$REFERENCE" "$@")" || return 1
        else
            y="$(time_one "$REFERENCE" "$@")" || return 1
            x="$(time_one "$MINIMAL" "$@")" || return 1
        fi
        s_min="$(awk -v a="$s_min" -v b="$x" 'BEGIN { printf "%.3f", a + b }')"
        s_ref="$(awk -v a="$s_ref" -v b="$y" 'BEGIN { printf "%.3f", a + b }')"
        r="$(awk -v a="$x" -v b="$y" 'BEGIN { if (b+0 <= 0) print "n/a"; else printf "%.4f", a/b }')"
        [ "$r" = "n/a" ] && return 1
        RATIOS="$RATIOS $r"
    done
    AVG_MIN="$(awk -v s="$s_min" -v n="$n" 'BEGIN { printf "%.3f", s/n }')"
    AVG_REF="$(awk -v s="$s_ref" -v n="$n" 'BEGIN { printf "%.3f", s/n }')"
    RATIO="$(awk -v a="$s_min" -v b="$s_ref" 'BEGIN { if (b+0 <= 0) print "n/a"; else printf "%.4f", a/b }')"
    [ "$RATIO" != "n/a" ] && [ -n "$AVG_MIN" ] && [ -n "$AVG_REF" ] && [ -n "$RATIOS" ]
}

# PCM 差异定位：首个不同字节偏移 + 不同字节数（只在 sha 不相等时调用）
pcm_diff() {
    local a="$1" b="$2" oa ob total changed first
    oa="$(ffmpeg_min_pcm_data_offset "$a")"; ob="$(ffmpeg_min_pcm_data_offset "$b")"
    total="$(ffmpeg_min_pcm_bytes "$a")"
    if command -v cmp >/dev/null 2>&1; then
        cmp -l <(tail -c +$((oa + 1)) "$a") <(tail -c +$((ob + 1)) "$b") 2>/dev/null > "$TMP/cmp.txt" || true
        changed="$(wc -l < "$TMP/cmp.txt" | tr -d ' ')"
        first="$(head -n 1 "$TMP/cmp.txt" 2>/dev/null | awk '{print $1}')"
        printf 'PCM 长度 %s / %s，首个差异字节 @%s，差异字节数 %s\n' \
            "$total" "$(ffmpeg_min_pcm_bytes "$b")" "${first:-?}" "${changed:-0}"
    else
        printf 'PCM 长度 %s / %s（无 cmp，无法定位差异）\n' "$total" "$(ffmpeg_min_pcm_bytes "$b")"
    fi
}

PASS=0
FAILS=0
ok()  { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad() { FAILS=$((FAILS + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

printf '\033[1mPCM 一致性 + 解码耗时对比\033[0m\n'
printf '  minimal   : %s\n' "$MINIMAL"
printf '  reference : %s\n' "$REFERENCE"
printf '  容差      : %s%%（单线程墙钟，预热 1 轮丢弃，%s 轮交替顺序按累计耗时比值判定，-stream_loop %s）\n\n' "$TOLERANCE" "$REPEATS" "$PERF_LOOP"
printf '  %-18s %12s %12s %18s %s\n' "fixture" "PCM(min)" "PCM(ref)" "PCM sha256" "结果"

for f in "$FIXTURES"/tone*; do
    [ -f "$f" ] || continue
    name="$(basename "$f")"
    o_min="$TMP/$name.min.wav"
    o_ref="$TMP/$name.ref.wav"

    if ! "$MINIMAL" -hide_banner -loglevel error -y -i "$f" -vn -ac 1 -ar 16000 \
            -f wav -acodec pcm_s16le - > "$o_min" 2>"$TMP/e1"; then
        bad "$name 最小化构建解码失败: $(head -n 1 "$TMP/e1")"
        continue
    fi
    if ! "$REFERENCE" -hide_banner -loglevel error -y -i "$f" -vn -ac 1 -ar 16000 \
            -f wav -acodec pcm_s16le - > "$o_ref" 2>"$TMP/e2"; then
        bad "$name 参考构建解码失败: $(head -n 1 "$TMP/e2")"
        continue
    fi

    if ! smin="$(ffmpeg_min_pcm_bytes "$o_min")"; then
        bad "$name 无法从 minimal 输出的 wav 头解析 PCM 长度"
        continue
    fi
    if ! sref="$(ffmpeg_min_pcm_bytes "$o_ref")"; then
        bad "$name 无法从 reference 输出的 wav 头解析 PCM 长度"
        continue
    fi
    if ! hmin="$(sha256_of_pcm "$o_min")"; then
        bad "$name 无法计算 minimal 的 PCM sha256"
        continue
    fi
    if ! href="$(sha256_of_pcm "$o_ref")"; then
        bad "$name 无法计算 reference 的 PCM sha256"
        continue
    fi

    same="NO"
    [ "$hmin" = "$href" ] && [ "$smin" = "$sref" ] && same="YES"

    if [ "$same" = "YES" ]; then
        verdict="ok"; PASS=$((PASS + 1))
    else
        verdict="PCM不一致"; FAILS=$((FAILS + 1))
    fi

    printf '  %-18s %12s %12s %18s %10s\n' "$name" "$smin" "$sref" "$(printf '%s' "$hmin" | cut -c1-16)" "$verdict"
    [ "$same" = "YES" ] || printf '                     %s\n' "$(pcm_diff "$o_min" "$o_ref")"

    # 性能对比只对代表性格式做，且用 -stream_loop 放大工作量 + -f null 去掉 I/O 噪声，
    # 否则 5 秒样本的解码时间几乎全被进程启动开销淹没，测出来没有意义。
    case ",$PERF_FIXTURES," in
        *",$name,"*) ;;
        *) continue ;;
    esac

    if ! time_both "$REPEATS" -hide_banner -loglevel error -threads 1 -stream_loop "$PERF_LOOP" \
            -i "$f" -vn -ac 1 -ar 16000 -f null -; then
        bad "$name 耗时测量失败（无法解析 time 输出）"
        continue
    fi
    t_min="$AVG_MIN"; t_ref="$AVG_REF"
    delta="$(awk -v r="$RATIO" 'BEGIN { printf "%.1f", (r - 1) * 100 }')"

    if awk -v d="$delta" -v t="$TOLERANCE" 'BEGIN { exit !(d+0 <= t+0) }'; then
        ok "$name 解码耗时 ${t_min}s vs ${t_ref}s (Δ${delta}%)"
    else
        bad "$name 解码耗时超标: ${t_min}s vs ${t_ref}s (Δ${delta}% > ${TOLERANCE}%)，各轮比值:${RATIOS}"
    fi
done

printf '\n\033[1m结果: %d 项通过, %d 项失败\033[0m\n' "$PASS" "$FAILS"
[ "$FAILS" -eq 0 ] || exit 1
