#!/usr/bin/env bash
# =============================================================================
# 与"同版本官方全量构建"对比：
#   1) 同一输入解码成裸 PCM（单声道 16k）后采样数据必须完全一致
#   2) 解码耗时差异必须 < 5%（取多次运行最优值，降低 CI 噪声）
#
# 说明：最小化构建的白名单里只有 wav/null 两个 muxer（多一个都不该有），
# 所以这里不用 `-f s16le`，而是统一输出 wav 后跳过固定 1024 字节头部再比 PCM，
# 效果等价于比较 `-f s16le` 的裸数据。
#
# 用法: compare-pcm.sh --minimal BIN --reference BIN --fixtures DIR
#                      [--tolerance 5] [--repeats 3]
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

MINIMAL=""
REFERENCE=""
FIXTURES="$HERE/../../fixtures"
TOLERANCE="5"
REPEATS="5"
# 性能对比只跑这几个代表性格式（PCM 一致性对全部 fixture 都跑）
PERF_FIXTURES="${PERF_FIXTURES:-tone.mp3,tone.aac,tone_alac.m4a,tone.mkv}"
# 用 -stream_loop 把工作量放大到秒级，抵消进程启动开销的影响
PERF_LOOP="${PERF_LOOP:-500}"

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

file_size() {
    if [ "$(uname -s)" = "Darwin" ]; then stat -f %z "$1"; else stat -c %s "$1"; fi
}
sha256_of_pcm() {  # 跳过 1024 字节头部，只对 PCM 数据取 sha256
    tail -c +1025 "$1" | { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; } | awk '{print $1}'
}
# 交替测量 minimal / reference，避免"先测的那个吃亏"（CPU 降频、缓存冷热）
time_both() {   # $1 = repeats, 其余 = 交给两个二进制共同的参数；结果写入 T_MIN / T_REF
    local n="$1" x
    shift
    T_MIN=999; T_REF=999
    TIMEFORMAT=%R
    for _ in $(seq 1 "$n"); do
        x=$( { time "$MINIMAL" "$@" >/dev/null 2>&1; } 2>&1 )
        T_MIN=$(awk -v a="$x" -v b="$T_MIN" 'BEGIN { print (a+0 < b+0) ? a+0 : b+0 }')
        x=$( { time "$REFERENCE" "$@" >/dev/null 2>&1; } 2>&1 )
        T_REF=$(awk -v a="$x" -v b="$T_REF" 'BEGIN { print (a+0 < b+0) ? a+0 : b+0 }')
    done
}

# PCM 差异定位：首个不同字节偏移 + 不同字节数（只在 sha 不相等时调用）
pcm_diff() {
    local a="$1" b="$2" total changed first
    total="$(file_size "$a")"
    if command -v cmp >/dev/null 2>&1; then
        cmp -l "$a" "$b" 2>/dev/null > "$TMP/cmp.txt" || true
        changed="$(wc -l < "$TMP/cmp.txt" | tr -d ' ')"
        first="$(head -n 1 "$TMP/cmp.txt" 2>/dev/null | awk '{print $1}')"
        printf 'PCM 长度 %s / %s，首个差异字节 @%s，差异字节数 %s\n' \
            "$total" "$(file_size "$b")" "${first:-?}" "${changed:-0}"
    else
        printf 'PCM 长度 %s / %s（无 cmp，无法定位差异）\n' "$total" "$(file_size "$b")"
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
printf '  容差      : %s%%（耗时取 %s 次最优，-stream_loop %s）\n\n' "$TOLERANCE" "$REPEATS" "$PERF_LOOP"
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

    smin="$(file_size "$o_min")"
    sref="$(file_size "$o_ref")"
    hmin="$(sha256_of_pcm "$o_min")"
    href="$(sha256_of_pcm "$o_ref")"

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

    time_both "$REPEATS" -hide_banner -loglevel error -stream_loop "$PERF_LOOP" \
        -i "$f" -vn -ac 1 -ar 16000 -f null -
    t_min="$T_MIN"; t_ref="$T_REF"
    delta="$(awk -v a="$t_min" -v b="$t_ref" 'BEGIN { if (b+0 <= 0) print "n/a"; else printf "%.1f", (a-b)*100.0/b }')"

    if [ "$delta" = "n/a" ]; then
        bad "$name 耗时测量失败"
    elif awk -v d="$delta" -v t="$TOLERANCE" 'BEGIN { exit !(d+0 <= t+0) }'; then
        ok "$name 解码耗时 ${t_min}s vs ${t_ref}s (Δ${delta}%)"
    else
        bad "$name 解码耗时超标: ${t_min}s vs ${t_ref}s (Δ${delta}% > ${TOLERANCE}%)"
    fi
done

printf '\n\033[1m结果: %d 项通过, %d 项失败\033[0m\n' "$PASS" "$FAILS"
[ "$FAILS" -eq 0 ] || exit 1
