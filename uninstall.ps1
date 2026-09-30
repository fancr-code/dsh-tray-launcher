# dsh-tray-launcher 一键卸载
# 用法: powershell -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1
# 远程: powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/fancr-code/dsh-tray-launcher/main/uninstall.ps1 | iex"
#
# 会一并注销已注册的"用量仪表"插件（安装目录被删掉后，profile 里那条 link 会指向
# 不存在的路径，所以必须一起清理）。用 -KeepUsageMeter 可保留注册。
param(
    [string]$ShortcutName = "DeepSeek Harness",
    [switch]$KeepUsageMeter,
    [switch]$DryRun
)

$ErrorActionPreference = 'SilentlyContinue'
$InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\DSHTray'
$ConfigPath = Join-Path $InstallDir 'dsh-tray.config.json'
$Profile = 'web'
$configuredShortcut = ''

Write-Host '开始卸载 dsh-tray-launcher ...'
if ($DryRun) { Write-Host '(DryRun: 只打印将执行的操作，不实际修改)' }

# ---- 读取配置，拿到托盘实际用的 dsh CLI 与插件目录（找不到就用默认值）----
$dshBin = ''
$pluginDir = Join-Path $InstallDir 'plugins\usage-meter'
if (Test-Path $ConfigPath) {
    try {
        # -Encoding UTF8 不能省：PS 5.1 默认按 ANSI 解码无 BOM 的 UTF-8
        $cfg = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($cfg.dshBin) { $dshBin = $cfg.dshBin }
        if ($cfg.pluginDir) { $pluginDir = $cfg.pluginDir }
        if ($cfg.shortcut) { $configuredShortcut = "$($cfg.shortcut)" }
    } catch {}
}
if (-not $dshBin) {
    foreach ($r in @($env:NPM_CONFIG_PREFIX, (Join-Path $env:APPDATA 'npm'), 'D:\apps\npm')) {
        if (-not $r) { continue }
        $c = Join-Path $r 'node_modules\@deepseek-ai\dsh\lib\bin.js'
        if (Test-Path $c) { $dshBin = $c; break }
    }
}
$node = ''
foreach ($c in @('D:\apps\nodejs\node.exe', 'C:\Program Files\nodejs\node.exe')) { if (Test-Path $c) { $node = $c; break } }
if (-not $node) { $c = Get-Command node.exe -ErrorAction SilentlyContinue; if ($c) { $node = $c.Source } }

# ---- 1) 结束托盘进程 ----
$trayProcs = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match '(?i)(?:tray\.ps1|dsh-tray(?:\.js)?)(?![-\w])' }
if ($trayProcs) {
    foreach ($p in $trayProcs) {
        if ($DryRun) { Write-Host ('将结束托盘进程 PID ' + $p.ProcessId) }
        else { Stop-Process -Id $p.ProcessId -Force }
    }
} else {
    Write-Host '没有正在运行的托盘进程'
}

# ---- 2) 注销用量仪表（放在删除安装目录之前：注册里存的路径就在安装目录下）----
$usageMeterCleanupOk = $true
if ($KeepUsageMeter) {
    Write-Host '按 -KeepUsageMeter 保留用量仪表注册'
} elseif (-not $node -or -not $dshBin -or -not (Test-Path $dshBin)) {
    Write-Host '未找到 dsh CLI，跳过量表注销；如需清理由你手动执行:'
    Write-Host ('  dsh plugin --profile ' + $Profile + ' remove dsh-plugin-usage-meter')
    $usageMeterCleanupOk = $false
} else {
    $dump = (& $node $dshBin --profile $Profile --dump-config 2>&1 | Out-String)
    $dumpExitCode = $LASTEXITCODE
    if ($dumpExitCode -ne 0) {
        Write-Host ('无法确认用量仪表注册状态（退出码 ' + $dumpExitCode + '），保留安装目录供重试')
        $usageMeterCleanupOk = $false
    } elseif ($dump -match 'dsh-plugin-usage-meter') {
        if ($DryRun) {
            Write-Host ('将注销用量仪表: dsh plugin --profile ' + $Profile + ' remove dsh-plugin-usage-meter')
        } else {
            & $node $dshBin plugin --profile $Profile remove dsh-plugin-usage-meter 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { Write-Host '已从 profile 注销用量仪表' }
            else {
                Write-Host ('用量仪表注销失败（退出码 ' + $LASTEXITCODE + '），可手动执行 dsh plugin --profile ' + $Profile + ' remove dsh-plugin-usage-meter')
                $usageMeterCleanupOk = $false
            }
        }
    } else {
        Write-Host '用量仪表本来就不在 profile 里，无需注销'
    }
}

# ---- 3) 删除桌面快捷方式 + 开机自启副本 ----
$cleanupOk = $true
$shortcutCandidates = @(
    (Join-Path ([Environment]::GetFolderPath('Desktop')) ($ShortcutName + '.lnk')),
    (Join-Path ([Environment]::GetFolderPath('Startup')) ($ShortcutName + '.lnk'))
)
if ($configuredShortcut) {
    $shortcutCandidates += $configuredShortcut
    $shortcutCandidates += (Join-Path ([Environment]::GetFolderPath('Startup')) ([System.IO.Path]::GetFileName($configuredShortcut)))
}
foreach ($shortcutPath in @($shortcutCandidates | Where-Object { $_ } | Select-Object -Unique)) {
    if (Test-Path $shortcutPath) {
        if ($DryRun) {
            Write-Host ('将删除: ' + $shortcutPath)
        } else {
            try { Remove-Item $shortcutPath -Force -ErrorAction Stop; Write-Host ('已删除: ' + $shortcutPath) }
            catch { Write-Host ('快捷方式删除失败: ' + $_.Exception.Message); $cleanupOk = $false }
        }
    }
}

# ---- 4) 删除安装目录（含插件副本、日志、自定义图标）----
if (Test-Path $InstallDir -and $usageMeterCleanupOk) {
    if ($DryRun) {
        if ($KeepUsageMeter) { Write-Host ('将删除启动器文件，保留用量仪表: ' + (Join-Path $InstallDir 'plugins')) }
        else { Write-Host ('将删除: ' + $InstallDir) }
    } elseif ($KeepUsageMeter) {
        try {
            Get-ChildItem $InstallDir -Force | Where-Object { $_.Name -ne 'plugins' } | Remove-Item -Recurse -Force -ErrorAction Stop
            Write-Host ('已删除启动器文件，保留用量仪表: ' + (Join-Path $InstallDir 'plugins'))
        } catch { Write-Host ('启动器文件删除失败: ' + $_.Exception.Message); $cleanupOk = $false }
    } else {
        try { Remove-Item $InstallDir -Recurse -Force -ErrorAction Stop; Write-Host ('已删除: ' + $InstallDir) }
        catch { Write-Host ('安装目录删除失败: ' + $_.Exception.Message); $cleanupOk = $false }
    }
} elseif (Test-Path $InstallDir) {
    Write-Host ('未删除安装目录，待完成用量仪表注销后重试: ' + $InstallDir)
}

Write-Host ''
if ($DryRun) {
    Write-Host 'DryRun 结束：以上为将执行的操作，未做任何修改。'
} elseif (-not $usageMeterCleanupOk -or -not $cleanupOk) {
    Write-Host '卸载未完成：用量仪表仍可能注册，请修复后重新运行卸载器。'
    exit 1
} else {
    Write-Host '卸载完成。'
    Write-Host '如果当时是用 npm 装的，再执行: npm uninstall -g dsh-tray-launcher'
}
