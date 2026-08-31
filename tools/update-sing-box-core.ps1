# ==============================================================================
# update-sing-box-core.ps1
# 功能：一键从 GitHub Releases 直链下载最新编译好的 libbox.aar 并覆盖到 app/libs/
# ==============================================================================

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

$ProjectRoot = Resolve-Path "$PSScriptRoot\.."
Set-Location $ProjectRoot

$DestDir = Join-Path $ProjectRoot "app\libs"
$DestFile = Join-Path $DestDir "libbox.aar"
$DownloadUrl = "https://github.com/rosen-dev/sing-box-for-android/releases/download/core-latest/libbox.aar"

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "            Sing-box Go 核心 (libbox.aar) 一键同步工具           " -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan

# 确保目标目录存在
if (-not (Test-Path $DestDir)) {
    New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
}

Write-Host "[*] 正在从 GitHub Releases 获取最新 libbox.aar 直链..." -ForegroundColor Yellow
Write-Host "    下载地址: $DownloadUrl" -ForegroundColor Gray

# 使用 .NET WebClient 实现带进度的极速下载
try {
    $wc = New-Object System.Net.WebClient
    $wc.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64)")
    
    $tempFile = "$DestFile.download"
    if (Test-Path $tempFile) { Remove-Item $tempFile -Force }

    Write-Host "[*] 正在高速下载中 (约 117MB)，请稍候..." -ForegroundColor Cyan
    $wc.DownloadFile($DownloadUrl, $tempFile)

    # 校验下载文件大小
    $downloadSize = (Get-Item $tempFile).Length
    if ($downloadSize -lt 10000000) { # 小于 10MB 说明可能下载到了 404 错误页
        $content = Get-Content $tempFile -Raw -ErrorAction SilentlyContinue
        Remove-Item $tempFile -Force
        throw "下载的文件大小异常 (${downloadSize} 字节)，可能 Release 中尚未生成文件。返回内容: $content"
    }

    # 覆盖正式文件
    Move-Item -Path $tempFile -Destination $DestFile -Force
    $sizeMB = [Math]::Round($downloadSize / 1MB, 2)

    Write-Host "`n[✔] 下载并更新成功！" -ForegroundColor Green
    Write-Host "    已保存至: $DestFile ($sizeMB MB)" -ForegroundColor Green
    Write-Host "================================================================" -ForegroundColor Cyan
    Write-Host "【提示】您现在可以直接运行 .\tools\build-and-install-debug.ps1 进行本地编译测试。" -ForegroundColor Yellow
} catch {
    Write-Host "`n[✖] 下载失败: $_" -ForegroundColor Red
    Write-Host "【可能原因】" -ForegroundColor Yellow
    Write-Host "1. GitHub Actions 尚未完成首次 Release 发布（请前往 Actions 页面确认）；" -ForegroundColor Gray
    Write-Host "2. 网络连接波动，请检查网络后重试。" -ForegroundColor Gray
    exit 1
}
