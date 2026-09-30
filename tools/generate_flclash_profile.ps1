$rulesDir = Join-Path $PSScriptRoot "..\app\src\main\assets\gateway_rules"
$baseFile = Join-Path $PSScriptRoot "flclash_base.yaml"
$desktopDir = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::Desktop)
$outputFile = Join-Path $desktopDir "flclash-gateway-profile.yaml"

function Convert-YamlFileToRules {
    param(
        [string]$fileName,
        [string]$targetAction,
        [string]$layerTag
    )
    $filePath = Join-Path $rulesDir $fileName
    $lines = [System.IO.File]::ReadAllLines($filePath, [System.Text.Encoding]::UTF8)
    $outLines = [System.Collections.Generic.List[string]]::new()
    $outLines.Add("  # ==========================================================")
    $outLines.Add("  # $layerTag (Source: assets/gateway_rules/$fileName)")
    $outLines.Add("  # ==========================================================")

    foreach ($rawLine in $lines) {
        $trimmed = $rawLine.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed -eq "payload:") {
            continue
        }
        if ($trimmed.StartsWith("#")) {
            $outLines.Add("  $trimmed")
            continue
        }
        $content = $trimmed
        if ($content.StartsWith("- ")) {
            $content = $content.Substring(2).Trim()
        }
        $comment = ""
        if ($content.Contains("#")) {
            $idx = $content.IndexOf("#")
            $comment = "  " + $content.Substring($idx).Trim()
            $content = $content.Substring(0, $idx).Trim()
        }
        $parts = $content.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
        if ($parts.Count -lt 2) {
            continue
        }
        $ruleType = $parts[0].ToUpper()
        $ruleVal = $parts[1]
        $hasNoResolve = ($parts.Count -ge 3 -and $parts[2] -eq "no-resolve") -or ($ruleType -like "IP-CIDR*")

        if ($hasNoResolve) {
            $outLines.Add("  - $ruleType,$ruleVal,$targetAction,no-resolve$comment")
        } else {
            $outLines.Add("  - $ruleType,$ruleVal,$targetAction$comment")
        }
    }
    $outLines.Add("")
    return ($outLines -join "`r`n")
}

$sb = [System.Text.StringBuilder]::new()

$baseContent = [System.IO.File]::ReadAllText($baseFile, [System.Text.Encoding]::UTF8)
[void]$sb.AppendLine($baseContent)

[void]$sb.AppendLine((Convert-YamlFileToRules "RuleSet_Priority_Whitelist.yaml" "PROXY" "Layer 2: Priority Whitelist"))
[void]$sb.AppendLine((Convert-YamlFileToRules "RuleSet_Blacklist.yaml" "REJECT" "Layer 3: Blacklist"))
[void]$sb.AppendLine((Convert-YamlFileToRules "RuleSet_Direct.yaml" "DIRECT" "Layer 4: Direct Rules"))
[void]$sb.AppendLine((Convert-YamlFileToRules "RuleSet_Whitelist.yaml" "PROXY" "Layer 5: Whitelist Rules"))

$footer = @(
    "  # ==========================================================",
    "  # Final Layer: Final Block (Matches Sing-box final: block)",
    "  # ==========================================================",
    "  - MATCH,REJECT"
) -join "`r`n"

[void]$sb.AppendLine($footer)

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($outputFile, $sb.ToString(), $utf8NoBom)

Write-Host "Generated Flclash configuration successfully on Desktop:"
Write-Host "  -> $outputFile"
