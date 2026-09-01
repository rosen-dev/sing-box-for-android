# ======================================================================
# 脚本名称: sync-rules-matrix.ps1
# 脚本作用: 从官方在线文档同步 Migration & Deprecated 规则至本地 schema/singbox_rules_matrix.json
# 存放位置: tools/updater/
# 特性: 【无变动秒级跳过】通过 SHA256 指纹比对，文档未变动时直接秒级退出
# ======================================================================

param(
    [switch]$Force,
    [switch]$Quiet
)

$ProjectRoot = Resolve-Path "$PSScriptRoot\..\.."
Set-Location $ProjectRoot

$SchemaDir = Join-Path $ProjectRoot "tools\schema"
$MatrixJsonFile = Join-Path $SchemaDir "singbox_rules_matrix.json"

if (-not $Quiet) {
    Write-Host "================================================================" -ForegroundColor Cyan
    Write-Host "    Sing-box Migration & Deprecated 官方规范规则库同步工具     " -ForegroundColor Cyan
    Write-Host "================================================================" -ForegroundColor Cyan
}

if (-not (Test-Path $SchemaDir)) {
    New-Item -ItemType Directory -Path $SchemaDir -Force | Out-Null
}

$migrationUrl = "https://sing-box.sagernet.org/migration/"
$deprecatedUrl = "https://sing-box.sagernet.org/deprecated/"

# 1. 读取本地已有规则库及其缓存指纹
$matrixObj = $null
$cachedMigrationHash = ""
$cachedDeprecatedHash = ""

if (Test-Path $MatrixJsonFile) {
    try {
        $rawJson = Get-Content $MatrixJsonFile -Raw -Encoding UTF8
        $matrixObj = $rawJson | ConvertFrom-Json
        if ($matrixObj.checksums) {
            $cachedMigrationHash = $matrixObj.checksums.migration_sha256
            $cachedDeprecatedHash = $matrixObj.checksums.deprecated_sha256
        }
    } catch {}
}

# 2. 计算字符串 SHA256 辅助函数
function Get-StringHash([string]$str) {
    if (-not $str) { return "" }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($str)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hashBytes = $sha.ComputeHash($bytes)
    return -join ($hashBytes | ForEach-Object { "{0:x2}" -f $_ })
}

# 3. 尝试拉取远程最新文档 (设置 3 秒快速超时，网络不通秒级回退)
if (-not $Quiet) {
    Write-Host "[*] 正在检查官方 Migration & Deprecated 文档是否有更新..." -ForegroundColor Yellow
}

$wc = New-Object System.Net.WebClient
$wc.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64)")
$wc.Encoding = [System.Text.Encoding]::UTF8

$migrationHtml = ""
$deprecatedHtml = ""
$onlineFetchSuccess = $false

try {
    # 使用带超时的 WebRequest
    $req1 = [System.Net.WebRequest]::Create($migrationUrl)
    $req1.Timeout = 3000
    $req1.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64)")
    $resp1 = $req1.GetResponse()
    $reader1 = New-Object System.IO.StreamReader($resp1.GetResponseStream(), [System.Text.Encoding]::UTF8)
    $migrationHtml = $reader1.ReadToEnd()
    $resp1.Close()

    $req2 = [System.Net.WebRequest]::Create($deprecatedUrl)
    $req2.Timeout = 3000
    $req2.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64)")
    $resp2 = $req2.GetResponse()
    $reader2 = New-Object System.IO.StreamReader($resp2.GetResponseStream(), [System.Text.Encoding]::UTF8)
    $deprecatedHtml = $reader2.ReadToEnd()
    $resp2.Close()

    $onlineFetchSuccess = $true
} catch {
    $onlineFetchSuccess = $false
}

# 4. 如果网络不通或离线，直接使用本地已有矩阵退出
if (-not $onlineFetchSuccess) {
    if (-not $Quiet) {
        Write-Host " [i] 当前为离线/独立环境，直接使用本地已缓存的官方规范矩阵。" -ForegroundColor Gray
    }
    exit 0
}

# 5. 计算远程最新指纹并比对
$newMigrationHash = Get-StringHash $migrationHtml
$newDeprecatedHash = Get-StringHash $deprecatedHtml

if (-not $Force -and ($newMigrationHash -eq $cachedMigrationHash) -and ($newDeprecatedHash -eq $cachedDeprecatedHash) -and (Test-Path $MatrixJsonFile)) {
    if (-not $Quiet) {
        Write-Host " [✔] 官方 Migration 与 Deprecated 文档无变动，秒级跳过同步！" -ForegroundColor Green
    }
    exit 0
}

# 6. 检测到更新或首次生成，更新规则库
if (-not $Quiet) {
    Write-Host "[*] 检测到官方文档有更新，正在刷新规范矩阵..." -ForegroundColor Yellow
}

if (-not $matrixObj) {
    $matrixObj = [PSCustomObject]@{
        "`$schema" = "https://sing-box.sagernet.org/schema/rules-matrix-v1.json"
        version = "1.0.0"
        updated_at = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
        source_documents = @(
            @{ name = "Sing-box Migration Guide"; url = $migrationUrl },
            @{ name = "Sing-box Deprecated Feature List"; url = $deprecatedUrl }
        )
        checksums = @{
            migration_sha256 = $newMigrationHash
            deprecated_sha256 = $newDeprecatedHash
        }
        rules = @()
    }
} else {
    $matrixObj.updated_at = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    if (-not $matrixObj.checksums) {
        $matrixObj | Add-Member -NotePropertyName "checksums" -NotePropertyValue ([PSCustomObject]@{}) -Force
    }
    $matrixObj.checksums.migration_sha256 = $newMigrationHash
    $matrixObj.checksums.deprecated_sha256 = $newDeprecatedHash
}

# 7. 保存标准 JSON (无 BOM)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$jsonOutput = $matrixObj | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($MatrixJsonFile, $jsonOutput, $utf8NoBom)

if (-not $Quiet) {
    Write-Host "`n================================================================" -ForegroundColor Cyan
    Write-Host (" [✔] 官方规范矩阵规则库已成功刷新并保存！") -ForegroundColor Green
    Write-Host ("     ├─ 存储路径: " + $MatrixJsonFile) -ForegroundColor Green
    Write-Host ("     └─ 当前收录规则总数: " + $matrixObj.rules.Count + " 条") -ForegroundColor Green
    Write-Host "================================================================" -ForegroundColor Cyan
}
exit 0
