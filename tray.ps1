# dsh-tray-launcher
# 以系统托盘方式运行 DeepSeek Harness (dsh web)：无窗口、托盘图标管理、端口就绪自动开浏览器。
#
# 托盘模式   : powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File tray.ps1
# 控制台模式 : powershell -NoProfile -ExecutionPolicy Bypass -File tray.ps1 -ConsoleMode
# 测试模式   : 追加 -NoOpen 不自动打开浏览器
param(
    [switch]$ConsoleMode,
    [switch]$NoOpen
)

$ErrorActionPreference = 'SilentlyContinue'

# ---- 配置（install.ps1 写入；所有字段可选，缺省自动探测）----
$script:cfg = $null
$configPath = Join-Path $PSScriptRoot 'dsh-tray.config.json'
if (Test-Path $configPath) {
    try { $script:cfg = Get-Content $configPath -Raw | ConvertFrom-Json } catch {}
}

function Get-CfgValue($name, $default) {
    if ($script:cfg) {
        $props = $script:cfg.PSObject.Properties.Name
        if ($props -contains $name) {
            $v = $script:cfg.$name
            if ($v -ne $null -and "$v".Trim() -ne '') { return "$v".Trim() }
        }
    }
    return $default
}

$url = Get-CfgValue 'url' 'http://127.0.0.1:3080'
$cwd = Get-CfgValue 'cwd' $env:USERPROFILE

# ---- 定位 node.exe ----
# 优先系统正式安装的 node：codex 等工具链的 node 可能是转发桩，
# 无窗标志传不到它重新拉起的真实 node 进程，会出现黑窗。
$script:systemNode = 'C:\Program Files\nodejs\node.exe'
$node = Get-CfgValue 'node' ''
if ($node -and $node -match 'codex' -and (Test-Path $script:systemNode)) { $node = $script:systemNode }
if (-not $node -or -not (Test-Path $node)) {
    $cmdNode = Get-Command node.exe -ErrorAction SilentlyContinue
    if ($cmdNode) { $node = $cmdNode.Source }
    if ($node -and $node -match 'codex' -and (Test-Path $script:systemNode)) { $node = $script:systemNode }
}
if (-not $node -or -not (Test-Path $node)) {
    if (Test-Path $script:systemNode) { $node = $script:systemNode }
}

# ---- 定位 dsh CLI（lib/bin.js）----
function Find-DshBin {
    $manual = Get-CfgValue 'dshBin' ''
    if ($manual -and (Test-Path $manual)) { return $manual }
    $candidates = @()
    # 1) dsh 命令在 PATH 上：从 .bin shim 反推真实 bin.js
    $cmd = Get-Command dsh -ErrorAction SilentlyContinue
    if ($cmd) {
        $binDir = Split-Path $cmd.Source -Parent
        $candidates += (Join-Path (Split-Path $binDir -Parent) '@deepseek-ai\dsh\lib\bin.js')
    }
    # 2) 当前 npm 的缓存目录（纯 PowerShell 探测，绝不执行外部命令：
    #    无控制台进程执行外部命令会触发 PowerShell 分配可见控制台=黑窗）
    $cacheDirs = @()
    if ($env:NPM_CONFIG_CACHE) { $cacheDirs += $env:NPM_CONFIG_CACHE }
    foreach ($rc in @((Join-Path $env:USERPROFILE '.npmrc'), (Join-Path $env:APPDATA 'npm\etc\npmrc'))) {
        if (Test-Path $rc) {
            $m = Select-String -Path $rc -Pattern '^\s*cache\s*=\s*(.+)\s*$' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($m) {
                $v = (($m.Lines | Select-Object -First 1) -split '=', 2)[1].Trim()
                if ($v) { $cacheDirs += $v }
            }
        }
    }
    $cacheDirs += (Join-Path $env:LOCALAPPDATA 'npm-cache')
    foreach ($cache in $cacheDirs) {
        $npxDir = Join-Path $cache '_npx'
        if (Test-Path $npxDir) {
            $candidates += Get-ChildItem $npxDir -Directory -ErrorAction SilentlyContinue |
                ForEach-Object { Join-Path $_.FullName 'node_modules\@deepseek-ai\dsh\lib\bin.js' }
        }
    }
    # 3) npm 全局安装（环境变量 / .npmrc prefix / 默认位置）
    $globalRoots = @()
    if ($env:NPM_CONFIG_PREFIX) { $globalRoots += $env:NPM_CONFIG_PREFIX }
    foreach ($rc in @((Join-Path $env:USERPROFILE '.npmrc'), (Join-Path $env:APPDATA 'npm\etc\npmrc'))) {
        if (Test-Path $rc) {
            $m = Select-String -Path $rc -Pattern '^\s*prefix\s*=\s*(.+)\s*$' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($m) {
                $v = (($m.Lines | Select-Object -First 1) -split '=', 2)[1].Trim()
                if ($v) { $globalRoots += $v }
            }
        }
    }
    $globalRoots += (Join-Path $env:APPDATA 'npm')
    foreach ($g in $globalRoots) {
        if ($g) { $candidates += (Join-Path $g '@deepseek-ai\dsh\lib\bin.js') }
    }
    # 4) 常见兜底位置
    $localNpx = Join-Path $env:LOCALAPPDATA 'npm-cache\_npx'
    if (Test-Path $localNpx) {
        $candidates += Get-ChildItem $localNpx -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName 'node_modules\@deepseek-ai\dsh\lib\bin.js' }
    }
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) { return $c }
    }
    return $null
}
$bin = Find-DshBin

# ---- 控制台模式：前台运行，日志直接打到窗口 ----
if ($ConsoleMode) {
    if (-not $node -or -not (Test-Path $node)) { Write-Host 'node.exe 未找到'; exit 1 }
    if (-not $bin) {
        Write-Host '未找到 dsh CLI (lib/bin.js)。请先运行 install.ps1 -DshPath <bin.js 路径>，或手动安装 dsh。'
        exit 1
    }
    & $node $bin web
    exit $LASTEXITCODE
}

if (-not $bin) {
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show(
        '未找到 DeepSeek Harness CLI (lib/bin.js)。' + "`n" +
        '请运行 install.ps1 -DshPath <bin.js 路径> 重新安装，或确认已安装 dsh。',
        'DeepSeek Harness') | Out-Null
    exit 1
}

# ---- 托盘模式 ----
$script:TrayVersion = '1.1.13'
# 版本烙印：控制台标题（若有可见控制台，标题会显示实际运行的版本）与日志
try { $Host.UI.RawUI.WindowTitle = 'DSH-Tray v' + $script:TrayVersion } catch {}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# 强制消除控制台窗口：先按句柄隐藏（SW_HIDE），再释放控制台（FreeConsole）。
# 不依赖启动标志——部分机器上 -WindowStyle Hidden 会被 Windows Terminal 默认终端机制忽略。
try {
    Add-Type -Name K32Win -Namespace Win32 -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern bool FreeConsole();
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@
    [Win32.K32Win]::ShowWindow([Win32.K32Win]::GetConsoleWindow(), 0) | Out-Null
    [Win32.K32Win]::FreeConsole() | Out-Null
} catch {}

$logDir = Join-Path $PSScriptRoot 'logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$outLog  = Join-Path $logDir 'dsh-out.log'
$errLog  = Join-Path $logDir 'dsh-err.log'
$trayLog = Join-Path $logDir 'dsh-tray.log'

function Write-TrayLog($msg) {
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    Add-Content -Path $trayLog -Value $line -Encoding UTF8
}

# 单实例保护：托盘只允许一个
$createdNew = $null
$mutex = New-Object System.Threading.Mutex($true, 'Global\dsh-tray-launcher', [ref]$createdNew)
if (-not $createdNew) {
    Write-TrayLog 'another tray instance is running; opening UI and exiting'
    if (-not $NoOpen) { Start-Process $url }
    exit 0
}
Write-TrayLog 'tray launcher started'
Write-TrayLog ('dsh-tray-launcher version: ' + $script:TrayVersion)
Write-TrayLog ('node: ' + $node)
Write-TrayLog ('dsh bin: ' + $bin)

# ---- 托盘图标与菜单 ----
$script:PresetIcons = @{
    'liangzu'    = 'icons\liangzu.ico'
    'whale-girl' = 'icons\whale-girl.ico'
    'deepseek'   = 'icons\deepseek.ico'
}
$script:PresetLabels = @{
    'liangzu'    = '梁祖'
    'whale-girl' = '鲸鱼娘'
    'deepseek'   = 'DeepSeek'
}

function Resolve-IconPath {
    $v = Get-CfgValue 'icon' ''
    if ($v) {
        if ($script:PresetIcons.ContainsKey($v)) {
            $p = Join-Path $PSScriptRoot $script:PresetIcons[$v]
            if (Test-Path $p) { return $p }
        } elseif (Test-Path $v) {
            return $v
        }
    }
    $legacy = Join-Path $PSScriptRoot 'liangzu-icon.ico'
    if (Test-Path $legacy) { return $legacy }
    return $null
}

$script:currentIconKey = 'custom'
$v = Get-CfgValue 'icon' ''
if ($v -and $script:PresetIcons.ContainsKey($v)) { $script:currentIconKey = $v }
elseif ($v -eq '') { $script:currentIconKey = 'liangzu' }  # 未配置时默认梁祖

$iconPath = Resolve-IconPath
if ($iconPath) {
    try { $icon = New-Object System.Drawing.Icon($iconPath) } catch { $icon = [System.Drawing.SystemIcons]::Application }
} else {
    $icon = [System.Drawing.SystemIcons]::Application
}
$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = $icon
$tray.Text = 'DeepSeek Harness'
$tray.Visible = $true

# ---- 图标切换：更新托盘 + 配置 + 桌面/自启快捷方式 ----
function Update-ShortcutIcon($icoPath) {
    if (-not $icoPath -or -not (Test-Path $icoPath)) { return }
    try {
        $ws = New-Object -ComObject WScript.Shell
        $shortcutPath = Get-CfgValue 'shortcut' ''
        if ($shortcutPath -and (Test-Path $shortcutPath)) {
            $lnk = $ws.CreateShortcut($shortcutPath)
            $lnk.IconLocation = $icoPath + ',0'
            $lnk.Save()
        }
        $name = [System.IO.Path]::GetFileName($shortcutPath)
        if ($name) {
            $autoPath = Join-Path ([Environment]::GetFolderPath('Startup')) $name
            if (Test-Path $autoPath) {
                $lnk2 = $ws.CreateShortcut($autoPath)
                $lnk2.IconLocation = $icoPath + ',0'
                $lnk2.Save()
            }
        }
        Write-TrayLog ('shortcut icon updated: ' + $icoPath)
    } catch {
        Write-TrayLog ('shortcut icon update failed: ' + $_.Exception.Message)
    }
}

function Save-IconConfig($value) {
    $cfg = $null
    try { $cfg = Get-Content $configPath -Raw | ConvertFrom-Json } catch {}
    if (-not $cfg) { $cfg = [pscustomobject]@{} }
    $cfg | Add-Member -MemberType NoteProperty -Name 'icon' -Value $value -Force
    $cfg | ConvertTo-Json | Set-Content -Path $configPath -Encoding UTF8
    $script:cfg = $cfg
}

function Apply-Icon($key, $icoPath) {
    if (-not $icoPath -or -not (Test-Path $icoPath)) {
        Write-TrayLog ('icon missing: ' + $key)
        return
    }
    try {
        $newIcon = New-Object System.Drawing.Icon($icoPath)
        $tray.Icon = $newIcon
    } catch {
        Write-TrayLog ('icon load failed: ' + $_.Exception.Message)
        return
    }
    $script:currentIconKey = $key
    Save-IconConfig $key
    Update-ShortcutIcon $icoPath
    Update-IconMenuChecks
    $label = if ($script:PresetLabels.ContainsKey($key)) { $script:PresetLabels[$key] } else { '自定义图标' }
    $tray.BalloonTipTitle = 'DeepSeek Harness'
    $tray.BalloonTipText = ('已切换图标：' + $label)
    $tray.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
    $tray.ShowBalloonTip(2000)
    Write-TrayLog ('icon switched to ' + $key)
}

function Update-IconMenuChecks {
    foreach ($it in $script:presetMenuItems.Values) {
        $it.Checked = ($it.Tag -eq $script:currentIconKey)
    }
    $script:customMenuItem.Checked = ($script:currentIconKey -eq 'custom')
}

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miOpen = $menu.Items.Add('打开界面')
$miLog  = $menu.Items.Add('打开日志')
$sep    = New-Object System.Windows.Forms.ToolStripSeparator
$menu.Items.Add($sep) | Out-Null

# 切换图标子菜单（预设 + 自定义）
$miIcon = New-Object System.Windows.Forms.ToolStripMenuItem('切换图标')
$script:presetMenuItems = @{}
foreach ($key in @('liangzu', 'whale-girl', 'deepseek')) {
    $item = New-Object System.Windows.Forms.ToolStripMenuItem($script:PresetLabels[$key])
    $item.Tag = $key
    $item.add_Click({
        $k = $this.Tag
        $p = Join-Path $PSScriptRoot $script:PresetIcons[$k]
        Apply-Icon $k $p
    })
    $miIcon.DropDownItems.Add($item) | Out-Null
    $script:presetMenuItems[$key] = $item
}
$sep2 = New-Object System.Windows.Forms.ToolStripSeparator
$miIcon.DropDownItems.Add($sep2) | Out-Null
$script:customMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem('自定义…')
$script:customMenuItem.add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = '图标文件 (*.ico)|*.ico|所有文件 (*.*)|*.*'
    $dlg.Title = '选择图标（.ico）'
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $dest = Join-Path $PSScriptRoot 'custom.ico'
        Copy-Item $dlg.FileName $dest -Force
        Apply-Icon $dest $dest
    }
})
$miIcon.DropDownItems.Add($script:customMenuItem) | Out-Null
$menu.Items.Add($miIcon) | Out-Null

$sep3 = New-Object System.Windows.Forms.ToolStripSeparator
$menu.Items.Add($sep3) | Out-Null
$miExit = $menu.Items.Add('退出')
$tray.ContextMenuStrip = $menu
Update-IconMenuChecks

$miOpen.add_Click({ Start-Process $url })
$miLog.add_Click({ Start-Process notepad $outLog })

# ---- 停止 Harness（端口占用者 + 命令行含 dsh 的 node 进程）----
function Stop-Harness {
    $pids = @()
    try {
        $owner = Get-NetTCPConnection -LocalPort 3080 -State Listen -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty OwningProcess
        if ($owner) { $pids += $owner }
    } catch {}
    try {
        $dshProcs = Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" |
            Where-Object { $_.CommandLine -match 'dsh' } |
            Select-Object -ExpandProperty ProcessId
        $pids += $dshProcs
    } catch {}
    $pids | Where-Object { $_ } | Sort-Object -Unique | ForEach-Object {
        Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue
    }
    Write-TrayLog 'stop requested'
}

$miExit.add_Click({
    # 退出 = 全部退出：先停 harness，再关托盘
    Write-TrayLog 'exit requested: stopping harness and closing tray'
    Stop-Harness
    $tray.Visible = $false
    [System.Windows.Forms.Application]::Exit()
})
$tray.add_DoubleClick({ Start-Process $url })

# ---- 启动 harness（已运行则只挂托盘）----
$script:spawned = $false
$script:proc = $null

$already = Get-NetTCPConnection -LocalPort 3080 -State Listen -ErrorAction SilentlyContinue
if ($already) {
    Write-TrayLog 'harness already listening on 3080; tray attached'
    $tray.BalloonTipTitle = 'DeepSeek Harness'
    $tray.BalloonTipText = '已在运行'
    $tray.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
    $tray.ShowBalloonTip(2500)
} else {
    try {
        # 启动 harness：用 CreateNoWindow（CREATE_NO_WINDOW）从 API 层面禁止控制台——
        # 部分机器上 Start-Process -WindowStyle Hidden 会被忽略，导致黑窗。
        # 经 cmd /c 中转以保留日志重定向（>> 追加，无缓冲区死锁）。
        $cmdLine = '/c ""' + $node + '" "' + $bin + '" web >> "' + $outLog + '" 2>> "' + $errLog + '" "'
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $env:ComSpec
        $psi.Arguments = $cmdLine
        $psi.WorkingDirectory = $cwd
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $script:proc = New-Object System.Diagnostics.Process
        $script:proc.StartInfo = $psi
        [void]$script:proc.Start()
        $script:spawned = $true
        Write-TrayLog ('harness started hidden, pid ' + $script:proc.Id)
        $tray.BalloonTipTitle = 'DeepSeek Harness'
        $tray.BalloonTipText = '正在启动…'
        $tray.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
        $tray.ShowBalloonTip(2000)
    } catch {
        Write-TrayLog ('start failed: ' + $_.Exception.Message)
        $tray.BalloonTipTitle = 'DeepSeek Harness'
        $tray.BalloonTipText = '启动失败，详见日志'
        $tray.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Error
        $tray.ShowBalloonTip(3000)
    }
}

# ---- 轮询：端口就绪后打开浏览器；监视退出 ----
$script:opened = $false
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 3000
$timer.add_Tick({
    if (-not $NoOpen -and -not $script:opened) {
        $l = Get-NetTCPConnection -LocalPort 3080 -State Listen -ErrorAction SilentlyContinue
        if ($l) {
            $script:opened = $true
            Start-Process $url
            Write-TrayLog 'browser opened'
        }
    }
    if ($script:spawned -and $script:proc -and $script:proc.HasExited) {
        Write-TrayLog 'harness exited'
        $tray.BalloonTipTitle = 'DeepSeek Harness'
        $tray.BalloonTipText = '已停止'
        $tray.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Warning
        $tray.ShowBalloonTip(2500)
        Start-Sleep -Seconds 2
        $tray.Visible = $false
        [System.Windows.Forms.Application]::Exit()
    }
})
$timer.Start()

# ---- 消息循环 ----
[System.Windows.Forms.Application]::Run()

# ---- 清理 ----
$timer.Stop()
$tray.Visible = $false
$tray.Dispose()
try { $mutex.ReleaseMutex() } catch {}
Write-TrayLog 'tray launcher exited'
