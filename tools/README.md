# Sing-box for Android 自动化维护与构建工具箱

本目录收纳了维护本项目自定义分流网关（Gateway）、白名单智能捕获、编译前合规校验与跟进官方最新发布版所需的全套自动化工具。

---

## 🛠️ 工具速查表

| 工具文件 | 所属模块 / 目录 | 核心功能说明 | 常用命令 |
| :--- | :--- | :--- | :--- |
| **`build-and-install-debug.ps1`** | **【根目录 · 本地调试】** | 本地极速编译 arm64 Debug APK，并自动推送到连接的手机上安装并拉起应用 | `.\tools\build-and-install-debug.ps1` |
| **`build-and-install-release.ps1`** | **【根目录 · 正式发布】** | 编译开启 R8 混淆优化与 Keystore 正式签名的 arm64 Release APK，并支持自动安装到手机 | `.\tools\build-and-install-release.ps1` |
| **`validator\validate-gateway-config.ps1`** | **【编译前体检】** | 一键深度诊断 4 大规则集语法、加载官方 Migration/Deprecated 矩阵，并调起官方原厂 `sing-box.exe check` 进行权威裁决 | `.\tools\validator\validate-gateway-config.ps1` |
| **`validator\sync-rules-matrix.ps1`** | **【编译前体检】** | 从官方在线文档同步最新 Migration & Deprecated 规范至 `tools\schema\singbox_rules_matrix.json` (未变动秒级跳过) | `.\tools\validator\sync-rules-matrix.ps1` |
| **`whitelist-updater\android-auto-whitelist-sniffer.ps1`** | **【白名单自愈 · Android】** | 实时嗅探指定 Android App（交互式输入包名）的网络活动，自动捕获被拦截的域名/IP 并更新至 `RuleSet_Whitelist.yaml` | `.\tools\whitelist-updater\android-auto-whitelist-sniffer.ps1` |
| **`whitelist-updater\windows-chrome-auto-whitelist-sniffer.ps1`** | **【白名单自愈 · Chrome】** | 自动启动 Windows Chrome 访问指定网站，实时嗅探全量子资源网络请求，捕获被拦截项并自动加入白名单 | `.\tools\whitelist-updater\windows-chrome-auto-whitelist-sniffer.ps1` |
| **`e2e-routing-test\test-e2e-gateway-routing.ps1`** | **【真机实测】** | 交互式索要订阅链接，自动打通真机端口映射，执行 5 层分流路由全项实测，带故障自动诊断与根因报告 | `.\tools\e2e-routing-test\test-e2e-gateway-routing.ps1` |
| **`update-to-latest-sing-box\update-sing-box-core.ps1`** | **【跟进官方更新】** | 官方 Go 核心发新版时，一键从 GitHub Releases 下载最新 `libbox.aar`（未变秒级跳过，并自动联动规范体检） | `.\tools\update-to-latest-sing-box\update-sing-box-core.ps1` |
| **`update-to-latest-sing-box\rebase-to-latest-clients-tag.ps1`** | **【跟进官方更新】** | 官方 Android 客户端发新版时，自动将本仓库变基至官方最新主线（自带版本备份与安全回滚） | `.\tools\update-to-latest-sing-box\rebase-to-latest-clients-tag.ps1` |

---

## 📖 典型工作流

### 🎯 场景 1：日常开发、修改分流规则或网关功能（闭环验证）
当您修改了 `app/src/main/assets/gateway_rules/` 中的规则集或 `app/src/main/java/gateway/` 源码时：

```powershell
# 1. 执行编译前双层合规自检（规则矩阵审查 + 官方原厂 sing-box.exe check）
.\tools\validator\validate-gateway-config.ps1

# 2. 一键极速编译 Debug 版并推送到手机安装启动
.\tools\build-and-install-debug.ps1

# 3. 运行端到端真机实测（输入机场订阅，全自动验证国内直连、Gemini/OneNote/微软代理与拦截）
.\tools\e2e-routing-test\test-e2e-gateway-routing.ps1
```

---

### 🕵️ 场景 2：给新应用（如 OneNote、Teams 等）自动适配白名单
当你在手机上使用某个 App 遇到部分功能无法同步或被拦截时：

```powershell
# 1. 启动白名单智能嗅探器（交互式输入包名，如 com.microsoft.office.onenote）
.\tools\whitelist-updater\auto-whitelist-sniffer.ps1

# 2. 拿着手机在 App 里操作（点击同步、笔记、文件等），屏幕将实时显示捕获到的拦截
# 3. 退出时脚本会自动询问是否一键追加至 RuleSet_Whitelist.yaml 并自动执行规范体检！
```

---

### 🚀 场景 3：官方更新了 Sing-box Go 核心（客户端代码未变）
当官方 SagerNet/sing-box 发布了新的 Go 核心版本（如 1.14.x / 1.15.0）：

```powershell
# 1. 一键拉取最新 Release 核心库 libbox.aar（自动触发配置规范体检）
.\tools\update-to-latest-sing-box\update-sing-box-core.ps1

# 2. 编译并推送到真机安装
.\tools\build-and-install-debug.ps1
```

---

### 🔄 场景 4：官方发布了新的 Android 客户端版本（如 upstream 发布新功能）
当上游官方客户端仓库 `SagerNet/sing-box-for-android` 提交了新代码或发布了新版本：

```powershell
# 1. 一键变基合并（自动保留您的网关与白名单定制）
.\tools\update-to-latest-sing-box\rebase-to-latest-clients-tag.ps1

# 2. 运行编译前诊断
.\tools\validator\validate-gateway-config.ps1

# 3. 编译发布版并真机验证
.\tools\build-and-install-release.ps1
```
