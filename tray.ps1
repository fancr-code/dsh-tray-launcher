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
$node = Get-CfgValue 'node' ''
if (-not $node -or -not (Test-Path $node)) {
    $cmdNode = Get-Command node.exe -ErrorAction SilentlyContinue
    if ($cmdNode) { $node = $cmdNode.Source }
}
if (-not $node -or -not (Test-Path $node)) {
    $candidate = 'C:\Program Files\nodejs\node.exe'
    if (Test-Path $candidate) { $node = $candidate }
}

# ---- 定位 dsh CLI（lib/bin.js）----
function Find-DshBin {
    $manual = Get-CfgValue 'dshBin' ''
    if ($manual -and (Test-Path $manual)) { return $manual }
    $candidates = @()
    try {
        $g = & npm root -g 2>$null
        if ($g) { $candidates += (Join-Path $g '@deepseek-ai\dsh\lib\bin.js') }
    } catch {}
    $npxRoot = Join-Path $env:LOCALAPPDATA 'npm-cache\_npx'
    if (Test-Path $npxRoot) {
        $candidates += Get-ChildItem $npxRoot -Directory -ErrorAction SilentlyContinue |
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
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

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

# ---- 托盘图标与菜单 ----
$iconPath = Get-CfgValue 'icon' ''
if ($iconPath -and (Test-Path $iconPath)) {
    $icon = New-Object System.Drawing.Icon($iconPath)
} else {
    $icon = [System.Drawing.SystemIcons]::Application
}
$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = $icon
$tray.Text = 'DeepSeek Harness'
$tray.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miOpen = $menu.Items.Add('打开界面')
$miLog  = $menu.Items.Add('打开日志')
$sep    = New-Object System.Windows.Forms.ToolStripSeparator
$menu.Items.Add($sep) | Out-Null
$miExit = $menu.Items.Add('退出')
$tray.ContextMenuStrip = $menu

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
        $args = @('"' + $bin + '"', 'web')
        $script:proc = Start-Process -FilePath $node -ArgumentList $args -WorkingDirectory $cwd `
            -WindowStyle Hidden -RedirectStandardOutput $outLog -RedirectStandardError $errLog -PassThru
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
