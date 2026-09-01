# Sing-box for Android 自动化维护与构建工具箱

本目录收纳了维护本项目自定义分流网关（Gateway）与跟进官方最新发布版所需的全套自动化工具。

---

## 🛠️ 工具速查表

| 工具文件 | 作用分类 | 核心功能说明 | 常用命令 |
| :--- | :--- | :--- | :--- |
| **`test-e2e-gateway-routing.ps1`** | **【真机实测】** | 交互式索要订阅链接，自动打通真机端口映射，执行 5 层分流路由全项实测，带故障自动诊断与根因报告 | `.\tools\test-e2e-gateway-routing.ps1` |
| **`build-and-install-debug.ps1`** | **【本地调试】** | 本地极速编译 arm64 Debug APK，并自动推送到连接的手机上安装并拉起应用 | `.\tools\build-and-install-debug.ps1` |
| **`build-and-install-release.ps1`** | **【正式发布】** | 编译开启 R8 混淆优化与 Keystore 正式签名的 arm64 Release APK，并支持自动安装到手机 | `.\tools\build-and-install-release.ps1` |
| **`validate-gateway-config.ps1`** | **【规范体检】** | 一键深度诊断 4 大规则集语法、Sing-box 1.14+ 现代 DNS/Route 规范兼容性，确保核心升级后配置 100% 合规 | `.\tools\validate-gateway-config.ps1` |
| **`updater\download-sing-box-cli.ps1`** | **【官方 CLI】** | 一键从官方 Releases 同步配套的 Windows 原厂命令行工具（`sing-box.exe` + `libcronet.dll` 到 `tools\bin\`） | `.\tools\updater\download-sing-box-cli.ps1` |
| **`updater\sync-rules-matrix.ps1`** | **【规范同步】** | 从官方在线文档同步最新 Migration & Deprecated 规范至 `tools\schema\singbox_rules_matrix.json` | `.\tools\updater\sync-rules-matrix.ps1` |
| **`updater\update-sing-box-core.ps1`** | **【核心同步】** | 官方 Go 核心发新版时，一键从 GitHub Releases 下载最新 `libbox.aar`（未变秒级跳过，并自动联动规范体检） | `.\tools\updater\update-sing-box-core.ps1` |
| **`updater\rebase-to-latest-clients-tag.ps1`** | **【代码同步】** | 官方 Android 客户端发新版时，自动将本仓库变基至官方最新主线（自带版本备份与安全回滚） | `.\tools\updater\rebase-to-latest-clients-tag.ps1` |

---

## 📖 典型工作流

### 🎯 场景 1：日常开发、修改分流规则或网关功能（闭环验证）
当您修改了 `app/src/main/assets/gateway_rules/` 中的规则集或 `app/src/main/java/gateway/` 源码时：

```powershell
# 1. 执行静态配置与规则规范诊断（秒级排查 YAML/JSON 语法与 1.14 规范）
.\tools\validate-gateway-config.ps1

# 2. 一键极速编译 Debug 版并推送到手机安装启动
.\tools\build-and-install-debug.ps1

# 3. 运行端到端真机实测（输入机场订阅，全自动验证国内直连、Gemini/OneNote/微软代理与拦截）
.\tools\test-e2e-gateway-routing.ps1
```

> [!TIP]
> `test-e2e-gateway-routing.ps1` 包含完整的异常捕获机制。若某个域名解析失败或规则未按预期分流，它会自动抓取手机端内核路由日志并给出针对性的修复建议。

---

### 🚀 场景 2：官方更新了 Sing-box Go 核心（客户端代码未变）
当官方 SagerNet/sing-box 发布了新的 Go 核心版本（如 1.14.x / 1.15.0）：

```powershell
# 1. 一键拉取最新 Release 核心库 libbox.aar（自动触发配置规范体检）
.\tools\updater\update-sing-box-core.ps1

# 2. 编译并推送到真机安装
.\tools\build-and-install-debug.ps1

# 3. 验证新核心在真实节点下的分流表现
.\tools\test-e2e-gateway-routing.ps1
```

---

### 🔄 场景 3：官方发布了新的 Android 客户端版本（如 upstream 发布新功能）
当上游官方客户端仓库 `SagerNet/sing-box-for-android` 提交了新代码或发布了新版本：

```powershell
# 1. 自动同步并变基客户端源码（自动创建安全回滚分支，并联动检查/同步核心库）
.\tools\updater\rebase-to-latest-clients-tag.ps1

# 2. 编译安装到真机进行兼容性实测
.\tools\build-and-install-debug.ps1
.\tools\test-e2e-gateway-routing.ps1

# 3. 实测通过后，推送到您自己的 GitHub 远程仓库
git push origin feature/gateway --force-with-lease
```

---

### 📦 场景 4：日常使用与正式发版（Release 编译交付）
当功能开发与测试均已完备，需要生成长期日常使用的正式版本时：

```powershell
# 编译正式签名与 R8 代码混淆优化的 Release APK 并自动推送到手机
.\tools\build-and-install-release.ps1
```

---

## 🛡️ 安全与回滚机制

`rebase-to-latest-clients-tag.ps1` 每次运行前，都会在本地自动创建带版本标识的安全备份分支（例如 `backup/gateway-before-1.14.0`）。

如果升级官方新版本后遇到不兼容或异常，随时可在终端执行以下命令秒级无损还原：
```bash
git reset --hard backup/gateway-before-<版本号>
```
脚本会自动保留最近 3 个版本的历史备份，无须担心分支冗余。
