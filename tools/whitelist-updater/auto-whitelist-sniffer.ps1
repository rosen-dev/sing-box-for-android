# ======================================================================
# 脚本名称: auto-whitelist-sniffer.ps1
# 脚本作用: 实时嗅探指定 App 的网络活动，自动捕获被 Sing-box 拦截的域名/IP 并更新至白名单
# 存放位置: tools/whitelist-updater/
# ======================================================================

param(
    [string]$PackageName = "",
    [switch]$AutoApply,
    [int]$IntervalSeconds = 3
)

$ProjectRoot = Resolve-Path "$PSScriptRoot\..\.."
Set-Location $ProjectRoot

$WhitelistYaml = Join-Path $ProjectRoot "app\src\main\assets\gateway_rules\RuleSet_Whitelist.yaml"
$ValidatorScript = Join-Path $ProjectRoot "tools\validator\validate-gateway-config.ps1"

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "     Sing-box 应用网络活动实时嗅探与白名单自愈工具               " -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan

# ----------------------------------------------------------------------
# 1. 交互式确认目标检测的应用包名 (Package Name)
# ----------------------------------------------------------------------
if (-not $PackageName) {
    Write-Host "`n[*] 正在检测已连接的 ADB 设备及已安装的第三方应用..." -ForegroundColor Yellow
    $deviceOutput = (adb devices 2>$null) -split "`r?`n" | Where-Object { $_ -match '\tdevice$' }
    if (-not $deviceOutput) {
        Write-Host "[!] 未检测到连接的 Android 手机，请确保已开启 USB 调试并连接手机。" -ForegroundColor Red
    } else {
        Write-Host " [+] 检测到 ADB 手机已在线。" -ForegroundColor Green
        # 尝试列出部分第三方包名作为参考
        $pkgList = (adb shell pm list packages -3 2>$null) -replace '^package:', '' | Select-Object -First 15
        if ($pkgList) {
            Write-Host " [+] 手机上安装的部分第三方应用参考:" -ForegroundColor Gray
            $pkgList | ForEach-Object { Write-Host ("     ├─ " + $_) -ForegroundColor DarkGray }
        }
    }

    Write-Host "`n----------------------------------------------------------------" -ForegroundColor Cyan
    $inputPkg = Read-Host "请输入你要检测的应用包名或关键字 (例如: com.microsoft.office.onenote 或 onenote，留空则监听全局被拦截流量)"
    $PackageName = $inputPkg.Trim()
}

$filterMsg = if ($PackageName) { "目标应用包名/关键字: [$PackageName]" } else { "全局所有被拦截的应用流量" }
Write-Host "`n[✔] 嗅探目标设定 -> $filterMsg" -ForegroundColor Green

# ----------------------------------------------------------------------
# 2. 打通 ADB 端口转发 (Clash REST API 9090 端口)
# ----------------------------------------------------------------------
Write-Host "`n[*] 正在打通手机 Sing-box 9090 控制端口映射 (adb forward)..." -ForegroundColor Yellow
& adb forward tcp:9090 tcp:9090 2>$null

$testApi = "http://127.0.0.1:9090/version"
$apiReady = $false
try {
    $wc = New-Object System.Net.WebClient
    $wc.Timeout = 2000
    $vJson = $wc.DownloadString($testApi)
    $apiReady = $true
    Write-Host " [✔] 手机 Sing-box Clash REST API 通信正常！" -ForegroundColor Green
} catch {
    Write-Host " [!] 无法连接到手机上的 9090 端口。请确认手机上 Sing-box 网关服务已启动开启！" -ForegroundColor Yellow
}

# ----------------------------------------------------------------------
# 3. 读取本地白名单已有规则（防止重复添加）
# ----------------------------------------------------------------------
function Get-ExistingRules {
    $existing = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if (Test-Path $WhitelistYaml) {
        $lines = Get-Content $WhitelistYaml -Encoding UTF8
        foreach ($line in $lines) {
            $t = $line.Trim()
            if ($t.StartsWith("- ")) {
                $ruleContent = $t.Substring(2).Trim()
                if ($ruleContent.Contains("#")) {
                    $ruleContent = $ruleContent.Substring(0, $ruleContent.IndexOf("#")).Trim()
                }
                $existing.Add($ruleContent) | Out-Null
            }
        }
    }
    return $existing
}

$knownRules = Get-ExistingRules
Write-Host (" [+] 本地 RuleSet_Whitelist.yaml 已有规则: " + $knownRules.Count + " 条") -ForegroundColor Gray

# ----------------------------------------------------------------------
# 4. 智能提取域名后缀辅助函数
# ----------------------------------------------------------------------
function Extract-DomainRule([string]$host) {
    if (-not $host -or $host -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
        return $null
    }
    $parts = $host.Split('.')
    if ($parts.Length -ge 2) {
        # 提取根域名 / 主域名
        $suffix = $parts[-2] + "." + $parts[-1]
        # 处理常见二级后缀 (如 .com.cn, .co.uk 等)
        if ($parts.Length -ge 3 -and $parts[-2] -in @("com", "net", "org", "gov", "edu", "co")) {
            $suffix = $parts[-3] + "." + $parts[-2] + "." + $parts[-1]
        }
        return "DOMAIN-SUFFIX,$suffix"
    }
    return "DOMAIN,$host"
}

# ----------------------------------------------------------------------
# 5. 循环嗅探与实时捕获
# ----------------------------------------------------------------------
Write-Host "`n================================================================" -ForegroundColor Cyan
Write-Host "  开始实时嗅探... 请在手机上操作 $filterMsg" -ForegroundColor Yellow
Write-Host "  (按 Ctrl + C 可随时退出并生成本次拦截报告)" -ForegroundColor Gray
Write-Host "================================================================`n" -ForegroundColor Cyan

$discoveredNewRules = [System.Collections.Generic.List[string]]::new()
$seenConnIds = [System.Collections.Generic.HashSet[string]]::new()

try {
    while ($true) {
        try {
            $wc = New-Object System.Net.WebClient
            $wc.Encoding = [System.Text.Encoding]::UTF8
            $connRaw = $wc.DownloadString("http://127.0.0.1:9090/connections")
            $connData = $connRaw | ConvertFrom-Json

            $allConns = @()
            if ($connData.connections) { $allConns += $connData.connections }

            foreach ($conn in $allConns) {
                $id = $conn.id
                if ($seenConnIds.Contains($id)) { continue }
                $seenConnIds.Add($id) | Out-Null

                $hostName = $conn.metadata.host
                $destIp = $conn.metadata.destinationIP
                $process = $conn.metadata.processPath
                $outbound = if ($conn.chains) { $conn.chains[0] } else { "" }
                $rule = $conn.rule

                # 过滤包名匹配
                $matchApp = $true
                if ($PackageName) {
                    $matchApp = ($process -match $PackageName) -or ($hostName -match $PackageName)
                }

                # 判定是否被拦截 (outbound 为 block/reject 或 rule 为 final 且未放行)
                $isBlocked = ($outbound -eq "block") -or ($outbound -eq "reject") -or ($rule -match "final" -and $outbound -ne "PROXY" -and $outbound -ne "direct")

                if ($matchApp -and $isBlocked) {
                    $targetStr = if ($hostName) { $hostName } else { $destIp }
                    $suggestedRule = if ($hostName) { Extract-DomainRule $hostName } else { "IP-CIDR,$destIp/32" }

                    $timeStr = Get-Date -Format "HH:mm:ss"
                    Write-Host "[$timeStr ⚡ 捕获拦截]" -ForegroundColor Red -NoNewline
                    Write-Host " 目标: " -ForegroundColor Gray -NoNewline
                    Write-Host $targetStr -ForegroundColor Yellow -NoNewline
                    Write-Host " (出站: $outbound, 规则: $rule)" -ForegroundColor DarkGray

                    if ($suggestedRule -and (-not $knownRules.Contains($suggestedRule)) -and (-not $discoveredNewRules.Contains($suggestedRule))) {
                        $discoveredNewRules.Add($suggestedRule)
                        Write-Host "    └─ [💡 推荐白名单规则] " -ForegroundColor Cyan -NoNewline
                        Write-Host $suggestedRule -ForegroundColor Green

                        if ($AutoApply) {
                            Add-Content -Path $WhitelistYaml -Value ("  - " + $suggestedRule) -Encoding UTF8
                            $knownRules.Add($suggestedRule) | Out-Null
                            Write-Host "    └─ [✔ 已自动写入] app/src/main/assets/gateway_rules/RuleSet_Whitelist.yaml" -ForegroundColor Green
                        }
                    }
                }
            }
        } catch {
            # 网络请求偶发异常静默忽略
        }

        Start-Sleep -Seconds $IntervalSeconds
    }
} finally {
    Write-Host "`n`n================================================================" -ForegroundColor Cyan
    Write-Host "                      嗅探会话结束报告                           " -ForegroundColor Cyan
    Write-Host "================================================================" -ForegroundColor Cyan

    if ($discoveredNewRules.Count -eq 0) {
        Write-Host " [✔] 嗅探期间未发现新的被拦截流量，当前白名单已完全满足需求！" -ForegroundColor Green
    } else {
        Write-Host (" [!] 本次共捕获到 " + $discoveredNewRules.Count + " 条被拦截规则:") -ForegroundColor Yellow
        foreach ($r in $discoveredNewRules) {
            Write-Host ("     - " + $r) -ForegroundColor Cyan
        }

        if (-not $AutoApply) {
            Write-Host "`n----------------------------------------------------------------" -ForegroundColor Gray
            $applyChoice = Read-Host "是否立即将上述规则写入 RuleSet_Whitelist.yaml 并执行规范体检？(Y/N)"
            if ($applyChoice -match '^[Yy]') {
                foreach ($r in $discoveredNewRules) {
                    Add-Content -Path $WhitelistYaml -Value ("  - " + $r) -Encoding UTF8
                }
                Write-Host " [✔] 规则已成功追加至 RuleSet_Whitelist.yaml！" -ForegroundColor Green

                if (Test-Path $ValidatorScript) {
                    Write-Host "`n[*] 正在自动执行编译前双层规范体检..." -ForegroundColor Yellow
                    & $ValidatorScript
                }
            }
        } else {
            if (Test-Path $ValidatorScript) {
                Write-Host "`n[*] 正在自动执行编译前双层规范体检..." -ForegroundColor Yellow
                & $ValidatorScript
            }
        }
    }
    Write-Host "================================================================" -ForegroundColor Cyan
}
