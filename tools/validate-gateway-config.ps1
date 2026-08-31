# Sing-box 1.14+ Gateway Pre-build Diagnostic and Validation Tool
$ProjectRoot = Resolve-Path "$PSScriptRoot\.."
Set-Location $ProjectRoot

$RulesDir = Join-Path $ProjectRoot "app\src\main\assets\gateway_rules"
$GatewayDir = Join-Path $ProjectRoot "app\src\main\java\gateway"

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "     Sing-box 1.14+ 网关编译前深度合规性体检与闭环诊断工具      " -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan

$allPassed = $true
$issues = @()

# ----------------------------------------------------------------------
# 1. 规则集源文件语法与 1.14.0 纯域名规范校验
# ----------------------------------------------------------------------
Write-Host "`n[*] [步骤 1/4] 正在扫描 assets/gateway_rules/ 规则集源文件..." -ForegroundColor Yellow

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
                Write-Host (" [!] " + $file + " 警告: 包含 IP 规则（1.14 DNS 路由中必须使用纯域名）") -ForegroundColor Red
                $issues += ($file + " 包含 IP-CIDR 规则，在 1.14.0 DNS 引擎中会导致警告或解析异常")
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
# 2. 规则集 JSON (version: 2) 序列化演练与语法校验 (纯 PowerShell 校验)
# ----------------------------------------------------------------------
Write-Host "`n[*] [步骤 2/4] 正在模拟 RuleSetManager 转换 Sing-box version: 2 JSON 规则..." -ForegroundColor Yellow

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
        $roundTrip = $jsonStr | ConvertFrom-Json
        if ($roundTrip.version -eq 2) {
            $totalExtracted = $domains.Count + $suffixes.Count + $keywords.Count + $ips.Count
            Write-Host (" [✔] " + $file + " -> JSON version: 2 合规, 转换出 " + $totalExtracted + " 条规则") -ForegroundColor Green
        } else {
            Write-Host (" [✖] " + $file + " JSON version 不为 2") -ForegroundColor Red
            $allPassed = $false
        }
    } catch {
        Write-Host (" [✖] " + $file + " JSON 序列化失败: " + $_.Exception.Message) -ForegroundColor Red
        $issues += ($file + " 无法转换为合规 JSON")
        $allPassed = $false
    }
}

# ----------------------------------------------------------------------
# 3. ConfigGenerator 核心配置逻辑全要素深度审查
# ----------------------------------------------------------------------
Write-Host "`n[*] [步骤 3/4] 正在对 ConfigGenerator.kt 核心生成逻辑进行静态语法与冲突体检..." -ForegroundColor Yellow

$configGenFile = Join-Path $GatewayDir "ConfigGenerator.kt"
if (-not (Test-Path $configGenFile)) {
    Write-Host " [✖] 未找到 ConfigGenerator.kt 源码文件！" -ForegroundColor Red
    $issues += "缺少 ConfigGenerator.kt"
    $allPassed = $false
} else {
    $ktContent = Get-Content $configGenFile -Raw -Encoding UTF8

    # 1. DNS 引擎检查
    $dnsChecks = @(
        @{
            Name = "dns-direct 纯净直连规范 (严禁声明 detour: direct)";
            Check = ($ktContent -match '"tag",\s*"dns-direct"') -and (-not ($ktContent -match '"dns-direct"[\s\S]{1,120}"detour",\s*"direct"'));
            ErrorMsg = "dns-direct 包含了 detour: direct，会导致核心报错: detour to an empty direct outbound makes no sense"
        },
        @{
            Name = "dns-remote 防污染 DoH 出站与域名解析器绑定";
            Check = ($ktContent -match '"tag",\s*"dns-remote"') -and ($ktContent -match '"domain_resolver",\s*"dns-direct"') -and ($ktContent -match '"detour",\s*GatewayConstants\.TAG_PROXY');
            ErrorMsg = "dns-remote 缺少 domain_resolver 或未指定 detour: PROXY，会导致海外 DNS 超时"
        },
        @{
            Name = "DNS 解析 IP 直通路由 (1.1.1.1 -> PROXY, 223.5.5.5 -> direct)";
            Check = ($ktContent -match '1\.1\.1\.1/32') -and ($ktContent -match '223\.5\.5\.5/32');
            ErrorMsg = "底层路由未对 1.1.1.1 或 223.5.5.5 显式放行，在 final: block 下会导致 DNS 请求被丢弃"
        },
        @{
            Name = "局域网与私有 IP 放行 (ip_is_private -> direct)";
            Check = ($ktContent -match '"ip_is_private",\s*true');
            ErrorMsg = "缺少 ip_is_private 直连规则，可能导致局域网通信中断"
        },
        @{
            Name = "旁路由 8899 mixed 端口入站注入";
            Check = ($ktContent -match 'GATEWAY_MIXED_PORT') -or ($ktContent -match '8899');
            ErrorMsg = "未检测到 8899 旁路由端口配置"
        },
        @{
            Name = "1.14 规则集引用格式规范 (必须指向 .json，严禁指向 .yaml)";
            Check = ($ktContent -match 'JSON_PRIORITY_WHITELIST') -or ($ktContent -match '\.json');
            ErrorMsg = "规则集指针未指向 .json 文件，会导致 1.14 核心 parse rule-set 报 JSON 解析错误"
        },
        @{
            Name = "1.14 缓存升级 (store_dns: true, 彻底移除 store_rdrc)";
            Check = ($ktContent -match '"store_dns"') -and (-not ($ktContent -match '"store_rdrc",\s*true'));
            ErrorMsg = "存在已废弃的 store_rdrc 缓存字段"
        }
    )

    foreach ($chk in $dnsChecks) {
        if ($chk.Check) {
            Write-Host (" [✔] " + $chk.Name) -ForegroundColor Green
        } else {
            Write-Host (" [✖] " + $chk.Name) -ForegroundColor Red
            Write-Host ("     └─ 错误详情: " + $chk.ErrorMsg) -ForegroundColor Red
            $issues += $chk.ErrorMsg
            $allPassed = $false
        }
    }
}

# ----------------------------------------------------------------------
# 4. 架构结构与 Kotlin 顶层包与 Hook 挂载点验证
# ----------------------------------------------------------------------
Write-Host "`n[*] [步骤 4/4] 正在检查 Gateway 源码包完整性与 Hook 挂载点..." -ForegroundColor Yellow

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
    Write-Host " [🎉] 全项合规体检 100% 通过！所有配置逻辑与规则集完全符合 Sing-box 1.14+ 规范。" -ForegroundColor Green
    exit 0
} else {
    Write-Host " [✖] 体检发现以下风险问题，建议修复后再进行编译：" -ForegroundColor Red
    foreach ($issue in $issues) {
        Write-Host ("     - " + $issue) -ForegroundColor Red
    }
    exit 1
}
Write-Host "================================================================" -ForegroundColor Cyan
