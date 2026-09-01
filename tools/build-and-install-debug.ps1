$ProjectRoot = Resolve-Path "$PSScriptRoot\.."
Set-Location $ProjectRoot

$AarPath = Join-Path $ProjectRoot "app\libs\libbox.aar"

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "     Sing-box for Android [Debug 调试版] 一键编译与安装工具      " -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan

# 1. 检查核心库是否存在
if (-not (Test-Path $AarPath)) {
    Write-Host "[!] 未检测到 app/libs/libbox.aar 核心库！" -ForegroundColor Red
    Write-Host "[*] 请先运行 .\tools\update-to-latest-sing-box\update-sing-box-core.ps1 下载最新核心库后再次编译。" -ForegroundColor Yellow
    exit 1
}

# 2. 编译前配置规范与规则集深度诊断体检
& "$PSScriptRoot\validator\validate-gateway-config.ps1"
if ($LASTEXITCODE -ne 0) {
    Write-Host "`n[✖] 编译前配置深度体检未通过，已终止编译！" -ForegroundColor Red
    exit 1
}

# 3. 执行本地 Gradle 编译 (assembleOtherDebug)
Write-Host "`n[*] 开始执行 Debug 编译 (assembleOtherDebug)..." -ForegroundColor Yellow
$startTime = Get-Date

& .\gradlew.bat assembleOtherDebug
if ($LASTEXITCODE -ne 0) {
    Write-Host "`n[✖] Debug 编译失败，请查看上方的 Gradle 错误信息。" -ForegroundColor Red
    exit 1
}

$elapsed = [Math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)
Write-Host ("`n[✔] Debug 编译成功！耗时: " + $elapsed + " 秒") -ForegroundColor Green

# 4. 查找生成的 Debug APK
$apkPath = Get-ChildItem -Path "$ProjectRoot\app\build\outputs\apk\other\debug\*arm64-v8a-debug.apk" | Select-Object -First 1
if (-not $apkPath) {
    $apkPath = Get-ChildItem -Path "$ProjectRoot\app\build\outputs\apk\other\debug\*.apk" | Select-Object -First 1
}

if (-not $apkPath) {
    Write-Host "[!] 未找到生成的 APK 文件，请检查输出目录。" -ForegroundColor Red
    exit 1
}

$apkSizeMB = [Math]::Round($apkPath.Length / 1MB, 2)
Write-Host (" [+] 安装包位置: " + $apkPath.FullName) -ForegroundColor Green
Write-Host (" [+] 文件大小: " + $apkSizeMB + " MB") -ForegroundColor Green

# 5. 检测并安装到连接的手机
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
    Write-Host ("    您可手动将上述 APK 复制到手机进行安装。") -ForegroundColor Gray
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
    Write-Host "[✔] Debug 应用已在前台启动就绪！" -ForegroundColor Green
    Write-Host "[*] 提示: 可直接运行 .\tools\test-e2e-gateway-routing.ps1 进行全链路分流路由真机实测。" -ForegroundColor Cyan
} else {
    Write-Host "[!] 安装失败，请检查手机是否允许 USB 安装应用权限。" -ForegroundColor Red
}

Write-Host "================================================================" -ForegroundColor Cyan
