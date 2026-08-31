$ErrorActionPreference = "Stop"

$ProjectRoot = Resolve-Path "$PSScriptRoot\.."
Set-Location $ProjectRoot

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "    Sing-box for Android 官方客户端主线代码自动变基同步工具       " -ForegroundColor Cyan
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

# 3. 拉取官方最新 main 分支与 tags
Write-Host "[*] 正在从官方上游拉取最新主分支 (upstream/main)..." -ForegroundColor Yellow
git fetch upstream main --quiet

# 4. 获取当前版本与官方最新版本号
$upstreamVersion = ""
try {
    $versionProps = git show upstream/main:version.properties
    if ($versionProps -match 'VERSION_NAME=(.+)') {
        $upstreamVersion = $matches[1].Trim()
    }
} catch {
    $upstreamVersion = "latest"
}

Write-Host ("[+] 官方上游最新正式版本为: " + $upstreamVersion + " (upstream/main)") -ForegroundColor Green

$currentBranch = (git branch --show-current).Trim()
Write-Host ("[*] 当前所在分支: " + $currentBranch) -ForegroundColor Gray

# 5. 检查是否已经是最新 commit
$mergeBase = git merge-base HEAD upstream/main
$upstreamCommit = (git rev-parse upstream/main).Trim()
if ($mergeBase -eq $upstreamCommit) {
    Write-Host ("[+] 当前分支已经基于官方最新主线 (" + $upstreamVersion + ")，无需重复变基！") -ForegroundColor Green
    
    # 仍联动检查核心库版本
    Write-Host "`n[*] 正在联动检查 Sing-box Go 核心库..." -ForegroundColor Yellow
    & "$PSScriptRoot\update-sing-box-core.ps1"
    
    Write-Host "================================================================" -ForegroundColor Cyan
    exit 0
}

# 6. 安全备份分支管理（智能滚动轮换，最多保留 3 个备份）
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$baseBackupName = "backup/gateway-before-" + $upstreamVersion
$backupBranch = $baseBackupName

if (git branch --list "$baseBackupName") {
    $backupBranch = $baseBackupName + "-" + $timestamp
}

Write-Host ("[*] 正在创建安全备份分支: " + $backupBranch + " ...") -ForegroundColor Yellow
git branch $backupBranch

$allBackups = git for-each-ref --sort=creatordate --format="%(refname:short)" refs/heads/backup/gateway-*
if ($allBackups.Count -gt 3) {
    $toDelete = $allBackups[0]
    Write-Host ("[*] 正在清理较旧的历史备份分支: " + $toDelete + " ...") -ForegroundColor Gray
    git branch -D $toDelete 2>$null | Out-Null
}

# 7. 开始执行 Rebase
Write-Host ("[*] 正在将当前分支变基 (Rebase) 到 upstream/main (" + $upstreamVersion + ") ...") -ForegroundColor Cyan
try {
    git rebase upstream/main
    Write-Host ("`n[✔] 变基成功！已顺利升级到官方最新主线: " + $upstreamVersion) -ForegroundColor Green
    Write-Host "================================================================" -ForegroundColor Cyan
    
    # 8. 自动联动更新 Go 核心库 (如果版本未变则自动跳过)
    Write-Host "`n[*] 正在联动检查并同步 Sing-box Go 核心库..." -ForegroundColor Yellow
    & "$PSScriptRoot\update-sing-box-core.ps1"

    Write-Host "================================================================" -ForegroundColor Cyan
    Write-Host "【后续指引】" -ForegroundColor Yellow
    Write-Host ("1. 推送更新到您的远程仓库:   git push origin " + $currentBranch + " --force-with-lease") -ForegroundColor White
    Write-Host "2. 编译并推送到手机安装:     .\tools\build-and-install-debug.ps1 或 .\tools\build-and-install-release.ps1" -ForegroundColor White
    Write-Host "----------------------------------------------------------------" -ForegroundColor Gray
    Write-Host "【万一需要回滚】执行以下命令即可秒级无损还原:" -ForegroundColor Gray
    Write-Host ("   git reset --hard " + $backupBranch) -ForegroundColor Gray
    Write-Host "================================================================" -ForegroundColor Cyan
} catch {
    Write-Host "`n[✖] 变基过程中检测到冲突或异常！" -ForegroundColor Red
    Write-Host "请手动解决冲突后执行 'git rebase --continue'，" -ForegroundColor Yellow
    Write-Host "或执行以下命令彻底放弃本次变基并恢复原状:" -ForegroundColor Yellow
    Write-Host "   git rebase --abort" -ForegroundColor White
    exit 1
}
