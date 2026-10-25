# =============================================================================
# Windows 本地验收脚本（等价于 CI 里 verify.sh 的 Windows 部分）
#   * ffmpeg -version
#   * PE 导入表检查：只允许系统 DLL
#   * 三种实际调用逐个 fixture 冒烟
#   * 体积与目标对比
#
# 用法:
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\ffmpeg-minimal\verify.ps1 `
#       -Binary work\build\win-x64\ffmpeg.exe
# =============================================================================
param(
    [Parameter(Mandatory = $true)][string]$Binary,
    [string]$Fixtures = '',
    [string]$SizeRange = '9-14'
)

# $PSScriptRoot 在 Windows PowerShell 5.1 的 param 默认值里不可用，这里补算
if (-not $Fixtures) { $Fixtures = Join-Path $PSScriptRoot '..\..\fixtures' }

$ErrorActionPreference = 'Stop'
$script:Pass = 0
$script:Fails = 0

function Ok($msg) { $script:Pass++; Write-Host "  PASS $msg" -ForegroundColor Green }
function Bad($msg) { $script:Fails++; Write-Host "  FAIL $msg" -ForegroundColor Red }
function Info($msg) { Write-Host "  ---- $msg" -ForegroundColor Gray }
function Title($msg) { Write-Host "`n$msg" -ForegroundColor Cyan }

# ----------------------------------------------------------------- Pebble: PE 导入表
function Get-PeImports([string]$Path) {
    $fs = [IO.File]::OpenRead($Path)
    try {
        $br = New-Object IO.BinaryReader($fs)
        $fs.Position = 0x3C
        $peOff = $br.ReadUInt32()
        $fs.Position = $peOff
        if ($br.ReadUInt32() -ne 0x4550) { throw "不是有效的 PE 文件: $Path" }
        $null = $br.ReadUInt16()          # machine
        $numSections = $br.ReadUInt16()
        $null = $br.ReadUInt32(); $null = $br.ReadUInt32(); $null = $br.ReadUInt32()
        $sizeOfOptional = $br.ReadUInt16()
        $null = $br.ReadUInt16()          # characteristics
        $optOff = $fs.Position
        $magic = $br.ReadUInt16()
        $dirOff = if ($magic -eq 0x20b) { $optOff + 112 } else { $optOff + 96 }
        $fs.Position = $dirOff + 8        # DataDirectory[1] = Import Table
        $importRva = $br.ReadUInt32()

        $sections = @()
        $fs.Position = $optOff + $sizeOfOptional
        for ($i = 0; $i -lt $numSections; $i++) {
            $null = $br.ReadBytes(8)
            $vsize = $br.ReadUInt32(); $vaddr = $br.ReadUInt32()
            $rawSize = $br.ReadUInt32(); $rawPtr = $br.ReadUInt32()
            $null = $br.ReadBytes(16)
            $sections += [pscustomobject]@{
                VSize = $vsize; VAddr = $vaddr; RawSize = $rawSize; RawPtr = $rawPtr
            }
        }

        function Convert-RvaToOffset($rva) {
            foreach ($s in $sections) {
                $span = [Math]::Max($s.VSize, $s.RawSize)
                if ($rva -ge $s.VAddr -and $rva -lt ($s.VAddr + $span)) {
                    return $s.RawPtr + ($rva - $s.VAddr)
                }
            }
            return $null
        }

        $names = @()
        $off = Convert-RvaToOffset $importRva
        while ($off) {
            $fs.Position = $off
            $origThunk = $br.ReadUInt32(); $null = $br.ReadUInt32(); $null = $br.ReadUInt32()
            $nameRva = $br.ReadUInt32(); $null = $br.ReadUInt32()
            if ($origThunk -eq 0 -and $nameRva -eq 0) { break }
            $nameOff = Convert-RvaToOffset $nameRva
            if ($nameOff) {
                $fs.Position = $nameOff
                $sb = New-Object Text.StringBuilder
                while ($true) {
                    $b = $br.ReadByte()
                    if ($b -eq 0) { break }
                    [void]$sb.Append([char]$b)
                }
                $names += $sb.ToString()
            }
            $off += 20
        }
        return $names | Sort-Object -Unique
    }
    finally {
        $fs.Dispose()
    }
}

# ----------------------------------------------------------------- 执行封装
function Invoke-Ffmpeg {
    param([string[]]$Arguments, [string]$StdOutFile, [string]$StdErrFile)
    $quoted = foreach ($a in $Arguments) {
        $x = $a.Replace('"', '\"')
        if ($x -match '[\s"]') { '"' + $x + '"' } else { $x }
    }
    $cmd = '"' + $Binary + '" ' + ($quoted -join ' ')
    if ($StdOutFile) { $cmd += ' > "' + $StdOutFile + '"' }
    if ($StdErrFile) { $cmd += ' 2> "' + $StdErrFile + '"' }
    $null = cmd /c $cmd
    return $LASTEXITCODE
}

if (-not (Test-Path -LiteralPath $Binary)) { throw "找不到 $Binary" }
$Binary = (Resolve-Path -LiteralPath $Binary).Path
$sizeBytes = (Get-Item -LiteralPath $Binary).Length
$sizeMb = [Math]::Round($sizeBytes / 1MB, 2)

Write-Host "验收: $Binary" -ForegroundColor White
Info "文件大小 : $sizeMb MB ($sizeBytes bytes)"
Info "sha256   : $((Get-FileHash -LiteralPath $Binary -Algorithm SHA256).Hash)"

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("ffmin-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null

try {
    # ------------------------------------------------------------- 1. 版本
    Title '[1/4] ffmpeg -version'
    $verOut = Join-Path $tmp 'version.txt'
    $verErr = Join-Path $tmp 'version.err'
    $code = Invoke-Ffmpeg -Arguments @('-hide_banner', '-version') -StdOutFile $verOut -StdErrFile $verErr
    if ($code -eq 0 -and (Test-Path $verOut)) {
        Ok 'ffmpeg -version 正常退出'
        $first = (Get-Content -LiteralPath $verOut -TotalCount 1)
        Info $first
        $cfg = (Get-Content -LiteralPath $verOut | Where-Object { $_ -like 'configuration:*' } | Select-Object -First 1)
        foreach ($flag in @('--disable-everything', '--disable-gpl', '--disable-nonfree', '--disable-version3', '--disable-swscale', '--disable-avdevice')) {
            # 注：libpostproc 自 FFmpeg 8.0 起已移除，不再有 --disable-postproc
            if ($cfg -and $cfg.Contains($flag)) { Ok "配置含 $flag" } else { Bad "配置缺少 $flag" }
        }
        if ($cfg -and $cfg.Contains('--enable-small')) { Bad '含 --enable-small' } else { Ok '未使用 --enable-small' }
        if ($cfg -and $cfg.Contains('--disable-asm')) { Bad '含 --disable-asm' } else { Ok '未使用 --disable-asm' }
    }
    else {
        Bad "ffmpeg -version 失败: $code"
    }

    # ------------------------------------------------------------- 2. 依赖
    Title '[2/4] 静态依赖（PE 导入表）'
    $imports = Get-PeImports $Binary
    Info ("导入 DLL: " + ($imports -join ' '))
    $allowed = @('kernel32.dll', 'msvcrt.dll', 'user32.dll', 'advapi32.dll', 'shell32.dll', 'bcrypt.dll', 'ntdll.dll', 'ole32.dll')
    $unexpected = $imports | Where-Object {
        $n = $_.ToLower()
        # api-ms-win-* / ext-ms-* 是 Windows 自带 API Set，不算第三方依赖
        ($allowed -notcontains $n) -and ($n -notlike 'api-ms-win-*') -and ($n -notlike 'ext-ms-*')
    }
    if (-not $unexpected) { Ok '只依赖系统 DLL（无第三方运行时依赖）' }
    else { Bad ("存在非系统 DLL 依赖: " + ($unexpected -join ' ')) }

    # ------------------------------------------------------------- 3. 冒烟
    Title '[3/4] 三种实际调用逐个 fixture 冒烟'
    $files = Get-ChildItem -LiteralPath (Resolve-Path $Fixtures) -File | Where-Object { $_.Name -like 'tone*' }
    $pipeOut = Join-Path $tmp 'pipe.wav'
    foreach ($f in $files) {
        $err = Join-Path $tmp 'err.txt'

        # 1) 管道提取
        $code = Invoke-Ffmpeg -Arguments @('-hide_banner', '-loglevel', 'error', '-i', $f.FullName,
            '-vn', '-ac', '1', '-ar', '16000', '-f', 'wav', '-acodec', 'pcm_s16le', '-') `
            -StdOutFile $pipeOut -StdErrFile $err
        $sz = if (Test-Path $pipeOut) { (Get-Item $pipeOut).Length } else { 0 }
        if ($code -eq 0 -and $sz -gt 32000 -and $sz -lt 216000) { Ok "$($f.Name) 管道提取 -> $sz bytes" }
        else { Bad "$($f.Name) 管道提取失败 (exit=$code, $sz bytes): $(Get-Content -LiteralPath $err -TotalCount 1)" }

        # 2) 预转 WAV 文件
        $wavOut = Join-Path $tmp ($f.Name + '.wav')
        $code = Invoke-Ffmpeg -Arguments @('-hide_banner', '-loglevel', 'error', '-y', '-err_detect', 'ignore_err',
            '-fflags', '+discardcorrupt+genpts', '-i', $f.FullName, '-vn', '-ac', '1', '-ar', '16000',
            '-f', 'wav', '-acodec', 'pcm_s16le', $wavOut) -StdErrFile $err
        $sz2 = if (Test-Path $wavOut) { (Get-Item $wavOut).Length } else { 0 }
        if ($code -eq 0 -and $sz2 -gt 32000) { Ok "$($f.Name) 预转 WAV 文件 -> $sz2 bytes" }
        else { Bad "$($f.Name) 预转 WAV 文件失败 (exit=$code)" }

        # 3) 时长探测
        $code = Invoke-Ffmpeg -Arguments @('-hide_banner', '-i', $f.FullName, '-vn', '-f', 'null', '-') `
            -StdOutFile $null -StdErrFile $err
        $dline = Get-Content -LiteralPath $err | Where-Object { $_ -like '*Duration:*' } | Select-Object -First 1
        if ($code -eq 0 -and $dline) {
            $val = [regex]::Match($dline, 'Duration: *([0-9:.]+)').Groups[1].Value
            # AMR 等容器本身没有时长元数据，Duration: N/A 属预期
            if ($val -like '*:*') { Ok "$($f.Name) 时长探测 -> $val" }
            else { Ok "$($f.Name) 时长探测 -> N/A（容器无时长元数据，符合预期）" }
        }
        else { Bad "$($f.Name) 时长探测失败" }
    }

    # ------------------------------------------------------------- 4. 体积
    Title '[4/4] 体积与目标对比'
    $lo, $hi = $SizeRange -split '-'
    # 目标区间是"上限"约束：超出失败；比下限更小只是更好
    if ($sizeMb -le ([double]$hi * 1.15)) {
        if ($sizeMb -lt [double]$lo) { Ok "体积 $sizeMb MB 小于目标区间 $SizeRange MB（更小，符合预期）" }
        else { Ok "体积 $sizeMb MB 在目标区间 $SizeRange MB 内" }
    }
    else { Bad "体积 $sizeMb MB 超出目标上限 $hi MB（+15% 容差）" }
}
finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "`n结果: $script:Pass 项通过, $script:Fails 项失败" -ForegroundColor White
if ($script:Fails -gt 0) { exit 1 }
