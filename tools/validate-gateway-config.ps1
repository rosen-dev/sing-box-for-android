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
        $issues += "$file 中存在非法规则行"
        $allPassed = $false
    } else {
        if ($dnsRuleSets -contains $file) {
            if ($hasIpCidr) {
                Write-Host (" [!] " + $file + " 警告: 包含 IP 规则（1.14 DNS 路由中必须使用纯域名）") -ForegroundColor Red
                $issues += "$file 包含 IP-CIDR 规则，在 1.14.0 DNS 引擎中会导致警告或解析异常"
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
# 2. 规则集 JSON (version: 2) 序列化演练与语法校验 (防止 parse rule-set 崩溃)
# ----------------------------------------------------------------------
Write-Host "`n[*] [步骤 2/4] 正在模拟 RuleSetManager 转换 Sing-box version: 2 JSON 规则..." -ForegroundColor Yellow

$jsonConvertCheckPy = @"
import os
import yaml
import json
import sys

rules_dir = r"$RulesDir"
yaml_files = [
    "RuleSet_Direct.yaml",
    "RuleSet_Blacklist.yaml",
    "RuleSet_Priority_Whitelist.yaml",
    "RuleSet_Whitelist.yaml"
]

all_ok = True
for yname in yaml_files:
    ypath = os.path.join(rules_dir, yname)
    if not os.path.exists(ypath):
        print(f"FAIL|Missing {yname}")
        all_ok = False
        continue

    domain_list = []
    suffix_list = []
    keyword_list = []
    ip_list = []

    with open(ypath, "r", encoding="utf-8-sig") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or line == "payload:":
                continue
            if line.startswith("- "):
                content = line[2:].strip()
                parts = [p.strip() for p in content.split(",")]
                rtype = parts[0].upper()
                rval = parts[1] if len(parts) > 1 else ""
                if rtype == "DOMAIN":
                    domain_list.append(rval)
                elif rtype == "DOMAIN-SUFFIX":
                    suffix_list.append(rval)
                elif rtype == "DOMAIN-KEYWORD":
                    keyword_list.append(rval)
                elif rtype.startswith("IP-CIDR"):
                    ip_list.append(rval)

    rule_obj = {}
    if domain_list: rule_obj["domain"] = domain_list
    if suffix_list: rule_obj["domain_suffix"] = suffix_list
    if keyword_list: rule_obj["domain_keyword"] = keyword_list
    if ip_list: rule_obj["ip_cidr"] = ip_list

    full_json_obj = {
        "version": 2,
        "rules": [rule_obj] if rule_obj else []
    }

    try:
        json_str = json.dumps(full_json_obj, ensure_ascii=False, indent=2)
        parsed = json.loads(json_str)
        if parsed.get("version") != 2:
            print(f"FAIL|{yname} output version is not 2")
            all_ok = False
        else:
            total_extracted = len(domain_list) + len(suffix_list) + len(keyword_list) + len(ip_list)
            print(f"PASS|{yname}|JSON version: 2 合规, 转换出 {total_extracted} 条规则")
    except Exception as e:
        print(f"FAIL|{yname} JSON serialization error: {e}")
        all_ok = False

if all_ok:
    print("ALL_JSON_OK")
"@

$tempPy1 = [System.IO.Path]::GetTempFileName() + ".py"
[System.IO.File]::WriteAllText($tempPy1, $jsonConvertCheckPy, [System.Text.Encoding]::UTF8)
$jsonCheckOutput = python $tempPy1
Remove-Item -Force $tempPy1 -ErrorAction SilentlyContinue

foreach ($line in ($jsonCheckOutput -split "`r?`n")) {
    if (-not $line) { continue }
    $parts = $line -split '\|'
    if ($parts[0] -eq "PASS") {
        Write-Host (" [✔] " + $parts[1] + " -> " + $parts[2]) -ForegroundColor Green
    } elseif ($parts[0] -eq "FAIL") {
        Write-Host (" [✖] " + $parts[1]) -ForegroundColor Red
        $issues += "RuleSet 转换 JSON 校验失败: " + $parts[1]
        $allPassed = $false
    }
}

# ----------------------------------------------------------------------
# 3. ConfigGenerator 核心配置逻辑全要素深度审查 (防止启动报错)
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

# 检查 BoxService.kt 挂载点
$boxServiceFile = Join-Path $ProjectRoot "app\src\main\java\io\nekohasekai\sfa\service\BoxService.kt"
if (Test-Path $boxServiceFile) {
    $bsContent = Get-Content $boxServiceFile -Raw -Encoding UTF8
    if ($bsContent -match 'GatewayHook\.patchConfig') {
        Write-Host " [✔] BoxService.kt 已正确注入 GatewayHook.patchConfig() 拦截点" -ForegroundColor Green
    } else {
        Write-Host " [✖] BoxService.kt 缺少 GatewayHook.patchConfig() 拦截点！" -ForegroundColor Red
        $issues += "BoxService.kt 缺少 GatewayHook 拦截点"
        $allPassed = $false
    }
}

Write-Host "`n================================================================" -ForegroundColor Cyan
if ($allPassed) {
    Write-Host " [🎉] 全项深度体检 100% 通过！所有规则集与配置逻辑已完全闭环，允许编译！" -ForegroundColor Green
} else {
    Write-Host " [!] 编译前深度诊断拦截到以下潜在致命问题，请在编译前修复:" -ForegroundColor Red
    $issues | ForEach-Object { Write-Host ("  ✖ " + $_) -ForegroundColor Red }
    Write-Host "================================================================" -ForegroundColor Cyan
    exit 1
}
Write-Host "================================================================" -ForegroundColor Cyan
