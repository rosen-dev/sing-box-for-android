# ======================================================================
# 脚本名称: download-sing-box-cli.ps1
# 脚本作用: 从官方 SagerNet/sing-box 仓库独立下载/更新 Windows CLI 命令行工具 (sing-box.exe)
# 存放位置: tools/bin/
# ======================================================================

param(
    [string]$Version = "",
    [switch]$Force
)

$ProjectRoot = Resolve-Path "$PSScriptRoot\..\.."
Set-Location $ProjectRoot

$BinDir = Join-Path $ProjectRoot "tools\bin"
$CliExe = Join-Path $BinDir "sing-box.exe"
$CronetDll = Join-Path $BinDir "libcronet.dll"

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "    Sing-box Windows CLI 命令行工具 (sing-box.exe) 下载与同步   " -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan

# 1. 确保 tools/bin 目录存在
if (-not (Test-Path $BinDir)) {
    New-Item -ItemType Directory -Path $BinDir -Force | Out-Null
}

# 2. 检查本地当前已安装版本
$localVersion = $null
if (Test-Path $CliExe) {
    try {
        $verOutput = (& $CliExe version 2>$null) -split "`r?`n"
        if ($verOutput[0] -match 'sing-box version ([^\s]+)') {
            $localVersion = $matches[1].Trim()
            Write-Host ("[+] 检测到本地已有 CLI 版本: " + $localVersion) -ForegroundColor Gray
        }
    } catch {
        $localVersion = $null
    }
}

# 3. 确定目标下载版本
$targetTag = $Version
if (-not $targetTag) {
    Write-Host "[*] 正在查询官方 SagerNet/sing-box 核心最新 Release 版本..." -ForegroundColor Yellow
    $apiUrl = "https://api.github.com/repos/SagerNet/sing-box/releases/latest"
    try {
        $headers = @{ "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" }
        $resp = Invoke-RestMethod -Uri $apiUrl -Headers $headers -TimeoutSec 10
        $targetTag = $resp.tag_name
        Write-Host ("[+] 官方最新版本为: " + $targetTag) -ForegroundColor Green
    } catch {
        Write-Host "[-] 无法连接 GitHub API 查询最新版本，默认尝试同步 1.14.0" -ForegroundColor Gray
        $targetTag = "v1.14.0"
    }
}

$cleanVersion = $targetTag.TrimStart('v')
$tagWithV = "v" + $cleanVersion

# 4. 判断是否需要下载
if (-not $Force -and (Test-Path $CliExe) -and (Test-Path $CronetDll) -and ($localVersion -eq $cleanVersion)) {
    Write-Host ("`n[✔] 当前本地 CLI 已是最新版本 (" + $localVersion + ")，无需重复下载！") -ForegroundColor Green
    Write-Host "================================================================" -ForegroundColor Cyan
    exit 0
}

# 5. 执行下载与解压
$zipFileName = "sing-box-$cleanVersion-windows-amd64.zip"
$downloadUrl = "https://github.com/SagerNet/sing-box/releases/download/$tagWithV/$zipFileName"
$tempBase = [System.IO.Path]::GetTempPath()
$tempZip = Join-Path $tempBase $zipFileName
$tempExtractDir = Join-Path $tempBase "sing-box-extract-$cleanVersion"

Write-Host ("[*] 正在从官方 GitHub Releases 下载: " + $zipFileName + " ...") -ForegroundColor Yellow
Write-Host ("    下载地址: " + $downloadUrl) -ForegroundColor Gray

try {
    $wc = New-Object System.Net.WebClient
    $wc.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64)")
    if (Test-Path $tempZip) { Remove-Item $tempZip -Force }
    $wc.DownloadFile($downloadUrl, $tempZip)

    Write-Host "[*] 正在解压并提取二进制文件..." -ForegroundColor Yellow
    if (Test-Path $tempExtractDir) { Remove-Item $tempExtractDir -Recurse -Force }
    Expand-Archive -Path $tempZip -DestinationPath $tempExtractDir -Force

    $subFolder = Join-Path $tempExtractDir "sing-box-$cleanVersion-windows-amd64"
    if (-not (Test-Path $subFolder)) {
        $subFolder = (Get-ChildItem -Path $tempExtractDir -Directory | Select-Object -First 1).FullName
    }

    Copy-Item -Path (Join-Path $subFolder "sing-box.exe") -Destination $BinDir -Force
    if (Test-Path (Join-Path $subFolder "libcronet.dll")) {
        Copy-Item -Path (Join-Path $subFolder "libcronet.dll") -Destination $BinDir -Force
    }

    # 清理临时文件
    Remove-Item -Path $tempZip -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $tempExtractDir -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host ("`n[✔] sing-box CLI 工具已成功就绪！") -ForegroundColor Green
    Write-Host ("    位置: " + $CliExe) -ForegroundColor Green
    Write-Host "================================================================" -ForegroundColor Cyan
} catch {
    Write-Host ("`n[✖] 下载或解压失败: " + $_.Exception.Message) -ForegroundColor Red
    Write-Host "【手动指引】您也可以手动将官方 zip 包中的 sing-box.exe 和 libcronet.dll 复制到 tools\bin\ 目录下使用。" -ForegroundColor Yellow
    Write-Host "================================================================" -ForegroundColor Cyan
    exit 1
}
