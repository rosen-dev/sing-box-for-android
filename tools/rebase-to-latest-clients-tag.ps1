# ==============================================================================
# rebase-to-latest-clients-tag.ps1
# 功能：自动检查官方 upstream 最新正式版 Tag，建立安全备份分支，并将自定义分支平滑变基
# ==============================================================================

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

$ProjectRoot = Resolve-Path "$PSScriptRoot\.."
Set-Location $ProjectRoot

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "    Sing-box for Android 官方客户端 Tag 自动变基同步工具         " -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan

# 1. 检查工作区状态
$status = git status --porcelain
if ($status) {
    Write-Host "[!] 检测到工作区有未提交的修改，请先提交或暂存后再执行变基！" -ForegroundColor Red
    git status -s
    exit 1
}

# 2. 检查并配置 upstream 远程仓库
$remotes = git remote
if ($remotes -notcontains "upstream") {
    Write-Host "[*] 正在添加官方上游远程源 (upstream: SagerNet/sing-box-for-android)..." -ForegroundColor Yellow
    git remote add upstream https://github.com/SagerNet/sing-box-for-android.git
}

# 3. 拉取官方最新 Tags
Write-Host "[*] 正在从官方上游拉取最新 Tags..." -ForegroundColor Yellow
git fetch upstream --tags --quiet

# 4. 获取当前版本与官方最新正式版 Tag
$allTags = git tag -l --sort=-v:refname
# 过滤掉包含 rc, alpha, beta, dev 的预发布标签，匹配类似于 1.14.0, 1.14.1 的正式版格式
$officialTags = $allTags | Where-Object { $_ -match '^[0-9]+\.[0-9]+(\.[0-9]+)?$' }

if (-not $officialTags) {
    Write-Host "[!] 未找到有效的官方正式版 Tag，请检查网络连接。" -ForegroundColor Red
    exit 1
}

$latestTag = $officialTags[0]
Write-Host "[+] 官方上游最新正式版 Tag 为: $latestTag" -ForegroundColor Green

# 检查当前分支
$currentBranch = (git branch --show-current).Trim()
Write-Host "[*] 当前所在分支: $currentBranch" -ForegroundColor Gray

# 5. 检查是否已经是该 Tag
$mergeBase = git merge-base HEAD "refs/tags/$latestTag"
$tagCommit = (git rev-parse "refs/tags/$latestTag").Trim()
if ($mergeBase -eq $tagCommit) {
    Write-Host "[+] 当前分支已经基于最新 Tag ($latestTag)，无需重复变基！" -ForegroundColor Green
    Write-Host "================================================================" -ForegroundColor Cyan
    exit 0
}

# 6. 安全备份分支管理（智能滚动轮换，最多保留 3 个备份）
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$baseBackupName = "backup/gateway-before-$latestTag"
$backupBranch = $baseBackupName

# 如果同名备份已存在，则追加时间戳后缀
$existingBranches = git branch --list "$baseBackupName"
if ($existingBranches) {
    $backupBranch = "$baseBackupName-$timestamp"
}

Write-Host "[*] 正在创建安全备份分支: $backupBranch ..." -ForegroundColor Yellow
git branch $backupBranch

# 自动滚动清理：若备份分支超过 3 个，删除最旧的一个
$allBackups = git for-each-ref --sort=creatordate --format="%(refname:short)" refs/heads/backup/gateway-*
if ($allBackups.Count -gt 3) {
    $toDelete = $allBackups[0]
    Write-Host "[*] 正在清理较旧的历史备份分支: $toDelete ..." -ForegroundColor Gray
    git branch -D $toDelete 2>$null | Out-Null
}

# 7. 开始执行 Rebase
Write-Host "[*] 正在将当前分支变基 (Rebase) 到官方 $latestTag ..." -ForegroundColor Cyan
try {
    git rebase $latestTag
    Write-Host "`n[✔] 变基成功！已顺利升级到官方正式版 Tag: $latestTag" -ForegroundColor Green
    Write-Host "================================================================" -ForegroundColor Cyan
    Write-Host "【后续指引】" -ForegroundColor Yellow
    Write-Host "1. 推送更新到您的远程仓库:   git push origin $currentBranch --force-with-lease" -ForegroundColor White
    Write-Host "2. 运行核心同步工具:         .\tools\update-sing-box-core.ps1" -ForegroundColor White
    Write-Host "3. 编译并推送到手机:         .\tools\build-and-install-debug.ps1 或 .\tools\build-and-install-release.ps1" -ForegroundColor White
    Write-Host "----------------------------------------------------------------" -ForegroundColor Gray
    Write-Host "【万一需要回滚】执行以下命令即可秒级无损还原:" -ForegroundColor Gray
    Write-Host "   git reset --hard $backupBranch" -ForegroundColor Gray
    Write-Host "================================================================" -ForegroundColor Cyan
} catch {
    Write-Host "`n[✖] 变基过程中检测到冲突或异常！" -ForegroundColor Red
    Write-Host "请手动解决冲突后执行 'git rebase --continue'，" -ForegroundColor Yellow
    Write-Host "或执行以下命令彻底放弃本次变基并恢复原状:" -ForegroundColor Yellow
    Write-Host "   git rebase --abort" -ForegroundColor White
    exit 1
}
