#!/usr/bin/env bash
# =============================================================================
# 生成 Release 说明（列出每个产物的体积并与目标区间对比）+ SHA256SUMS.txt
# 用法: release-notes.sh <dist 目录> <tag>
# 退出码: 0 全部产物齐全且可解析；1 有产物缺失或 zip 内容解析失败
# =============================================================================
set -euo pipefail

DIST="${1:?用法: release-notes.sh <dist 目录> <tag>}"
TAG="${2:?用法: release-notes.sh <dist 目录> <tag>}"
VERSION="${FFMPEG_VERSION:-unknown}"

case "$TAG" in
    *[!A-Za-z0-9._-]*|.*|*..*)
        echo "ERROR: tag 非法: ${TAG}（只允许字母数字 . _ -）" >&2
        exit 2 ;;
esac

command -v unzip >/dev/null 2>&1 || { echo "ERROR: 缺少 unzip" >&2; exit 2; }

# zip 名 | 平台标签 | 二进制名 | 体积目标区间(MB)
TARGETS="
ffmpeg-win-x64.zip|Windows x64|ffmpeg.exe|9-14
ffmpeg-macos-arm64.zip|macOS arm64|ffmpeg|7-11
ffmpeg-macos-x64.zip|macOS x86_64|ffmpeg|7-12
ffmpeg-macos-universal.zip|macOS universal|ffmpeg|14-22
"

bin_size_bytes() {  # $1=zip $2=二进制名 -> 打印解压后字节数（取不到则空）
    unzip -l "$1" 2>/dev/null | awk -v n="$2" '$NF == n { print $1; exit }'
}
# 从 zip 内的 VERSION 文件读出版本串（首行 "ffmpeg <version>" 的第 2 列）；空串表示读不到
extract_zip_version() {
    unzip -p "$1" VERSION 2>/dev/null | head -n 1 | awk '{print $2}' || true
}
mb() { awk -v b="${1:-0}" 'BEGIN { printf "%.2f", b/1048576 }'; }

FAIL=0

{
    echo "FFmpeg ${VERSION} 最小化静态构建（LGPL-2.1-or-later）"
    echo
    echo "组件白名单唯一来源：\`scripts/ffmpeg-minimal/components.sh\`。"
    echo "静态链接、无第三方运行时依赖；已禁用 GPL / 非自由 / (L)GPLv3 组件。"
    echo
    echo "| 产物 | 平台 | 版本 | 可执行文件体积 | 目标区间 | 结论 |"
    echo "| --- | --- | --- | --- | --- | --- |"
    while IFS='|' read -r zip label bin range; do
        [ -n "${zip:-}" ] || continue
        if [ ! -f "$DIST/$zip" ]; then
            echo "| \`$zip\` | $label | ? | 缺失 | $range MB | ✗ 未生成 |"
            FAIL=1
            continue
        fi
        zver="$(extract_zip_version "$DIST/$zip")"
        bytes="$(bin_size_bytes "$DIST/$zip" "$bin" | tr -d ' \r')"
        if [ -z "$bytes" ]; then
            echo "| \`$zip\` | $label | \`${zver:-?}\` | 无法解析 | $range MB | ✗ zip 内找不到 \`$bin\` |"
            FAIL=1
            continue
        fi
        ver_bad=""
        if [ -z "$zver" ]; then
            ver_bad="✗ 缺少 VERSION"
        elif [ "$VERSION" != "unknown" ] && [ "$zver" != "${VERSION}-minimal" ]; then
            ver_bad="✗ 版本不符（期望 ${VERSION}-minimal）"
        fi
        if [ -n "$ver_bad" ]; then
            echo "| \`$zip\` | $label | \`${zver:-?}\` | $(mb "$bytes") MB | $range MB | $ver_bad |"
            FAIL=1
            continue
        fi
        lo="${range%-*}"; hi="${range#*-}"
        verdict="$(awk -v a="$(mb "$bytes")" -v lo="$lo" -v hi="$hi" \
            'BEGIN { if (a > hi*1.15) print "✗ 超出上限"; else if (a < lo) print "✓ 达标（比目标更小）"; else print "✓ 达标" }')"
        echo "| \`$zip\` | $label | \`$zver\` | $(mb "$bytes") MB | $range MB | $verdict |"
    done <<< "$TARGETS"
    echo
    echo "每个 zip 内含：可执行文件、\`LICENSE\`（LGPL-2.1 全文）、\`BUILD.txt\`（完整 configure 命令 + FFmpeg 版本 + 源码 sha256）、\`VERSION\`（机器可读版本 + 源码 sha256）。"
    echo
    echo '```'
    echo "zip sha256:"
    ( cd "$DIST" && { sha256sum ./*.zip 2>/dev/null || shasum -a 256 ./*.zip; } )
    echo '```'
} > "$DIST/RELEASE_NOTES.md"

( cd "$DIST" && { sha256sum ./*.zip 2>/dev/null || shasum -a 256 ./*.zip; } ) > "$DIST/SHA256SUMS.txt"

echo "已生成: $DIST/RELEASE_NOTES.md 与 $DIST/SHA256SUMS.txt (tag: $TAG)"
if [ "$FAIL" -ne 0 ]; then
    echo "ERROR: 产物缺失、版本不符或 zip 解析失败，Release 不应发布" >&2
    exit 1
fi
