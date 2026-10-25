# ffmpeg-binaries — 最小化 FFmpeg 静态构建（LGPL）

给 **muyi**（Tauri 2 桌面应用）用的最小化 FFmpeg 可执行文件构建流水线。

功能边界由调用点反推，只覆盖三件事：

```bash
# 1) 音频提取到管道（主力路径）
ffmpeg -hide_banner -loglevel error -i <任意音视频文件> [-t <秒>] \
       -vn -ac 1 -ar 16000 -f wav -acodec pcm_s16le -

# 2) 预转 WAV 文件
ffmpeg -hide_banner -loglevel error -y -err_detect ignore_err \
       -fflags +discardcorrupt+genpts -i <文件> \
       -vn -ac 1 -ar 16000 -f wav -acodec pcm_s16le <输出.wav>

# 3) 时长探测（从 stderr 解析 Duration:）
ffmpeg -hide_banner -i <文件> -vn -f null -
```

不做视频解码、不做视频编码、不做网络/流媒体、不需要 ffprobe/ffplay。

## 产物

| zip | 内容 | 体积目标 |
| --- | --- | --- |
| `ffmpeg-win-x64.zip` | `ffmpeg.exe` + `LICENSE` + `BUILD.txt` | 9–14 MB |
| `ffmpeg-macos-arm64.zip` | `ffmpeg` + … | 7–11 MB |
| `ffmpeg-macos-x64.zip` | `ffmpeg` + … | 7–12 MB |
| `ffmpeg-macos-universal.zip` | `ffmpeg`（arm64 + x86_64） | 14–22 MB |

每个产物都是**完全静态**的：Windows 只依赖系统 DLL，macOS 只依赖 `/usr/lib/libSystem` 等系统库。
许可证为 **LGPL-2.1-or-later**（`--disable-gpl --disable-nonfree --disable-version3`），不含 x264/x265/fdk-aac 等 GPL/非自由组件。

## 如何触发构建

```bash
# 手动触发（推荐）
gh workflow run build-ffmpeg-minimal.yml \
  -f ffmpeg_version=9.0.2 \
  -f release_tag=ffmpeg-min-9.0.2 \
  -f build_reference=true \
  -f publish_release=true

# 跟踪进度
gh run watch
```

也可以在 GitHub 网页 Actions → `build-ffmpeg-minimal` → Run workflow 里点。

输入项：

| 输入 | 说明 |
| --- | --- |
| `ffmpeg_version` | 从哪里下载源码（`https://ffmpeg.org/releases/ffmpeg-<版本>.tar.xz`） |
| `release_tag` | Release 名；4 个 zip + `SHA256SUMS.txt` 会发布到这个 tag |
| `build_reference` | 是否额外构建一份同版本**全量**（默认组件全开）作对照，用于 PCM 一致性与解码耗时对比 |
| `publish_release` | 是否发 Release（关掉就只在 Actions 里留 artifact） |

## 如何下载产物

```bash
# 从 Release（推荐，带 sha256）
gh release download ffmpeg-min-9.0.2 --pattern '*.zip' --dir ./dl

# 或者从某次 run 的 artifact
gh run download <run-id> -n windows-binaries -D ./dl
```

## 放进 Tauri 的 resources

把对应平台的 `ffmpeg` / `ffmpeg.exe` 放到 `src-tauri/resources/bin/` 下，`tauri.conf.json`：

```json
{
  "bundle": {
    "resources": [ "resources/bin/ffmpeg", "resources/bin/ffmpeg.exe" ]
  }
}
```

运行时解析路径（Tauri 2）：

```rust
use tauri::path::BaseDirectory;
use tauri::Manager;

let exe_name = if cfg!(windows) { "ffmpeg.exe" } else { "ffmpeg" };
let ffmpeg = app
    .path()
    .resolve(format!("resources/bin/{exe_name}"), BaseDirectory::Resource)?;
```

> macOS 上产物是 **ad-hoc 签名**（`codesign --sign -`），够本机开发/内嵌调用使用；
> 正式分发前需要在打包流程里用自己的 Developer ID 重签并对整包公证，否则 Gatekeeper 会拦。

## 仓库结构

```
.github/workflows/build-ffmpeg-minimal.yml   流水线（windows / macos / release 三个 job）
scripts/ffmpeg-minimal/
  components.sh        组件白名单唯一来源（三平台共用，禁止复制到别处）
  common.sh            源码下载、configure 封装、全量参考构建、打包
  build-msys2.sh       Windows x64 构建（MSYS2 MINGW64）
  build-macos.sh       macOS arm64 / x86_64 / universal 构建
  check-components.sh  构建前校验白名单里的组件名在目标版本里真实存在
  verify.sh            验收：版本 / 静态依赖 / 架构 / 组件面 / 三种调用 / 体积
  verify.ps1           Windows 本地版验收（含纯 PowerShell 的 PE 导入表解析）
  compare-pcm.sh       与同版本全量构建比 PCM 一致性与解码耗时
  release-notes.sh     生成 Release 说明与 SHA256SUMS
fixtures/              冒烟测试样本（覆盖白名单里的容器与音频编码）
```

## 体积与性能策略（硬性约束）

- 体积**只**来自"组件白名单裁剪 + strip"
- 禁止 `--enable-small`（= `-Os`，解码慢 10–30%）
- 禁止 `--disable-asm`；x86_64 必须装 nasm 走 SIMD 汇编路径（构建脚本会断言 `HAVE_X86ASM 1`，为 0 直接失败）
- 保留 pthreads 与 runtime cpudetect
- `--disable-autodetect`：不链接任何第三方库，保证三平台行为一致、可复现
- `--disable-videotoolbox`：白名单之外的 macOS 硬解，关掉后产物只依赖 `/usr/lib/libSystem`

### 优化等级：`-O3`（而非 `-O2`），原因如下

FFmpeg 的构建系统不支持给单个文件加编译选项，而实测（CI run 40201186924，`-O2` 版本对比官方全量构建）：

| 样本 | `-O2` 耗时 | 官方全量（`-O3`） | 差异 |
| --- | --- | --- | --- |
| tone.mp3 | 3.05 s | 1.74 s | **+75%** |
| tone.aac | 1.50 s | 1.45 s | +3.8% |

原因：FFmpeg 9.0 的 mp3 解码路径（`mpegaudiodsp`）已没有 x86 SIMD 汇编，完全依赖编译器自动向量化——
`-O2` 既慢 75%，又让浮点舍入与官方构建不一致（PCM 无法逐字节相同）。也就是说 `-O2` 会同时踩中
"PCM SHA256 一致"和"耗时差异 < 5%"这两条硬性验收。按"个别热点解码器可单独 `-O3`"这条的初衷
（宁可 `-O3`，也不能牺牲性能），这里统一用官方默认的 `-O3`。

体积代价可以忽略：实测 `win-x64` 3.28 MB、`macos-arm64` 3.08 MB，远低于目标区间。
确实需要 `-O2` 时：`FFMPEG_MIN_OPTFLAGS=-O2 bash scripts/ffmpeg-minimal/build-msys2.sh`。

### 关于 `eac3` / `truehd` parser

任务说明的白名单里列了 `eac3`、`truehd` 两个 parser，但 **FFmpeg 9.0 起已没有独立的这两个 parser**
（eac3 由 `ac3` parser 覆盖，truehd 由 `mlp` parser 覆盖）。因此 `components.sh` 里为
`ac3` + `mlp`，解码器 `eac3` / `truehd` 仍然照常启用。`check-components.sh` 会在每次构建前
核对全部组件名，换版本时名字对不上会立刻失败而不是静默跳过。

## 验收清单（CI 自动执行，失败即 job 失败）

1. `ffmpeg -version` 正常输出，且配置行含 `--disable-everything`，不含 `--enable-small` / `--disable-asm`
2. Windows：`objdump -p ffmpeg.exe` 的 `DLL Name` 只有系统 DLL（`api-ms-win-*` 视为系统 API Set）
3. macOS：`otool -L` 只有系统库；`lipo -archs` 含期望架构；`minos >= 13.0`；已签名
4. `fixtures/` 里每个样本逐个跑三种调用：PCM 非空、`-ac 1 -ar 16000` 真实生效（解析 wav 头）、`Duration:` 可解析
5. 与同版本**全量构建**对同一文件输出 PCM 做 SHA256 对比，并比较解码耗时（差异需 < 5%，取多次最优）
6. 产物体积与目标区间对比，写进 Release 说明

> 对比 PCM 时统一输出 `-f wav` 后跳过固定 1024 字节头部再比裸数据 —— 因为最小化构建的
> muxer 白名单里只有 `wav` / `null`，故意不为了测试而多加一个 `s16le` muxer。

## 本地构建

Windows（MSYS2 MINGW64 shell）：

```bash
pacman -S --needed base-devel mingw-w64-x86_64-toolchain mingw-w64-x86_64-nasm make pkgconf diffutils zip
FFMPEG_VERSION=9.0.2 bash scripts/ffmpeg-minimal/build-msys2.sh
powershell -File scripts/ffmpeg-minimal/verify.ps1 -Binary work/build/win-x64/ffmpeg.exe
```

macOS：

```bash
brew install nasm
FFMPEG_VERSION=9.0.2 bash scripts/ffmpeg-minimal/build-macos.sh
bash scripts/ffmpeg-minimal/verify.sh --binary work/build/macos-arm64/ffmpeg \
  --platform macos-arm64 --archs arm64
```

> 仓库必须是 public：私有仓库的 macOS runner 按 10 倍计费。

## fixtures 覆盖情况

样本均为 5 秒 440Hz 正弦波，覆盖：mp4/mkv（含视频流，验证 `-vn` 直接丢流不解码）、mov/alac、
avi/mp3、flv/aac、mpegts/aac·ac3·eac3、mpegps/mp2、asf/wmav2、mp3、adts aac、flac、ogg/vorbis、
ogg/opus、aiff、au、caf、w64、amr。

未覆盖（本机无法产出样本，但白名单里已启用）：RealMedia/`cook`、`sipr`、`atrac3/atrac3p`、
`dca`、`wmalossless` 等。需要时往 `fixtures/` 丢一个同类文件，验收会自动带上它。
