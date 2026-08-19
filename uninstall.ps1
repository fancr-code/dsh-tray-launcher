# dsh-tray-launcher 一键卸载
# 用法: powershell -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1
# 远程: powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/fancr-code/dsh-tray-launcher/main/uninstall.ps1 | iex"
param(
    [string]$ShortcutName = "DeepSeek Harness"
)

$ErrorActionPreference = 'SilentlyContinue'
$InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\DSHTray'

Write-Host '开始卸载 dsh-tray-launcher ...'

# 1) 结束托盘进程
$trayProcs = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
    Where-Object { $_.CommandLine -match 'dsh-tray' }
foreach ($p in $trayProcs) { Stop-Process -Id $p.ProcessId -Force }

# 2) 删除桌面快捷方式 + 开机自启副本
$desktopLnk = Join-Path ([Environment]::GetFolderPath('Desktop')) ($ShortcutName + '.lnk')
if (Test-Path $desktopLnk) { Remove-Item $desktopLnk -Force; Write-Host ('已删除: ' + $desktopLnk) }
$startupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) ($ShortcutName + '.lnk')
if (Test-Path $startupLnk) { Remove-Item $startupLnk -Force; Write-Host ('已删除: ' + $startupLnk) }

# 3) 删除安装目录
if (Test-Path $InstallDir) {
    Remove-Item $InstallDir -Recurse -Force
    Write-Host ('已删除: ' + $InstallDir)
}

Write-Host ''
Write-Host '卸载完成。'
Write-Host '如果当时是用 npm 装的，再执行: npm uninstall -g dsh-tray-launcher'
