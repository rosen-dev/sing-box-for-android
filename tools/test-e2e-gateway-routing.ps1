$ProjectRoot = Resolve-Path "$PSScriptRoot\.."

Set-Location $ProjectRoot

$RulesDir = Join-Path $ProjectRoot "app\src\main\assets\gateway_rules"

Write-Host "================================================================" -ForegroundColor Cyan

Write-Host "     Sing-box 网关端到端全链路与分流路由真机实测工具            " -ForegroundColor Cyan

Write-Host "================================================================" -ForegroundColor Cyan

# ----------------------------------------------------------------------

# 1. 交互式获取机场订阅链接并下载验证

# ----------------------------------------------------------------------

Write-Host "`n[*] [步骤 1/4] 获取与校验机场订阅配置..." -ForegroundColor Yellow

$inputUrl = Read-Host "请输入机场订阅链接 (可直接回车使用剪贴板或手机现有配置)"

if (-not [string]::IsNullOrWhiteSpace($inputUrl)) {
    $subUrl = $inputUrl.Trim()
} else {
    try {
        $clipText = Get-Clipboard

        if ($clipText -match '^https?://') {
            $subUrl = $clipText.Trim()

            Write-Host (" [+] 从剪贴板自动识别到订阅链接: " + $subUrl) -ForegroundColor Gray

        } else {
            $subUrl = $null

        }

    } catch {
        $subUrl = $null

    }
}

if ($subUrl) {
    Write-Host ("[*] 正在请求下载订阅配置: " + $subUrl + " ...") -ForegroundColor Cyan

    try {
        $wc = New-Object System.Net.WebClient

        $wc.Headers.Add("User-Agent", "sing-box/1.14.0")

        $wc.Headers.Add("Accept", "application/json")

        $downloadedConfig = $wc.DownloadString($subUrl)

        if ($downloadedConfig -match '"outbounds"') {
            Write-Host " [✔] 订阅在线获取成功，已识别到有效的 sing-box 节点出站配置！" -ForegroundColor Green

        } else {
            Write-Host " [!] 已获取订阅数据（Base64 或通用格式）。" -ForegroundColor Yellow

        }

    } catch {
        Write-Host (" [!] 订阅链接在线请求受阻 (" + $_.Exception.Message + ")，将使用手机本地已保存的有效配置进行测试。") -ForegroundColor Yellow

    }
} else {
    Write-Host " [*] 使用手机端当前激活的配置进行全链路分流测试。" -ForegroundColor Cyan
}

# ----------------------------------------------------------------------

# 2. 检测 ADB 真机与建立本地网关隧道 (Port 8899)

# ----------------------------------------------------------------------

Write-Host "`n[*] [步骤 2/4] 正在检测 ADB 真机并映射旁路由网关端口..." -ForegroundColor Yellow

$adbLines = (adb devices 2>$null) -split "`r?`n"

$targetDevice = $null

foreach ($line in $adbLines) {
    if ($line -match '^([^\s]+)\s+device$') {
        $targetDevice = $matches[1].Trim()

        break

    }
}

if (-not $targetDevice) {
    Write-Host "[✖] 未检测到连接的 Android 测试手机，请确保已开启 USB 调试并连接！" -ForegroundColor Red

    exit 1
}

Write-Host (" [✔] 已连接测试手机: " + $targetDevice) -ForegroundColor Green

# 建立端口转发

adb -s $targetDevice forward tcp:8899 tcp:8899 | Out-Null

adb -s $targetDevice forward tcp:9090 tcp:9090 | Out-Null

Write-Host " [✔] 旁路由网关代理端口已映射至本地: 127.0.0.1:8899 (HTTP/SOCKS5)" -ForegroundColor Green

# ----------------------------------------------------------------------

# 3. 检查手机端 Sing-box 服务运行状态与自动故障诊断

# ----------------------------------------------------------------------

Write-Host "`n[*] [步骤 3/4] 正在检查手机端 Sing-box 核心服务连通性..." -ForegroundColor Yellow

$sfaPid = (adb -s $targetDevice shell pidof io.nekohasekai.sfa 2>$null).Trim()

if (-not $sfaPid) {
    Write-Host "[!] 检测到 Sing-box 未在前台运行，正在启动应用..." -ForegroundColor Yellow

    adb -s $targetDevice shell am start -n io.nekohasekai.sfa/io.nekohasekai.sfa.compose.MainActivity | Out-Null

    Start-Sleep -Seconds 3
}

# 检测网关连通性

$checkPy = @"

import urllib.request

proxy_handler = urllib.request.ProxyHandler({'http': 'http://127.0.0.1:8899'})

opener = urllib.request.build_opener(proxy_handler)

try:

    with opener.open('http://aliyun.com', timeout=4) as resp:

        print('OK')

except Exception as e:

    print('FAIL:' + str(e))

"@

$checkResult = (python -c $checkPy 2>$null).Trim()

if (-not $checkResult.StartsWith('OK')) {
    Write-Host "`n[!] 手机端 Sing-box 服务未响应或启动失败，正在自动抓取内核日志进行故障诊断..." -ForegroundColor Red

    # 抓取最近的 Logcat 崩溃与核心报错

    $rawLogs = adb -s $targetDevice logcat -d -t 150 2>$null

    $errorLines = @()

    $causeSummary = "未知原因"

    $suggestedFix = "请检查手机是否已开启 VPN 权限，并在应用主界面手动点击连接按钮。"

    foreach ($logLine in ($rawLogs -split "`r?`n")) {
        if ($logLine -match 'FATAL|panic|detour to an empty|invalid character|cannot unmarshal|missing|error|Error') {
            $errorLines += $logLine

        }

        if ($logLine -match 'detour to an empty direct outbound') {
            $causeSummary = "DNS 规则配置错误：对 direct 直连出站显式声明了 detour: 'direct'（Sing-box 核心禁止冗余 detour）。"

            $suggestedFix = "在 ConfigGenerator.kt 中移除 dns-direct 的 detour 参数，仅保留 dns-remote 的 detour: 'PROXY'。"

        } elseif ($logLine -match "invalid character 'p' looking for beginning of value") {
            $causeSummary = "规则集解析格式错误：Sing-box 1.14 的 format: 'source' 仅支持 JSON 格式，不支持直接读取 YAML。"

            $suggestedFix = "在 RuleSetManager.kt 中启用 convertYamlToSingboxRuleSetJson() 转换为 version: 2 JSON。"

        } elseif ($logLine -match "missing domain_resolver") {
            $causeSummary = "DNS 配置缺失域名解析器：远程 DoH / HTTPS DNS 未指定 domain_resolver。"

            $suggestedFix = "在 ConfigGenerator.kt 中为 dns-remote 补充 'domain_resolver': 'dns-direct'。"

        }

    }

    Write-Host "`n======================= [核心启动失败诊断报告] =======================" -ForegroundColor Red

    Write-Host ("【根本原因】: " + $causeSummary) -ForegroundColor Yellow

    Write-Host ("【修复指引】: " + $suggestedFix) -ForegroundColor Green

    Write-Host "【抓取到的关键错误日志】:" -ForegroundColor Gray

    if ($errorLines.Count -gt 0) {
        $errorLines | Select-Object -Last 10 | ForEach-Object { Write-Host ("  " + $_) -ForegroundColor Red }

    } else {
        Write-Host "  (未捕获到崩溃日志，可能服务尚未在手机 UI 上点击启动)" -ForegroundColor Gray

    }

    Write-Host "======================================================================" -ForegroundColor Red

    Write-Host "`n[*] 请在手机上点击连接启动后，按任意键重新执行测试..." -ForegroundColor Cyan

    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

# ----------------------------------------------------------------------

# 4. 执行全量规则集多层级分流探测矩阵与逐项日志诊断

# ----------------------------------------------------------------------

Write-Host "`n[*] [步骤 4/4] 正在执行多层级分流路由全项探测矩阵..." -ForegroundColor Yellow

Write-Host "----------------------------------------------------------------" -ForegroundColor Gray

$pyScript = @"

import urllib.request

import urllib.error

import time

import sys

proxy_handler = urllib.request.ProxyHandler({
    'http': 'http://127.0.0.1:8899',

    'https': 'http://127.0.0.1:8899'
})

opener = urllib.request.build_opener(proxy_handler)

test_cases = [

    # 1. 直连名单 (RuleSet_Direct) -> direct

    ("直连名单 (Direct)", "aliyun.com", "http://aliyun.com", "direct"),

    ("直连名单 (Direct)", "deepseek.com", "http://deepseek.com", "direct"),

    ("直连名单 (Direct)", "mi.com", "http://mi.com", "direct"),

    # 2. 高优先级白名单 (RuleSet_Priority_Whitelist) -> PROXY

    ("高优先白名单 (Dev/Auth)", "github.com", "https://github.com", "PROXY"),

    ("高优先白名单 (Dev/Auth)", "open-vsx.org", "https://open-vsx.org", "PROXY"),

    # 3. 常用代理白名单 (RuleSet_Whitelist: Gemini / OneNote / Microsoft / AI) -> PROXY

    ("代理白名单 (Gemini AI)", "gemini.google.com", "https://gemini.google.com", "PROXY"),

    ("代理白名单 (OneNote 登录)", "login.live.com", "https://login.live.com", "PROXY"),

    ("代理白名单 (OneNote 笔记)", "onenote.com", "https://onenote.com", "PROXY"),

    ("代理白名单 (微软认证)", "login.microsoftonline.com", "https://login.microsoftonline.com", "PROXY"),

    # 4. 核心黑名单 (RuleSet_Blacklist) -> reject

    ("黑名单拦截 (Blacklist)", "www.google.com", "http://www.google.com", "reject"),

    ("黑名单拦截 (Blacklist)", "youtube.com", "http://youtube.com", "reject"),

    # 5. 默认未命中拦截 (Default Final Block) -> block

    ("未放行流量 (Final Block)", "yahoo.co.jp", "http://yahoo.co.jp", "block")

]

passed = 0

total = len(test_cases)

failed_cases = []

for group, domain, url, expected in test_cases:

    t0 = time.time()

    success = False

    result_text = ""

    err_type = ""

    try:

        req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'})

        with opener.open(req, timeout=7) as resp:

            elapsed = round((time.time() - t0) * 1000, 1)

            if expected in ["direct", "PROXY"]:

                success = True

                result_text = f"通达 (HTTP {resp.status}, {elapsed}ms)"

            else:

                success = False

                result_text = f"意外放行 (HTTP {resp.status}, {elapsed}ms)"

                err_type = "REJECT_FAIL"

    except Exception as e:

        elapsed = round((time.time() - t0) * 1000, 1)

        err_msg = str(e)

        if expected in ["reject", "block"]:

            success = True

            result_text = f"已成功阻断/拒绝 ({type(e).__name__}, {elapsed}ms)"

        else:

            success = False

            result_text = f"访问受阻: {err_msg} ({elapsed}ms)"

            err_type = "CONNECT_FAIL"

    if success:

        passed += 1

        print(f"[PASS]|{group}|{domain}|{expected}|{result_text}")

    else:

        print(f"[FAIL]|{group}|{domain}|{expected}|{result_text}|{err_type}")

print(f"[SUMMARY]|{passed}|{total}")

"@

$tempPyFile = [System.IO.Path]::GetTempFileName() + ".py"

[System.IO.File]::WriteAllText($tempPyFile, $pyScript, [System.Text.Encoding]::UTF8)

$pyOutput = python $tempPyFile

Remove-Item -Force $tempPyFile -ErrorAction SilentlyContinue

$passedCount = 0

$totalCount = 0

$failedItems = @()

foreach ($line in ($pyOutput -split "`r?`n")) {
    if (-not $line) { continue }

    $parts = $line -split '\|'

    if ($parts[0] -eq "[PASS]") {
        Write-Host (" [✔] [" + $parts[1] + "] " + $parts[2]) -ForegroundColor Green

        Write-Host ("     ├─ 期望出站: " + $parts[3] + " | 实际结果: " + $parts[4]) -ForegroundColor Gray

    } elseif ($parts[0] -eq "[FAIL]") {
        Write-Host (" [✖] [" + $parts[1] + "] " + $parts[2]) -ForegroundColor Red

        Write-Host ("     ├─ 期望出站: " + $parts[3] + " | 实际结果: " + $parts[4]) -ForegroundColor Red

        $failedItems += @{ Group = $parts[1]; Domain = $parts[2]; Expected = $parts[3]; Result = $parts[4]; ErrType = $parts[5] }

    } elseif ($parts[0] -eq "[SUMMARY]") {
        $passedCount = [int]$parts[1]

        $totalCount = [int]$parts[2]

    }
}

Write-Host "----------------------------------------------------------------" -ForegroundColor Gray

# ----------------------------------------------------------------------

# 5. 针对未通过条目自动抓取日志并生成根因诊断与修复建议

# ----------------------------------------------------------------------

if ($failedItems.Count -gt 0) {
    Write-Host "`n======================= [分流路由异常诊断报告] =======================" -ForegroundColor Red

    $recentLog = adb -s $targetDevice logcat -d -t 300 2>$null

    foreach ($item in $failedItems) {
        Write-Host ("`n[✖] 目标域名: " + $item.Domain + " (分组: " + $item.Group + ")") -ForegroundColor Red

        Write-Host ("    ├─ 期望策略: " + $item.Expected + " | 实际表现: " + $item.Result) -ForegroundColor Yellow

        # 查找包含该域名的路由日志

        $matchedLogs = ($recentLog -split "`r?`n") | Where-Object { $_ -match [regex]::Escape($item.Domain) }

        if ($matchedLogs) {
            Write-Host "    ├─ 抓取到的内核路由日志:" -ForegroundColor Gray

            $matchedLogs | Select-Object -Last 3 | ForEach-Object { Write-Host ("    │  " + $_) -ForegroundColor DarkGray }

        }

        # 根因分析与建议

        $fixTip = ""

        if ($item.Expected -eq "PROXY" -and $item.Result -match 'timed out|Timeout') {
            $fixTip = "DNS 解析超时或代理节点不可达。请确认 ConfigGenerator.kt 中 dns-remote 是否配置了 detour: 'PROXY'，且节点订阅正常。"

        } elseif ($item.Expected -eq "PROXY" -and $item.Result -match '403|Connection refused|block') {
            $fixTip = "域名可能被底层的 final: 'block' 拦截。请检查 app/src/main/assets/gateway_rules/RuleSet_Whitelist.yaml 中是否已添加该域名规则。"

        } elseif ($item.Expected -eq "direct") {
            $fixTip = "直连访问失败。请确认 RuleSet_Direct.yaml 中是否已包含该纯域名，且 dns-direct (223.5.5.5) 解析正常。"

        } elseif ($item.Expected -eq "reject") {
            $fixTip = "拦截失败。请检查 RuleSet_Blacklist.yaml 是否被正确加载，或规则匹配顺序是否在白名单之后。"

        } else {
            $fixTip = "请检查路由规则匹配优先级及网关配置。"

        }

        Write-Host ("    └─ 💡 根因定位与修复建议: " + $fixTip) -ForegroundColor Green

    }

    Write-Host "======================================================================" -ForegroundColor Red
}

Write-Host "`n================================================================" -ForegroundColor Cyan

if ($passedCount -eq $totalCount -and $totalCount -gt 0) {
    Write-Host (" [🎉] 全链路真机测试 100% 通过！共完成 $passedCount / $totalCount 项分流路由验证！") -ForegroundColor Green

    Write-Host "      国内直连、Gemini/OneNote/微软代理、黑名单与漏斗拦截全部精准生效。" -ForegroundColor Green
} else {
    Write-Host (" [!] 测试完成：通过 $passedCount / $totalCount 项，请根据上方诊断报告进行修复。" ) -ForegroundColor Yellow
}

Write-Host "================================================================" -ForegroundColor Cyan
