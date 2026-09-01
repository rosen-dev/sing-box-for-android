# ======================================================================
# 脚本名称: windows-chrome-auto-whitelist-sniffer.ps1
# 脚本作用: 【Windows 浏览器端】打开指定网站，实时嗅探所有网络请求，捕获被拦截的域名/IP 并更新至白名单
# 存放位置: tools/whitelist-updater/
# 核心特性:
#   1. 自动等待用户输入要访问的目标网址 (支持任何域名/URL)
#   2. 直接拉起浏览器打开网页 (依托 PC Clash Verge TUN 全局走手机网关 192.168.31.100:8899)
#   3. 自动探测 9090 控制接口 (支持本地 127.0.0.1:9090 或局域网 192.168.31.100:9090)
#   4. 用户可自由在网页中操作任意时长，按【Enter 回车键】或【Ctrl + C】结束并一键自愈白名单
# ======================================================================

param(
    [string]$Url = "",
    [switch]$AutoApply,
    [string]$GatewayIp = "192.168.31.100"
)

$ProjectRoot = Resolve-Path "$PSScriptRoot\..\.."
Set-Location $ProjectRoot

$WhitelistYaml = Join-Path $ProjectRoot "app\src\main\assets\gateway_rules\RuleSet_Whitelist.yaml"
$ValidatorScript = Join-Path $ProjectRoot "tools\validator\validate-gateway-config.ps1"

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "   Sing-box Windows 网页访问嗅探与白名单自愈工具               " -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan

# ----------------------------------------------------------------------
# 1. 交互式获取目标网站 URL
# ----------------------------------------------------------------------
if (-not $Url) {
    Write-Host "`n----------------------------------------------------------------" -ForegroundColor Cyan
    $inputUrl = Read-Host "请输入你要嗅探访问的目标网站 URL (例如: onenote.com 或 https://gemini.google.com)"
    $Url = $inputUrl.Trim()
}

if (-not $Url) {
    Write-Host "[!] 未输入任何 URL，脚本已终止。" -ForegroundColor Red
    exit 1
}

# 自动补全 https:// 协议头
if (-not ($Url.StartsWith("http://") -or $Url.StartsWith("https://"))) {
    $Url = "https://" + $Url
}

Write-Host "`n[✔] 目标网站设定 -> $Url" -ForegroundColor Green

# ----------------------------------------------------------------------
# 2. 探测 Sing-box 9090 控制接口 (优先 ADB 映射，其次局域网直连)
# ----------------------------------------------------------------------
Write-Host "`n[*] 正在探测 Sing-box 9090 控制端口通信..." -ForegroundColor Yellow

$adb = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
if (-not (Test-Path $adb)) { $adb = "adb" }
& $adb forward tcp:9090 tcp:9090 2>$null

$apiBase = "http://127.0.0.1:9090"
$apiReady = $false

# 尝试 127.0.0.1:9090
try {
    $wc = New-Object System.Net.WebClient
    $wc.Timeout = 1500
    $vJson = $wc.DownloadString("$apiBase/version")
    $apiReady = $true
    Write-Host " [✔] 成功连接 Sing-box 9090 控制端口 ($apiBase)" -ForegroundColor Green
} catch {
    # 尝试局域网直连 192.168.31.100:9090
    try {
        $apiBase = "http://${GatewayIp}:9090"
        $wc = New-Object System.Net.WebClient
        $wc.Timeout = 1500
        $vJson = $wc.DownloadString("$apiBase/version")
        $apiReady = $true
        Write-Host " [✔] 成功通过局域网连接 Sing-box 9090 控制端口 ($apiBase)" -ForegroundColor Green
    } catch {
        Write-Host " [!] 无法连接到 9090 控制端口。请确保手机 Sing-box 已启动连接。" -ForegroundColor Yellow
        $apiBase = "http://127.0.0.1:9090"
    }
}

# ----------------------------------------------------------------------
# 3. 读取本地已有白名单规则
# ----------------------------------------------------------------------
$knownRules = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$knownCidrs = [System.Collections.Generic.List[string]]::new()

if (Test-Path $WhitelistYaml) {
    $lines = Get-Content $WhitelistYaml -Encoding UTF8
    foreach ($line in $lines) {
        $t = $line.Trim()
        if ($t.StartsWith("- ")) {
            $ruleContent = $t.Substring(2).Trim()
            if ($ruleContent.Contains("#")) {
                $ruleContent = $ruleContent.Substring(0, $ruleContent.IndexOf("#")).Trim()
            }
            $knownRules.Add($ruleContent) | Out-Null
            if ($ruleContent.StartsWith("IP-CIDR,")) {
                $knownCidrs.Add($ruleContent.Substring(8).Trim())
            }
        }
    }
}
Write-Host (" [+] 本地已有白名单规则: " + $knownRules.Count + " 条") -ForegroundColor Gray

# ----------------------------------------------------------------------
# 4. 辅助函数：域名提炼、IP 判断与反查
# ----------------------------------------------------------------------
function Extract-DomainRule([string]$host) {
    if (-not $host -or $host -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
        return $null
    }
    $parts = $host.Split('.')
    if ($parts.Length -ge 2) {
        $suffix = $parts[-2] + "." + $parts[-1]
        if ($parts.Length -ge 3 -and $parts[-2] -in @("com", "net", "org", "gov", "edu", "co")) {
            $suffix = $parts[-3] + "." + $parts[-2] + "." + $parts[-1]
        }
        return "DOMAIN-SUFFIX,$suffix"
    }
    return "DOMAIN,$host"
}

function Is-PrivateIp([string]$ip) {
    if (-not $ip) { return $true }
    if ($ip -match '^(10\.|192\.168\.|127\.|169\.254\.|172\.(1[6-9]|2[0-9]|3[01])\.|0\.|::1|fe80:)') {
        return $true
    }
    return $false
}

function Test-IpInCidr([string]$ipStr, [string]$cidrStr) {
    try {
        $parts = $cidrStr.Split('/')
        $netBytes = [System.Net.IPAddress]::Parse($parts[0]).GetAddressBytes()
        $maskLen = [int]$parts[1]
        $ipBytes = [System.Net.IPAddress]::Parse($ipStr).GetAddressBytes()
        if ($netBytes.Length -ne $ipBytes.Length) { return $false }
        for ($i = 0; $i -lt $netBytes.Length; $i++) {
            if ($maskLen -ge 8) {
                $curMask = 255
                $maskLen -= 8
            } elseif ($maskLen -gt 0) {
                $curMask = (256 - [Math]::Pow(2, 8 - $maskLen))
                $maskLen = 0
            } else {
                $curMask = 0
            }
            if (($netBytes[$i] -band $curMask) -ne ($ipBytes[$i] -band $curMask)) {
                return $false
            }
        }
        return $true
    } catch {
        return $false
    }
}

function Resolve-IpPtrDomain([string]$ip) {
    try {
        $entry = [System.Net.Dns]::GetHostEntry($ip)
        if ($entry -and $entry.HostName -and $entry.HostName -ne $ip) {
            return $entry.HostName
        }
    } catch {}
    return $null
}

# ----------------------------------------------------------------------
# 5. 直接拉起浏览器打开目标网页
# ----------------------------------------------------------------------
Write-Host "`n[*] 正在启动浏览器访问 $Url ..." -ForegroundColor Yellow
Start-Process $Url

# ----------------------------------------------------------------------
# 6. 实时嗅探网络请求 (用户自由操作，随时按 Enter 结束)
# ----------------------------------------------------------------------
Write-Host "`n================================================================" -ForegroundColor Cyan
Write-Host "  [⚡ 雷达监听中] 正在实时捕获该网站触发的所有网络请求..." -ForegroundColor Yellow
Write-Host "  [💡 操作指引] 请在浏览器中自由操作网页（登录/浏览/点击/测试功能）" -ForegroundColor Gray
Write-Host "  [👉 结束方式] 操作完毕后，随时按【Enter 回车键】或【Ctrl + C】结束嗅探！" -ForegroundColor Cyan
Write-Host "================================================================`n" -ForegroundColor Cyan

$discoveredNewRules = [System.Collections.Generic.List[string]]::new()
$seenConnIds = [System.Collections.Generic.HashSet[string]]::new()

try {
    while ($true) {
        # 检查用户是否按下了 Enter / 退出键
        if ([System.Console]::KeyAvailable) {
            $key = [System.Console]::ReadKey($true)
            if ($key.Key -eq 'Enter' -or $key.Key -eq 'Escape' -or $key.KeyChar -in @('q', 'Q')) {
                Write-Host "`n[*] 收到用户结束指令，正在生成本次嗅探汇总报告..." -ForegroundColor Yellow
                break
            }
        }

        try {
            $wc = New-Object System.Net.WebClient
            $wc.Encoding = [System.Text.Encoding]::UTF8
            $connRaw = $wc.DownloadString("$apiBase/connections")
            $connData = $connRaw | ConvertFrom-Json

            $allConns = @()
            if ($connData.connections) { $allConns += $connData.connections }

            foreach ($conn in $allConns) {
                $id = $conn.id
                if ($seenConnIds.Contains($id)) { continue }
                $seenConnIds.Add($id) | Out-Null

                $hostName = $conn.metadata.host
                $destIp = $conn.metadata.destinationIP
                $outbound = if ($conn.chains) { $conn.chains[0] } else { "" }
                $rule = $conn.rule

                $isBlocked = ($outbound -eq "block") -or ($outbound -eq "reject") -or ($rule -match "final" -and $outbound -ne "PROXY" -and $outbound -ne "direct")
                $targetStr = if ($hostName) { $hostName } else { $destIp }
                $timeStr = Get-Date -Format "HH:mm:ss"

                if ($isBlocked) {
                    $suggestedRule = $null
                    $reason = ""
                    $ptrComment = ""

                    # 情况 A：域名被拦截
                    if ($hostName -and $hostName -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
                        Write-Host "[$timeStr ⚡ 域名拦截]" -ForegroundColor Red -NoNewline
                        Write-Host " $hostName" -ForegroundColor Yellow -NoNewline
                        Write-Host " (出站: $outbound, 规则: $rule)" -ForegroundColor DarkGray
                        
                        $suggestedRule = Extract-DomainRule $hostName
                        $reason = "网页关联域名规则"
                    }
                    # 情况 B：纯 IP 被拦截
                    elseif ($destIp) {
                        if (Is-PrivateIp $destIp) { continue }
                        $alreadyCovered = $false
                        foreach ($cidr in $knownCidrs) {
                            if (Test-IpInCidr $destIp $cidr) { $alreadyCovered = $true; break }
                        }
                        if ($alreadyCovered) { continue }

                        Write-Host "[$timeStr ⚡ 纯 IP 拦截]" -ForegroundColor Red -NoNewline
                        Write-Host " $destIp" -ForegroundColor Yellow -NoNewline
                        Write-Host " (出站: $outbound, 规则: $rule)" -ForegroundColor DarkGray

                        $ptrDomain = Resolve-IpPtrDomain $destIp
                        if ($ptrDomain) { $ptrComment = " # PTR: $ptrDomain" }
                        $suggestedRule = "IP-CIDR,$destIp/32"
                        $reason = if ($ptrDomain) { "原始 IP 直通 (PTR: $ptrDomain)" } else { "纯 IP 直通" }
                    }

                    # 判断是否为全新规则
                    if ($suggestedRule -and (-not $knownRules.Contains($suggestedRule)) -and (-not $discoveredNewRules.Contains($suggestedRule))) {
                        $discoveredNewRules.Add($suggestedRule)
                        $ruleWithComment = if ($ptrComment) { $suggestedRule + $ptrComment } else { $suggestedRule }
                        Write-Host "    └─ [💡 推荐自愈规则] " -ForegroundColor Cyan -NoNewline
                        Write-Host $ruleWithComment -ForegroundColor Green -NoNewline
                        Write-Host (" (" + $reason + ")") -ForegroundColor Gray

                        if ($AutoApply) {
                            Add-Content -Path $WhitelistYaml -Value ("  - " + $ruleWithComment) -Encoding UTF8
                            $knownRules.Add($suggestedRule) | Out-Null
                            if ($suggestedRule.StartsWith("IP-CIDR,")) {
                                $knownCidrs.Add($suggestedRule.Substring(8).Trim())
                            }
                            Write-Host "    └─ [✔ 已自动写入] RuleSet_Whitelist.yaml" -ForegroundColor Green
                        }
                    }
                } else {
                    # 正常通过的连接（输出浅色日志）
                    Write-Host "[$timeStr ✔ 正常放行]" -ForegroundColor DarkGray -NoNewline
                    Write-Host " $targetStr" -ForegroundColor DarkCyan -NoNewline
                    Write-Host " -> $outbound" -ForegroundColor DarkGray
                }
            }
        } catch {}

        Start-Sleep -Milliseconds 1200
    }
} finally {
    Write-Host "`n================================================================" -ForegroundColor Cyan
    Write-Host "                   网页访问嗅探汇总报告                          " -ForegroundColor Cyan
    Write-Host "================================================================" -ForegroundColor Cyan

    if ($discoveredNewRules.Count -eq 0) {
        Write-Host " [✔] 访问期间该网站的所有网络请求均已顺畅通行，未发现被拦截项！" -ForegroundColor Green
    } else {
        Write-Host (" [!] 本次共捕获到 " + $discoveredNewRules.Count + " 条被拦截规则:") -ForegroundColor Yellow
        foreach ($r in $discoveredNewRules) {
            Write-Host ("     - " + $r) -ForegroundColor Cyan
        }

        if (-not $AutoApply) {
            Write-Host "`n----------------------------------------------------------------" -ForegroundColor Gray
            $applyChoice = Read-Host "是否立即将上述拦截规则写入 RuleSet_Whitelist.yaml 并执行规范体检？(Y/N)"
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
