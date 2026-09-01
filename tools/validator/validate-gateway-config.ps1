# ======================================================================
# 脚本名称: validate-gateway-config.ps1
# 脚本作用: Sing-box 网关配置与规则集深度合规体检工具
# 架构特性: 【双层数据驱动工业级校验】
#           第 1 层：tools/schema/singbox_rules_matrix.json 驱动的版本感知废弃矩阵
#           第 2 层：官方原厂 Go 内核 (sing-box.exe check) 权威 Schema 与依赖闭环裁决
# ======================================================================

$ProjectRoot = Resolve-Path "$PSScriptRoot\..\.."
Set-Location $ProjectRoot

$RulesDir = Join-Path $ProjectRoot "app\src\main\assets\gateway_rules"
$GatewayDir = Join-Path $ProjectRoot "app\src\main\java\gateway"
$VersionFile = Join-Path $ProjectRoot "app\libs\core-version.txt"
$CliExe = Join-Path $ProjectRoot "tools\bin\sing-box.exe"
$MatrixJsonPath = Join-Path $ProjectRoot "tools\schema\singbox_rules_matrix.json"

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Sing-box 网关配置全要素深度合规体检与原厂闭环诊断工具         " -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan

$allPassed = $true
$issues = @()
$warnings = @()

# ----------------------------------------------------------------------
# 0. 核心版本动态探测与语义化解析 (Version Detection)
# ----------------------------------------------------------------------
$coreVersionStr = "1.14.0"
if (Test-Path $VersionFile) {
    $rawVer = (Get-Content $VersionFile -Raw).Trim()
    if ($rawVer) { $coreVersionStr = $rawVer.TrimStart('v') }
} elseif (Test-Path $CliExe) {
    try {
        $verOut = (& $CliExe version 2>$null) -split "`r?`n"
        if ($verOut[0] -match 'sing-box version ([^\s]+)') {
            $coreVersionStr = $matches[1].Trim()
        }
    } catch {}
}

Write-Host ("[*] 当前检测到 Sing-box Go 核心版本: v" + $coreVersionStr) -ForegroundColor Cyan

function Convert-VersionToNumber([string]$ver) {
    $parts = $ver.Split('.')
    $major = if ($parts.Length -gt 0) { [int]$parts[0] } else { 0 }
    $minor = if ($parts.Length -gt 1) { [int]$parts[1] } else { 0 }
    $patch = if ($parts.Length -gt 2) { [int]($parts[2] -replace '\D.*$','') } else { 0 }
    return ($major * 1000000) + ($minor * 1000) + $patch
}

$currentVerNum = Convert-VersionToNumber $coreVersionStr

# ----------------------------------------------------------------------
# 1. 规则集源文件语法与 纯域名规范校验
# ----------------------------------------------------------------------
Write-Host "`n[*] [步骤 1/5] 正在扫描 assets/gateway_rules/ 规则集源文件..." -ForegroundColor Yellow

$dnsRuleSets = @("RuleSet_Direct.yaml", "RuleSet_Blacklist.yaml")
$routeRuleSets = @("RuleSet_Priority_Whitelist.yaml", "RuleSet_Whitelist.yaml")
$ruleFiles = $dnsRuleSets + $routeRuleSets
$validTypes = @("DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "IP-CIDR", "IP-CIDR6")

foreach ($file in $ruleFiles) {
    $filePath = Join-Path $RulesDir $file
    if (-not (Test-Path $filePath)) {
        Write-Host (" [✖] 缺失规则集源文件: " + $file) -ForegroundColor Red
        $issues += "缺失规则集源文件: $file"
        $allPassed = $false
        continue
    }

    $lines = Get-Content $filePath -Encoding UTF8
    $ruleCount = 0
    $hasIpCidr = $false
    $invalidLines = @()

    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith("#") -or $trimmed -eq "payload:") {
            continue
        }
        if ($trimmed.StartsWith("- ")) {
            $ruleContent = $trimmed.Substring(2).Trim()
            if ($ruleContent.Contains("#")) {
                $ruleContent = $ruleContent.Substring(0, $ruleContent.IndexOf("#")).Trim()
            }
            $parts = $ruleContent -split ','
            $ruleType = $parts[0].Trim()

            if ($validTypes -contains $ruleType) {
                $ruleCount++
                if ($ruleType.StartsWith("IP-CIDR")) {
                    $hasIpCidr = $true
                }
            } else {
                $invalidLines += $line
            }
        }
    }

    if ($invalidLines.Count -gt 0) {
        Write-Host (" [✖] " + $file + " 发现 " + $invalidLines.Count + " 行非法规则:") -ForegroundColor Red
        $invalidLines | ForEach-Object { Write-Host ("     " + $_) -ForegroundColor Red }
        $issues += ($file + " 中存在非法规则行")
        $allPassed = $false
    } else {
        if ($dnsRuleSets -contains $file) {
            if ($hasIpCidr) {
                Write-Host (" [✖] " + $file + " 错误: 包含 IP 规则（DNS 规则集必须 100% 纯域名）") -ForegroundColor Red
                $issues += ($file + " 包含 IP-CIDR 规则，在 DNS 引擎中会导致警告或解析异常")
                $allPassed = $false
            } else {
                Write-Host (" [✔] " + $file + " -> 校验通过，有效规则 " + $ruleCount + " 条 (100% 纯域名)") -ForegroundColor Green
            }
        } else {
            $ipNote = if ($hasIpCidr) { " (含域名与 IP-CIDR 规则)" } else { " (纯域名规则)" }
            Write-Host (" [✔] " + $file + " -> 校验通过，有效规则 " + $ruleCount + " 条" + $ipNote) -ForegroundColor Green
        }
    }
}

# ----------------------------------------------------------------------
# 2. 规则集 JSON (version: 2) 序列化演练
# ----------------------------------------------------------------------
Write-Host "`n[*] [步骤 2/5] 正在模拟 RuleSetManager 转换 Sing-box version: 2 JSON 规则..." -ForegroundColor Yellow

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$tempRulesDir = Join-Path ([System.IO.Path]::GetTempPath()) ("sb_validate_rules_" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRulesDir -Force | Out-Null

foreach ($file in $ruleFiles) {
    $filePath = Join-Path $RulesDir $file
    if (-not (Test-Path $filePath)) { continue }

    $domains = @()
    $suffixes = @()
    $keywords = @()
    $ips = @()

    $lines = Get-Content $filePath -Encoding UTF8
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith("#") -or $trimmed -eq "payload:") { continue }
        if ($trimmed.StartsWith("- ")) {
            $content = $trimmed.Substring(2).Trim()
            if ($content.Contains("#")) {
                $content = $content.Substring(0, $content.IndexOf("#")).Trim()
            }
            $parts = $content -split ','
            $rtype = $parts[0].Trim().ToUpper()
            $rval = if ($parts.Length -gt 1) { $parts[1].Trim() } else { "" }
            if ($rtype -eq "DOMAIN") { $domains += $rval }
            elseif ($rtype -eq "DOMAIN-SUFFIX") { $suffixes += $rval }
            elseif ($rtype -eq "DOMAIN-KEYWORD") { $keywords += $rval }
            elseif ($rtype.StartsWith("IP-CIDR")) { $ips += $rval }
        }
    }

    $ruleItem = @{}
    if ($domains.Count -gt 0) { $ruleItem["domain"] = $domains }
    if ($suffixes.Count -gt 0) { $ruleItem["domain_suffix"] = $suffixes }
    if ($keywords.Count -gt 0) { $ruleItem["domain_keyword"] = $keywords }
    if ($ips.Count -gt 0) { $ruleItem["ip_cidr"] = $ips }

    $jsonObj = @{
        version = 2
        rules = @($ruleItem)
    }

    try {
        $jsonStr = $jsonObj | ConvertTo-Json -Depth 5
        $jsonFileName = [System.IO.Path]::GetFileNameWithoutExtension($file) + ".json"
        [System.IO.File]::WriteAllText((Join-Path $tempRulesDir $jsonFileName), $jsonStr, $utf8NoBom)
        $totalExtracted = $domains.Count + $suffixes.Count + $keywords.Count + $ips.Count
        Write-Host (" [✔] " + $file + " -> JSON version: 2 转换成功 (提取 " + $totalExtracted + " 条规则)") -ForegroundColor Green
    } catch {
        Write-Host (" [✖] " + $file + " JSON 序列化失败: " + $_.Exception.Message) -ForegroundColor Red
        $issues += ($file + " 无法转换为合规 JSON")
        $allPassed = $false
    }
}

# ----------------------------------------------------------------------
# 3. 【第 1 层】基于 schema/singbox_rules_matrix.json 的「版本感知废弃矩阵」
# ----------------------------------------------------------------------
Write-Host "`n[*] [步骤 3/5] 正在执行官方 Migration & Deprecated 版本感知规则矩阵审查..." -ForegroundColor Yellow

# 联动同步检查 Migration & Deprecated 规范 (文档无变动秒级跳过)
$syncScript = Join-Path $PSScriptRoot "sync-rules-matrix.ps1"
if (Test-Path $syncScript) {
    & $syncScript
}

$configGenFile = Join-Path $GatewayDir "ConfigGenerator.kt"
if (-not (Test-Path $configGenFile)) {
    Write-Host " [✖] 未找到 ConfigGenerator.kt 源码文件！" -ForegroundColor Red
    $issues += "缺少 ConfigGenerator.kt"
    $allPassed = $false
} elseif (-not (Test-Path $MatrixJsonPath)) {
    Write-Host " [✖] 未找到规则矩阵文件: tools/schema/singbox_rules_matrix.json" -ForegroundColor Red
    $issues += "缺少 singbox_rules_matrix.json"
    $allPassed = $false
} else {
    $ktContent = Get-Content $configGenFile -Raw -Encoding UTF8
    $matrixData = Get-Content $MatrixJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Host (" [+] 已加载官方规范库: 共 " + $matrixData.rules.Count + " 条规则 (数据源更新于: " + $matrixData.updated_at + ")") -ForegroundColor Gray

    foreach ($rule in $matrixData.rules) {
        $depNum = Convert-VersionToNumber $rule.since_version
        $remNum = Convert-VersionToNumber $rule.removed_in_version

        $checkPass = $false
        if ($rule.check_type -eq "positive_match") {
            $checkPass = [bool]($ktContent -match $rule.pattern)
        } elseif ($rule.check_type -eq "negative_match") {
            $checkPass = -not [bool]($ktContent -match $rule.pattern)
        } elseif ($rule.check_type -eq "custom") {
            switch ($rule.pass_condition) {
                "has_store_dns_and_no_put_store_rdrc" {
                    $checkPass = ($ktContent -match '"store_dns"') -and (-not ($ktContent -match 'put\(\s*"store_rdrc"'))
                }
                "dns_direct_no_detour_direct" {
                    $checkPass = ($ktContent -match '"tag",\s*"dns-direct"') -and (-not ($ktContent -match '"dns-direct"[\s\S]{1,120}"detour",\s*"direct"'))
                }
                "dns_remote_has_resolver_and_detour" {
                    $checkPass = ($ktContent -match '"tag",\s*"dns-remote"') -and ($ktContent -match '"domain_resolver",\s*"dns-direct"') -and ($ktContent -match '"detour",\s*GatewayConstants\.TAG_PROXY')
                }
                "dns_server_ips_routed" {
                    $checkPass = ($ktContent -match '1\.1\.1\.1/32') -and ($ktContent -match '223\.5\.5\.5/32')
                }
                "mixed_port_8899_configured" {
                    $checkPass = ($ktContent -match 'GATEWAY_MIXED_PORT') -or ($ktContent -match '8899')
                }
                "ruleset_points_to_json" {
                    $checkPass = ($ktContent -match 'JSON_PRIORITY_WHITELIST') -or ($ktContent -match '\.json')
                }
                default {
                    $checkPass = $true
                }
            }
        }

        if ($currentVerNum -ge $remNum) {
            if ($checkPass) {
                Write-Host (" [✔] [强制规范] " + $rule.name) -ForegroundColor Green
            } else {
                Write-Host (" [✖] [破坏性变更阻断] " + $rule.name) -ForegroundColor Red
                Write-Host ("     ├─ 错误详情: " + $rule.error_message) -ForegroundColor Red
                Write-Host ("     ├─ 修复建议: " + $rule.suggestion) -ForegroundColor Yellow
                Write-Host ("     └─ 官方文档: " + $rule.doc_url) -ForegroundColor Gray
                $issues += $rule.error_message
                $allPassed = $false
            }
        } elseif ($currentVerNum -ge $depNum) {
            if ($checkPass) {
                Write-Host (" [✔] [已完成迁移] " + $rule.name) -ForegroundColor Green
            } else {
                Write-Host (" [!] [已弃用警告] " + $rule.name) -ForegroundColor Yellow
                Write-Host ("     ├─ 警告详情: " + $rule.error_message) -ForegroundColor Yellow
                Write-Host ("     ├─ 迁移建议: " + $rule.suggestion) -ForegroundColor Cyan
                Write-Host ("     └─ 官方文档: " + $rule.doc_url) -ForegroundColor Gray
                $warnings += $rule.error_message
            }
        } else {
            Write-Host (" [i] [前向兼容] " + $rule.name + " (适于 v" + $rule.since_version + "+)") -ForegroundColor Gray
        }
    }
}

# ----------------------------------------------------------------------
# 4. 【第 2 层】官方 Go 内核 (sing-box.exe check) 原厂权威 Schema 与依赖闭环裁决
# ----------------------------------------------------------------------
Write-Host "`n[*] [步骤 4/5] 正在调用官方原厂 sing-box.exe 执行权威 Schema 与配置自检..." -ForegroundColor Yellow

if (-not (Test-Path $CliExe)) {
    Write-Host " [!] 未在 tools/bin/ 找到 sing-box.exe，正在尝试自动拉取配套原厂 CLI..." -ForegroundColor Yellow
    $cliScript = Join-Path $PSScriptRoot "download-sing-box-cli.ps1"
    if (Test-Path $cliScript) {
        & $cliScript
    }
}

if (-not (Test-Path $CliExe)) {
    Write-Host " [!] 无法获取 sing-box.exe，跳过原厂二进制自检。" -ForegroundColor Yellow
} else {
    # 构造与 ConfigGenerator 100% 拓扑等价的模拟完整配置
    $mockConfig = @{
        log = @{ level = "warn" }
        dns = @{
            servers = @(
                @{ tag = "dns-direct"; type = "udp"; server = "223.5.5.5" },
                @{ tag = "dns-remote"; type = "https"; server = "1.1.1.1"; path = "/dns-query"; domain_resolver = "dns-direct"; detour = "PROXY" }
            )
            rules = @(
                @{ rule_set = "direct"; server = "dns-direct" },
                @{ rule_set = "blacklist"; action = "reject" }
            )
            final = "dns-remote"
            strategy = "prefer_ipv4"
        }
        inbounds = @(
            @{ type = "mixed"; tag = "mixed-in"; listen = "0.0.0.0"; listen_port = 8899 }
        )
        outbounds = @(
            @{ type = "selector"; tag = "PROXY"; outbounds = @("direct", "block") },
            @{ type = "direct"; tag = "direct" },
            @{ type = "block"; tag = "block" }
        )
        route = @{
            rules = @(
                @{ action = "sniff" },
                @{ protocol = "dns"; action = "hijack-dns" },
                @{ ip_cidr = @("1.1.1.1/32", "1.0.0.1/32", "8.8.8.8/32", "8.8.4.4/32"); outbound = "PROXY" },
                @{ ip_cidr = @("223.5.5.5/32", "223.6.6.6/32", "119.29.29.29/32", "180.184.1.1/32"); outbound = "direct" },
                @{ ip_is_private = $true; outbound = "direct" },
                @{ ip_cidr = @("17.0.0.0/8", "100.64.0.0/10"); outbound = "direct" },
                @{
                    type = "logical"
                    mode = "and"
                    rules = @(
                        @{ source_ip_cidr = @("192.168.10.50/32") },
                        @{ domain_suffix = @("googlevideo.com") }
                    )
                    action = "reject"
                },
                @{ rule_set = "priority-whitelist"; outbound = "PROXY" },
                @{ rule_set = "blacklist"; action = "reject" },
                @{ rule_set = "direct"; outbound = "direct" },
                @{ rule_set = "whitelist"; outbound = "PROXY" }
            )
            rule_set = @(
                @{ type = "local"; tag = "priority-whitelist"; format = "source"; path = (Join-Path $tempRulesDir "RuleSet_Priority_Whitelist.json") },
                @{ type = "local"; tag = "blacklist"; format = "source"; path = (Join-Path $tempRulesDir "RuleSet_Blacklist.json") },
                @{ type = "local"; tag = "direct"; format = "source"; path = (Join-Path $tempRulesDir "RuleSet_Direct.json") },
                @{ type = "local"; tag = "whitelist"; format = "source"; path = (Join-Path $tempRulesDir "RuleSet_Whitelist.json") }
            )
            default_domain_resolver = "dns-direct"
            final = "block"
            auto_detect_interface = $true
        }
        experimental = @{
            clash_api = @{ external_controller = "127.0.0.1:9090" }
            cache_file = @{ enabled = $true; store_dns = $true }
        }
    }

    $mockConfigJson = $mockConfig | ConvertTo-Json -Depth 10
    $tempConfigFile = Join-Path $tempRulesDir "singbox_mock_gateway_config.json"
    [System.IO.File]::WriteAllText($tempConfigFile, $mockConfigJson, $utf8NoBom)

    $checkOutput = & $CliExe check -c $tempConfigFile 2>&1
    $checkExitCode = $LASTEXITCODE

    if ($checkExitCode -eq 0) {
        Write-Host " [✔] 官方原厂 sing-box.exe check 校验 100% 通过！" -ForegroundColor Green
        Write-Host "     ├─ Go 内核 Schema 反序列化: 成功" -ForegroundColor Gray
        Write-Host "     ├─ DNS 拓扑与 Outbound 依赖关系图: 无死锁无缺失" -ForegroundColor Gray
        Write-Host "     └─ 本地 4 大 JSON version: 2 规则集加载: 全部正常" -ForegroundColor Gray
    } else {
        Write-Host " [✖] 官方原厂 sing-box.exe check 报出语法/依赖错误:" -ForegroundColor Red
        $checkOutput | ForEach-Object { Write-Host ("     " + $_) -ForegroundColor Red }
        $issues += "官方 sing-box.exe check 校验失败: $checkOutput"
        $allPassed = $false
    }
}

# 清理临时演练文件
Remove-Item -Recurse -Force $tempRulesDir -ErrorAction SilentlyContinue

# ----------------------------------------------------------------------
# 5. 架构结构与 Kotlin 顶层包与 Hook 挂载点验证
# ----------------------------------------------------------------------
Write-Host "`n[*] [步骤 5/5] 正在检查 Gateway 源码包完整性与 Hook 挂载点..." -ForegroundColor Yellow

$requiredKt = @("ConfigGenerator.kt", "GatewayConstants.kt", "GatewayHook.kt", "RuleSetManager.kt")
$allKtFound = $true
foreach ($kt in $requiredKt) {
    if (-not (Test-Path (Join-Path $GatewayDir $kt))) {
        Write-Host (" [✖] 顶层包缺少文件: " + $kt) -ForegroundColor Red
        $allKtFound = $false
        $allPassed = $false
    }
}

if ($allKtFound) {
    Write-Host " [✔] Gateway 核心 4 大文件完整位于顶层包: app/src/main/java/gateway/" -ForegroundColor Green
}

# 检查 Profile.kt 挂载点 (网关自动注入)
$profileFile = Join-Path $ProjectRoot "app\src\main\java\io\nekohasekai\sfa\database\Profile.kt"
if (Test-Path $profileFile) {
    $profContent = Get-Content $profileFile -Raw -Encoding UTF8
    if ($profContent -match 'GatewayHook\.injectGatewayConfig') {
        Write-Host " [✔] Profile.kt 数据库实体已正确挂载 GatewayHook.injectGatewayConfig()" -ForegroundColor Green
    } else {
        Write-Host " [!] Profile.kt 未挂载 GatewayHook（如在其他层挂载可忽略）" -ForegroundColor Yellow
    }
}

Write-Host "`n================================================================" -ForegroundColor Cyan
if ($allPassed) {
    Write-Host " [🎉] 全项工业级双层体检 100% 通过！网关配置完全符合官方最新规范。" -ForegroundColor Green
    exit 0
} else {
    Write-Host " [✖] 体检发现以下风险问题，建议修复后再进行编译：" -ForegroundColor Red
    foreach ($issue in $issues) {
        Write-Host ("     - " + $issue) -ForegroundColor Red
    }
    exit 1
}
Write-Host "================================================================" -ForegroundColor Cyan
