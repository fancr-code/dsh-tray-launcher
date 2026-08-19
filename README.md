# dsh-tray-launcher

DeepSeek Harness（dsh）的 Windows 桌面托盘启动器：双击快捷方式**无窗口**启动 `dsh web`，常驻系统托盘；托盘图标管理界面与日志，「退出」即完整停止。本仓库包含托盘脚本、一键安装器与桌面快捷方式生成——不是 dsh 的 cordis 插件，而是 dsh 的 Windows 启动/常驻工具。

## 特性

- **无窗口启动**：不弹 cmd/控制台，harness 在后台运行，stdout/stderr 落盘日志
- **系统托盘**：托盘图标常驻，右键菜单「打开界面 / 打开日志 / 退出」；双击图标直接打开界面
- **退出即全退**：点「退出」先停止 harness 进程、再关闭托盘，不留后台残留
- **就绪自动开浏览器**：后台轮询端口，harness 一监听就自动打开 `http://127.0.0.1:3080`
- **单实例保护**：重复双击快捷方式不会重复启动，只会唤起界面（互斥锁 + 端口检测）
- **自动定位 dsh**：依次探测配置文件、npm 全局安装、npx 缓存，找不到才报错；也支持手动指定
- **自定义图标**：安装时传一个 `.ico` 即可换托盘与快捷方式图标
- **控制台模式兜底**：`launch.bat` 前台运行、日志直接打在窗口里（排查问题时用）
- **可选开机自启**：安装器 `-Autostart` 把快捷方式复制进启动文件夹

## 系统要求

- Windows 10 / 11
- Windows PowerShell 5.1（系统自带，无需安装）
- 已安装 DeepSeek Harness CLI（`dsh web` 可正常启动）与 Node.js（dsh 自身要求 ≥ 22）

## 安装

### 方式一：远程一行命令（推荐）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/fancr-code/dsh-tray-launcher/main/install.ps1 | iex"
```

安装器自动检测 dsh 位置、写入配置、生成桌面快捷方式。

### 方式二：克隆仓库

```powershell
git clone https://github.com/fancr-code/dsh-tray-launcher.git
cd dsh-tray-launcher
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
```

### 安装参数

| 参数 | 说明 |
| --- | --- |
| `-DshPath <路径>` | 手动指定 dsh CLI 入口（`@deepseek-ai/dsh/lib/bin.js`），自动检测失败时使用 |
| `-Icon <xxx.ico>` | 托盘 + 快捷方式图标；不传使用系统默认图标 |
| `-ShortcutName <名称>` | 桌面快捷方式名称，默认 `DeepSeek Harness` |
| `-Autostart` | 同时注册开机自启（复制快捷方式到启动文件夹） |
| `-DryRun` | 只检测和打印，不写入任何文件 |

示例：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Icon D:\icons\liangzu.ico -Autostart
```

## 使用

- **启动**：双击桌面快捷方式 → 托盘出现图标 + 气泡提示，harness 就绪后自动打开浏览器
- **托盘右键菜单**：
  - **打开界面** — 浏览器打开 Web GUI
  - **打开日志** — 记事本打开 stdout 日志
  - **退出** — 停止 harness 并退出托盘（全部退出）
- **双击托盘图标** = 打开界面
- **harness 意外退出**：托盘气泡提示「已停止」并自动收起
- **控制台模式**：双击安装目录的 `launch.bat`，前台运行、日志直出（窗口关掉即停止）

## 配置

安装器在安装目录（`%LOCALAPPDATA%\Programs\DSHTray\`）生成 `dsh-tray.config.json`，全部字段可选：

```json
{
  "dshBin": "C:\\...\\node_modules\\@deepseek-ai\\dsh\\lib\\bin.js",
  "node":   "C:\\Program Files\\nodejs\\node.exe",
  "url":    "http://127.0.0.1:3080",
  "icon":   "C:\\...\\icon.ico",
  "cwd":    "C:\\Users\\<you>"
}
```

`dshBin` / `node` / `icon` 缺省时按「npm 全局 → npx 缓存 → PATH → 常见路径」顺序自动探测。

## 卸载

1. 托盘右键「退出」（或直接结束进程）；
2. 删除桌面快捷方式（以及启动文件夹里的开机自启副本，若安装时用了 `-Autostart`）；
3. 删除安装目录 `%LOCALAPPDATA%\Programs\DSHTray\`。

## 常见问题

**托盘图标看不到？**
Windows 会把不常用的新图标收进通知区「^」折叠区，点开小箭头看看；或把图标拖到常显区。

**重复点快捷方式会开两个 harness 吗？**
不会。托盘脚本带单实例互斥锁，第二个实例只会唤起已有界面后退出。

**报「未找到 dsh CLI」？**
用 `install.ps1 -DshPath <bin.js 路径>` 重新安装并手动指定；`bin.js` 一般在 `node_modules\@deepseek-ai\dsh\lib\bin.js`。

**想换图标？**
重新跑一遍安装器并传 `-Icon`；图标会同步应用到托盘与快捷方式。

**harness 更新后路径变了？**
重跑安装器即可（自动重新探测 dsh 位置并更新配置）。

## 已知限制

- 「退出 / 停止」通过端口占用者与「命令行含 `dsh` 的 node.exe 进程」定位并结束 harness；若你同时跑着其他命令行里带 `dsh` 字样的 node 进程，可能被一并结束
- 单实例互斥锁在**同一用户会话**内有效；不同用户/会话可各开一套
- 端口检测依赖 `Get-NetTCPConnection`（Windows 8+ 内置），固定端口 `3080`（可经配置 `url` 调整展示，但监听端口由 dsh 自身配置决定）
- 仓库不附带图标资产；如需使用第三方图片（如 liang-intensity-calibrator 的画像），请自行确认其授权
- 本工具只负责启动/常驻，不接管 dsh 的升级、多 profile 等能力

## 许可

MIT © 2026 fancr-code

## 致谢

托盘形态与无窗口化思路参考了社区各类 dsh 桌面工具的实践；本地使用的梁祖图标来自 [liang-intensity-calibrator](https://github.com/Lichtspektrum/liang-intensity-calibrator) 项目（未随本仓库分发）。
