# Sing-box for Android 自动化维护与构建工具箱

本目录收纳了维护本项目自定义分流网关（Gateway）与跟进官方最新发布版所需的全套自动化工具。

---

## 🛠️ 工具速查表

| 工具文件 | 作用场景 | 常用命令 |
| :--- | :--- | :--- |
| **`rebase-to-latest-clients-tag.ps1`** | **【客户端代码同步】** 官方 Android 仓库发新版时，自动将本项目的自定义功能变基至官方最新正式版 Tag（自带智能备份与回滚机制） | `.\tools\rebase-to-latest-clients-tag.ps1` |
| **`update-sing-box-core.ps1`** | **【Go 核心库同步】** 官方 Go 核心发新版时，一键从 GitHub Releases 下载最新编译的 `libbox.aar` 覆盖到 `app/libs/` | `.\tools\update-sing-box-core.ps1` |
| **`build-and-install-debug.ps1`** | **【Debug 调试版：编译 + 安装】** 本地极速编译 arm64 Debug APK，并自动推送到连接的手机上安装与启动 | `.\tools\build-and-install-debug.ps1` |
| **`build-and-install-release.ps1`** | **【Release 正式版：编译 + 安装】** 编译开启 R8 混淆优化与 Keystore 正式签名的 arm64 Release APK，并支持自动安装 | `.\tools\build-and-install-release.ps1` |

---

## 📖 典型工作流

### 场景 1：官方发布了新的 Android 客户端版本（如 1.14.1 / 1.15.0）
```powershell
# 1. 自动同步并变基客户端源码（自动创建安全备份）
.\tools\rebase-to-latest-clients-tag.ps1

# 2. 推送变基后的提交到您自己的 GitHub 仓库
git push origin feature/gateway --force-with-lease

# 3. 同步对应版本的 Go 核心库
.\tools\update-sing-box-core.ps1

# 4. 本地编译安装（可按需选择 Debug 或 Release）
.\tools\build-and-install-debug.ps1      # 快速调试与安装
.\tools\build-and-install-release.ps1    # 正式签名版编译与安装
```

---

### 场景 2：官方仅更新了 sing-box Go 核心（客户端代码未变）
```powershell
# 1. 直接拉取最新 Release 核心库
.\tools\update-sing-box-core.ps1

# 2. 本地编译与安装
.\tools\build-and-install-debug.ps1
```

---

### 场景 3：本地修改了分流规则或网关代码后测试
```powershell
# 一键编译安装到手机
.\tools\build-and-install-debug.ps1
```

---

## 🛡️ 安全与回滚机制
`rebase-to-latest-clients-tag.ps1` 每次运行都会在本地自动创建带版本标识的安全备份分支（如 `backup/gateway-before-1.14.0`）。

如果升级后发现官方新版本存在问题，随时可以在终端执行以下命令秒级无损还原：
```bash
git reset --hard backup/gateway-before-<版本号>
```
脚本会自动维护保留最近 3 个版本的历史备份，无须担心分支堆积。
