$ProjectRoot = Resolve-Path "$PSScriptRoot\.."
Set-Location $ProjectRoot

$AarPath = Join-Path $ProjectRoot "app\libs\libbox.aar"

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "    Sing-box for Android [Release 正式发布版] 一键编译工具       " -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan

# 1. 检查核心库是否存在
if (-not (Test-Path $AarPath)) {
    Write-Host "[!] 未检测到 app/libs/libbox.aar 核心库！" -ForegroundColor Red
    Write-Host "[*] 请先运行 .\tools\update-sing-box-core.ps1 下载最新核心库后再次编译。" -ForegroundColor Yellow
    exit 1
}

# 2. 执行本地 Gradle 正式版编译 (assembleOtherRelease)
Write-Host "[*] 开始执行 Release 正式版编译与 R8 代码混淆优化 (assembleOtherRelease)..." -ForegroundColor Yellow
$startTime = Get-Date

& .\gradlew.bat assembleOtherRelease
if ($LASTEXITCODE -ne 0) {
    Write-Host "`n[✖] Release 编译失败，请查看上方的 Gradle 错误信息。" -ForegroundColor Red
    exit 1
}

$elapsed = [Math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)
Write-Host ("`n[✔] Release 正式版编译成功！耗时: " + $elapsed + " 秒") -ForegroundColor Green

# 3. 查找生成的 Release APK
$apkPath = Get-ChildItem -Path "$ProjectRoot\app\build\outputs\apk\other\release\*arm64-v8a*.apk" | Select-Object -First 1
if (-not $apkPath) {
    $apkPath = Get-ChildItem -Path "$ProjectRoot\app\build\outputs\apk\other\release\*.apk" | Select-Object -First 1
}

if (-not $apkPath) {
    Write-Host "[!] 未找到生成的 Release APK 文件，请检查输出目录。" -ForegroundColor Red
    exit 1
}

$apkSizeMB = [Math]::Round($apkPath.Length / 1MB, 2)
Write-Host (" [+] 正式版安装包: " + $apkPath.FullName) -ForegroundColor Green
Write-Host (" [+] 文件大小: " + $apkSizeMB + " MB (已使用 release.keystore 正式签名)") -ForegroundColor Green

# 4. 检测并安装到连接的手机
Write-Host "`n[*] 正在检测 ADB 连接设备..." -ForegroundColor Yellow
$adbLines = (adb devices 2>$null) -split "`r?`n"
$targetDevice = $null

foreach ($line in $adbLines) {
    if ($line -match '^([^\s]+)\s+device$') {
        $targetDevice = $matches[1].Trim()
        break
    }
}

if (-not $targetDevice) {
    Write-Host "[!] 未检测到已连接的 ADB 手机设备。" -ForegroundColor Yellow
    Write-Host "    您可直接将上述 APK 复制到任何手机上进行正式安装使用。" -ForegroundColor Gray
    Write-Host "================================================================" -ForegroundColor Cyan
    exit 0
}

Write-Host (" [+] 检测到测试手机: " + $targetDevice) -ForegroundColor Green
Write-Host "[*] 正在推送到手机安装..." -ForegroundColor Cyan

adb -s $targetDevice install -r -d "$($apkPath.FullName)"
if ($LASTEXITCODE -eq 0) {
    Write-Host "[✔] 手机覆盖安装成功！" -ForegroundColor Green
    Write-Host "[*] 正在启动应用..." -ForegroundColor Cyan
    adb -s $targetDevice shell am start -n io.nekohasekai.sfa/io.nekohasekai.sfa.compose.MainActivity | Out-Null
    Write-Host "[✔] Release 正式版应用已在前台启动就绪！" -ForegroundColor Green
} else {
    Write-Host "[!] 安装失败，请检查手机是否允许 USB 安装应用权限。" -ForegroundColor Red
}

Write-Host "================================================================" -ForegroundColor Cyan
