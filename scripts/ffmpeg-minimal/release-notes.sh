#!/usr/bin/env bash
# =============================================================================
# 生成 Release 说明（列出每个产物的体积并与目标区间对比）+ SHA256SUMS.txt
# 用法: release-notes.sh <dist 目录> <tag>
# =============================================================================
set -euo pipefail

DIST="${1:?用法: release-notes.sh <dist 目录> <tag>}"
TAG="${2:?用法: release-notes.sh <dist 目录> <tag>}"
VERSION="${FFMPEG_VERSION:-unknown}"

# zip 名 | 平台标签 | 二进制名 | 体积目标区间(MB)
TARGETS="
ffmpeg-win-x64.zip|Windows x64|ffmpeg.exe|9-14
ffmpeg-macos-arm64.zip|macOS arm64|ffmpeg|7-11
ffmpeg-macos-x64.zip|macOS x86_64|ffmpeg|7-12
ffmpeg-macos-universal.zip|macOS universal|ffmpeg|14-22
"

bin_size_bytes() {  # $1=zip $2=二进制名 -> 打印解压后字节数
    unzip -l "$1" | awk -v n="$2" '$4 == n { print $1; exit }'
}
mb() { awk -v b="${1:-0}" 'BEGIN { printf "%.2f", b/1048576 }'; }

{
    echo "FFmpeg ${VERSION} 最小化静态构建（LGPL-2.1-or-later）"
    echo
    echo "组件白名单唯一来源：\`scripts/ffmpeg-minimal/components.sh\`。"
    echo "静态链接、无第三方运行时依赖；已禁用 GPL / 非自由 / (L)GPLv3 组件。"
    echo
    echo "| 产物 | 平台 | 可执行文件体积 | 目标区间 | 结论 |"
    echo "| --- | --- | --- | --- | --- |"
    printf '%s\n' "$TARGETS" | while IFS='|' read -r zip label bin range; do
        [ -n "${zip:-}" ] || continue
        if [ ! -f "$DIST/$zip" ]; then
            echo "| \`$zip\` | $label | 缺失 | $range MB | ✗ 未生成 |"
            continue
        fi
        bytes="$(bin_size_bytes "$DIST/$zip" "$bin")"
        lo="${range%-*}"; hi="${range#*-}"
        verdict="$(awk -v a="$(mb "$bytes")" -v lo="$lo" -v hi="$hi" \
            'BEGIN { if (a >= lo*0.85 && a <= hi*1.15) print "✓ 达标"; else print "✗ 超出" }')"
        echo "| \`$zip\` | $label | $(mb "$bytes") MB | $range MB | $verdict |"
    done
    echo
    echo "每个 zip 内含：可执行文件、\`LICENSE\`（LGPL-2.1 全文）、\`BUILD.txt\`（完整 configure 命令 + FFmpeg 版本 + 源码 sha256）。"
    echo
    echo '```'
    echo "zip sha256:"
    ( cd "$DIST" && sha256sum ./*.zip 2>/dev/null || shasum -a 256 ./*.zip )
    echo '```'
} > "$DIST/RELEASE_NOTES.md"

( cd "$DIST" && { sha256sum ./*.zip 2>/dev/null || shasum -a 256 ./*.zip; } > SHA256SUMS.txt )

echo "已生成: $DIST/RELEASE_NOTES.md 与 $DIST/SHA256SUMS.txt (tag: $TAG)"
