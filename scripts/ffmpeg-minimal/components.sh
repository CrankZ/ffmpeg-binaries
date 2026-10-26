#!/usr/bin/env bash
# =============================================================================
# FFmpeg 最小化构建 —— 组件白名单的唯一来源
#
# 三平台共用本文件，任何构建脚本都不得再复制一份白名单。
# 所有名字都是 configure 的组件名（--enable-decoder=<name> 等），
# 已对 FFmpeg 9.0.2 源码逐一校验（scripts/ffmpeg-minimal/check-components.sh）。
#
# 用途反推依据：muyi（Tauri 2）只做"任意音视频 -> 单声道 16k PCM 管道"、
# "预转 WAV 文件"、"时长探测"，不做视频解码、不做编码（除 pcm_s16le）、
# 不联网、不需要 ffprobe/ffplay。
# =============================================================================

# --- 协议 --------------------------------------------------------------------
FFMPEG_MIN_PROTOCOLS="file,pipe"

# --- demuxer -----------------------------------------------------------------
FFMPEG_MIN_DEMUXERS="mov,matroska,avi,flv,mpegts,mpegps,mp3,aac,flac,ogg,wav,asf,rm,aiff,amr,au,caf,w64"

# --- muxer -------------------------------------------------------------------
FFMPEG_MIN_MUXERS="wav,null"

# --- encoder -----------------------------------------------------------------
FFMPEG_MIN_ENCODERS="pcm_s16le"

# --- 音频 decoder ------------------------------------------------------------
# mp3float：全量构建默认优先走浮点 MP3 解码；只开 mp3（定点）会与参考构建 PCM/性能不一致
FFMPEG_MIN_DECODERS="aac,aac_latm,mp3,mp3float,mp2,ac3,eac3,dca,truehd,mlp,opus,vorbis,flac,alac,wavpack,tta,ape,cook,sipr,atrac3,atrac3p,wmav1,wmav2,wmapro,wmalossless,adpcm_ms,adpcm_ima_wav,gsm,amrnb,amrwb,pcm_s16le,pcm_s16be,pcm_u8,pcm_s24le,pcm_s24be,pcm_s32le,pcm_s32be,pcm_f32le,pcm_f64le,pcm_alaw,pcm_mulaw"

# --- parser ------------------------------------------------------------------
# 注意：FFmpeg 9.0 起不再有独立的 eac3 / truehd parser
# （eac3 由 ac3 parser 覆盖，truehd 由 mlp parser 覆盖），
# 因此这里不给它们 --enable-parser，否则 configure 会因组件不存在而失败。
FFMPEG_MIN_PARSERS="aac,aac_latm,mpegaudio,opus,vorbis,flac,ac3,dca,cook,mlp"

# --- filter ------------------------------------------------------------------
# -ac / -ar 的重采样由自动插入的 aresample 完成，缺少即报 "no such filter"
FFMPEG_MIN_FILTERS="aresample,anull,format,aformat,atrim"

# --- 库 ----------------------------------------------------------------------
# 注：libpostproc 自 FFmpeg 8.0 起已从源码树移除，没有 --disable-postproc 这个
#     configure 选项了（9.0.2 上写了会直接报 Unknown option），因此这里只列
#     avdevice / swscale；postproc 已经不存在，效果等价于"关闭"。
FFMPEG_MIN_LIBS_ENABLE="avcodec,avformat,avfilter,swresample"
FFMPEG_MIN_LIBS_DISABLE="avdevice,swscale"

# --- 许可证 --------------------------------------------------------------
# LGPL-2.1-or-later：禁止 GPL / 非自由 / (L)GPLv3 组件
FFMPEG_MIN_LICENSE_ARGS="--disable-gpl --disable-nonfree --disable-version3"

# =============================================================================
# 组件白名单 -> configure 参数（结果写入全局数组 FFMPEG_MIN_COMPONENT_ARGS）
# =============================================================================
ffmpeg_min_components_args() {
    FFMPEG_MIN_COMPONENT_ARGS=(
        --disable-everything
        --enable-protocol="$FFMPEG_MIN_PROTOCOLS"
        --enable-demuxer="$FFMPEG_MIN_DEMUXERS"
        --enable-muxer="$FFMPEG_MIN_MUXERS"
        --enable-encoder="$FFMPEG_MIN_ENCODERS"
        --enable-decoder="$FFMPEG_MIN_DECODERS"
        --enable-parser="$FFMPEG_MIN_PARSERS"
        --enable-filter="$FFMPEG_MIN_FILTERS"
    )

    local lib
    for lib in ${FFMPEG_MIN_LIBS_ENABLE//,/ }; do
        FFMPEG_MIN_COMPONENT_ARGS+=("--enable-$lib")
    done
    for lib in ${FFMPEG_MIN_LIBS_DISABLE//,/ }; do
        FFMPEG_MIN_COMPONENT_ARGS+=("--disable-$lib")
    done
}

# =============================================================================
# 与平台无关的通用 configure 参数（不含白名单，不覆盖 arch / cc / 版本相关项）
#
# 性能约束（1.md 第三节，硬性）：
#   * 禁止 --enable-small（= -Os，会让解码慢 10~30%）
#   * 禁止 --disable-asm（会让 x86 掉到 C 实现）
#   * 保留 pthreads、保留 runtime cpudetect
#   * 体积只能来自"组件裁剪 + strip"
# 这里统一使用官方默认的 -O3，并用 --optflags 显式覆盖 ffbuild 的优化等级选择逻辑。
# =============================================================================
ffmpeg_min_common_args() {
    FFMPEG_MIN_COMMON_ARGS=(
        # —— 只产出 ffmpeg 一个可执行文件，不要 ffprobe / ffplay ——
        --disable-programs
        --enable-ffmpeg
        # —— 体积：不要文档 / 调试符号 ——
        --disable-doc
        --disable-debug
        # —— 不要网络 / 流媒体协议，也不要自动探测第三方库 ——
        --disable-network
        --disable-autodetect
        # —— 白名单之外的平台专有组件：macOS 的 VideoToolbox 硬解（不需要，
        #    关掉后 macOS 产物只依赖 /usr/lib/libSystem，不再链 CoreMedia/CoreVideo）——
        --disable-videotoolbox
        # —— 静态链接 ——
        --enable-static
        --disable-shared
        # —— 性能：线程与运行时 CPU 检测都保留（禁止 --enable-small / --disable-asm）——
        --enable-pthreads
        --enable-runtime-cpudetect
        --optflags="$FFMPEG_MIN_OPTFLAGS"
        # —— 许可证 ——
        --disable-gpl
        --disable-nonfree
        --disable-version3
    )
}

# -----------------------------------------------------------------------------
# 优化等级
#
# 1.md 写的是"统一用 -O2、个别热点解码器可单独 -O3"。但实测（CI run 40201186924）：
# FFmpeg 9.0 的 mp3 解码路径（mpegaudiodsp）已经没有 x86 SIMD 汇编，全靠编译器自动
# 向量化，-O2 相对官方全量构建默认的 -O3：
#   * 解码耗时慢 75%（1500s 音频：3.05s vs 1.74s）
#   * PCM 与官方构建不是逐字节一致（浮点向量化改变舍入顺序）
# 也就是说 -O2 会同时踩中 1.md 的两条硬性验收（PCM SHA256 一致、耗时差异 < 5%）。
# 由于 FFmpeg 的构建系统不支持给单个文件加编译选项，这里按该条的初衷
#（宁可 -O3 也不要 -Os / 不要牺牲性能）统一使用官方默认的 -O3。
# 体积不是问题：实测 3.3MB(win-x64) / 3.08MB(macos-arm64)，远低于目标区间。
# 需要严格 -O2 时：FFMPEG_MIN_OPTFLAGS=-O2 bash scripts/ffmpeg-minimal/build-msys2.sh
# -----------------------------------------------------------------------------
FFMPEG_MIN_OPTFLAGS="${FFMPEG_MIN_OPTFLAGS:--O3}"

# 冒烟测试里用来确认"跑的是我们这份裁剪构建"的版本后缀。
# FFmpeg 会在版本号后自动补一个连字符，所以这里不带前导 "-"：
# extra_version=minimal -> "ffmpeg version 9.0.2-minimal"
FFMPEG_MIN_EXTRA_VERSION="minimal"
