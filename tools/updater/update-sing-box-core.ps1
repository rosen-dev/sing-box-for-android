param(
    [switch]$Force
)

$ProjectRoot = Resolve-Path "$PSScriptRoot\..\.."
Set-Location $ProjectRoot

$DestDir = Join-Path $ProjectRoot "app\libs"
$DestFile = Join-Path $DestDir "libbox.aar"
$VersionFile = Join-Path $DestDir "core-version.txt"
$DownloadUrl = "https://github.com/rosen-dev/sing-box-for-android/releases/download/core-latest/libbox.aar"

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "    Sing-box Go 核心库 (libbox.aar) 自动化同步工具             " -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan

# 1. 确保目录存在
if (-not (Test-Path $DestDir)) {
    New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
}

# 2. 查询官方 SagerNet/sing-box 最新 Release 版本
$apiUrl = "https://api.github.com/repos/SagerNet/sing-box/releases/latest"
Write-Host "[*] 正在查询官方 sing-box 核心最新版本信息..." -ForegroundColor Yellow

$remoteTag = $null
try {
    $headers = @{ "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" }
    $resp = Invoke-RestMethod -Uri $apiUrl -Headers $headers -TimeoutSec 10
    $remoteTag = $resp.tag_name
    Write-Host ("[+] 官方最新核心版本为: " + $remoteTag) -ForegroundColor Green
} catch {
    Write-Host "[-] 无法连接 GitHub API 查询最新版本号，将通过预编译产物直接同步。" -ForegroundColor Gray
}

# 3. 检查本地已有版本
$localVersion = ""
if (Test-Path $VersionFile) {
    $localVersion = (Get-Content $VersionFile -Raw).Trim()
}

$needDownload = $false
if ($Force) {
    Write-Host "[*] 检测到 -Force 参数，强制重新下载核心库..." -ForegroundColor Yellow
    $needDownload = $true
} elseif (-not (Test-Path $DestFile)) {
    Write-Host "[*] 本地未找到 libbox.aar 核心库，开始下载..." -ForegroundColor Yellow
    $needDownload = $true
} elseif ($remoteTag -and $localVersion -eq $remoteTag) {
    Write-Host ("[✔] 当前本地核心已是最新版本 (" + $localVersion + ")，无需重复下载！") -ForegroundColor Green
    
    # 自动联动执行配置兼容性诊断
    Write-Host "`n[*] 正在联动执行网关配置与规则集规范诊断..." -ForegroundColor Yellow
    & "$PSScriptRoot\..\validate-gateway-config.ps1"
    exit 0
} else {
    if ($localVersion) {
        Write-Host ("[*] 检测到新核心版本: 本地 (" + $localVersion + ") -> 远程 (" + $remoteTag + ")，开始更新...") -ForegroundColor Yellow
    } else {
        Write-Host ("[*] 本地缺少版本记录，开始同步最新核心 (" + $remoteTag + ")...") -ForegroundColor Yellow
    }
    $needDownload = $true
}

# 4. 下载最新预编译 libbox.aar
Write-Host "[*] 正在从 GitHub Releases 下载预编译 core-latest 产物..." -ForegroundColor Yellow
try {
    Write-Host ("    下载地址: " + $DownloadUrl) -ForegroundColor Gray
    
    $wc = New-Object System.Net.WebClient
    $wc.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64)")
    $tempFile = "$DestFile.tmp"
    if (Test-Path $tempFile) { Remove-Item $tempFile -Force }
    
    $wc.DownloadFile($DownloadUrl, $tempFile)
    
    $downloadSize = (Get-Item $tempFile).Length
    if ($downloadSize -lt 10000000) {
        $msg = Get-Content $tempFile -Raw -ErrorAction SilentlyContinue
        Remove-Item $tempFile -Force
        throw ("下载的文件大小异常 (" + $downloadSize + " 字节)，可能 Release 尚未构建完成。返回内容: " + $msg)
    }

    Move-Item -Path $tempFile -Destination $DestFile -Force
    $sizeMB = [Math]::Round((Get-Item $DestFile).Length / 1MB, 2)
    
    Write-Host "`n[✔] 核心库下载并更新成功！" -ForegroundColor Green
    Write-Host ("    已保存至: " + $DestFile + " (" + $sizeMB + " MB)") -ForegroundColor Green
    
    if ($remoteTag) {
        Set-Content -Path $VersionFile -Value $remoteTag -Force
        Write-Host ("    核心版本标记已更新为: " + $remoteTag) -ForegroundColor Green
    }
    Write-Host "================================================================" -ForegroundColor Cyan

    # 自动联动执行配置兼容性诊断
    Write-Host "`n[*] 正在联动执行网关配置与规则集规范诊断..." -ForegroundColor Yellow
    & "$PSScriptRoot\..\validate-gateway-config.ps1"
} catch {
    Write-Host "`n[✖] 核心库同步失败: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "【可能原因】" -ForegroundColor Yellow
    Write-Host "1. GitHub Actions 尚未完成该版本的 Release 构建（请在 GitHub Actions 页面查看）；" -ForegroundColor Gray
    Write-Host "2. 网络连接波动，请检查代理或重试。" -ForegroundColor Gray
    Write-Host "================================================================" -ForegroundColor Cyan
    exit 1
}
