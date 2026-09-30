# dsh-tray-launcher
# 以系统托盘方式运行 DeepSeek Harness (dsh web)：无窗口、托盘图标管理、端口就绪自动开浏览器。
#
# 托盘模式   : powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File tray.ps1
# 控制台模式 : powershell -NoProfile -ExecutionPolicy Bypass -File tray.ps1 -ConsoleMode
# 测试模式   : 追加 -NoOpen 不自动打开浏览器
# -NoRespawn : 内部参数（无窗口重启自身时使用，防止循环）
# -InstanceId: 单实例互斥体名（默认 dsh-tray-launcher）。多个 dsh profile 各跑一个托盘时
#              传不同值；测试也靠它隔离，避免被用户正在运行的托盘挡住。
param(
    [switch]$ConsoleMode,
    [switch]$NoOpen,
    [switch]$NoRespawn,
    [string]$DataDir = '',
    [string]$InstanceId = 'dsh-tray-launcher'
)

# 状态目录：默认与脚本同目录（install.ps1 部署方式）；以 dsh 插件方式运行时
# 由 src/plugin.js 传入 -DataDir，避免把配置与日志写进 node_modules。
if ($DataDir.Trim() -ne '') { $script:dataDir = $DataDir.Trim() } else { $script:dataDir = $PSScriptRoot }

$ErrorActionPreference = 'SilentlyContinue'

# ---- 配置（install.ps1 写入；所有字段可选，缺省自动探测）----
$script:cfg = $null
$configPath = Join-Path $script:dataDir 'dsh-tray.config.json'
# 必须显式 -Encoding UTF8：Windows PowerShell 5.1 默认按 ANSI 解码无 BOM 的 UTF-8，
# 配置里只要有一个中文字符就会解析失败（静默回落到默认值）。
if (Test-Path $configPath) {
    try { $script:cfg = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
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
# Web 端口：从配置 url 里解析（杀 3080 监听者、重启前等端口都用它；缺省 3080）
$script:webPort = 3080
if ($url -match '://[^/]+:(\d+)') { $script:webPort = [int]$Matches[1] }

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
# 版本号优先读部署目录里的 package.json（install.ps1 会一并拷贝；npm 全局包目录本来就有）。
# 读不到（远程安装/手工拷贝的单文件部署）才退回下面这个硬编码值——发版时记得一起改。
$script:TrayVersion = '1.5.5'
function Get-PackageVersion($dir) {
    if (-not $dir) { return '' }
    $pk = Join-Path $dir 'package.json'
    if (-not (Test-Path $pk)) { return '' }
    try {
        $v = (Get-Content $pk -Raw -Encoding UTF8 | ConvertFrom-Json).version
        if ($v -and "$v".Trim() -match '^[0-9]+\.[0-9]+\.[0-9]+') { return $Matches[0] }
    } catch {}
    return ''
}

# 优先按实际部署位置判定：插件方式（-DataDir）下 dataDir 没有 package.json，
# 脚本自身所在的包目录才是权威来源。
foreach ($verDir in @($script:dataDir, $PSScriptRoot)) {
    $pv = Get-PackageVersion $verDir
    if ($pv) { $script:TrayVersion = $pv; break }
}
# 版本烙印：控制台标题（若有可见控制台，标题会显示实际运行的版本）与日志
try { $Host.UI.RawUI.WindowTitle = 'DSH-Tray v' + $script:TrayVersion } catch {}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# 快路径：按句柄隐藏（SW_HIDE）并释放控制台（FreeConsole）。
# 不依赖启动标志——部分机器上 -WindowStyle Hidden 会被 Windows Terminal 默认终端机制忽略。
try {
    Add-Type -Name K32Win -Namespace Win32 -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern bool FreeConsole();
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
'@
    [Win32.K32Win]::ShowWindow([Win32.K32Win]::GetConsoleWindow(), 0) | Out-Null
    [Win32.K32Win]::FreeConsole() | Out-Null
} catch {}

# 工作集回收用的 P/Invoke（与上面分开声明：即使控制台隐藏那段被策略禁用，
# 内存回收仍可用；反之亦然）。
try {
    Add-Type -Name K32Mem -Namespace Win32 -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetCurrentProcess();
[DllImport("psapi.dll")] public static extern bool EmptyWorkingSet(IntPtr hProcess);
'@
} catch {}

# 可见控制台判定：优先用 GetConsoleWindow + IsWindowVisible（准确），
# 取不到再退回 Console.WindowWidth（有控制台才 > 0，无控制台会抛错）。
function Test-VisibleConsole {
    try {
        if ([Win32.K32Win]) {
            $hwnd = [Win32.K32Win]::GetConsoleWindow()
            if ($hwnd -eq [IntPtr]::Zero) { return $false }
            return [Win32.K32Win]::IsWindowVisible($hwnd)
        }
    } catch {}
    try { return ([System.Console]::WindowWidth -gt 0) } catch { return $false }
}

# 兜底：若仍持有可见控制台（Add-Type 被策略禁用 / 隐藏失败），用 CreateNoWindow
# 无窗口重启自身后退出——原进程退出即销毁其控制台窗口，无需任何 C# 编译。
# 注意：脚本开关（-NoRespawn / -DataDir）必须写在 -File <路径> 之前，
# 否则 powershell.exe 会把它们当成命令而不是参数。
if (-not $NoRespawn -and (Test-VisibleConsole)) {
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'powershell.exe'
        $respawnArgs = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -NoRespawn'
        if ($script:dataDir -ne $PSScriptRoot) { $respawnArgs = $respawnArgs + ' -DataDir "' + $script:dataDir + '"' }
        $psi.Arguments = $respawnArgs + ' -File "' + $PSCommandPath + '"'
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        [System.Diagnostics.Process]::Start($psi) | Out-Null
    } catch {}
    exit 0
}

$logDir = Join-Path $script:dataDir 'logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$outLog  = Join-Path $logDir 'dsh-out.log'
$errLog  = Join-Path $logDir 'dsh-err.log'
$trayLog = Join-Path $logDir 'dsh-tray.log'
# 托盘自身动作（自更新 / 插件注册与卸载）的专属日志。绝不能复用 dsh-out.log / dsh-err.log：
# 那两个文件被常驻的 Harness 进程以独占写方式持有，cmd 的 >> 打不开就直接以退出码 1
# 结束，且报错也无处可写（正是自更新"退出码 1 且零输出"的根因）。
$updateOutLog = Join-Path $logDir 'dsh-update-out.log'
$updateErrLog = Join-Path $logDir 'dsh-update-err.log'
$pluginLogs = @{
    'add'    = @{ Out = (Join-Path $logDir 'dsh-plugin-out.log');    Err = (Join-Path $logDir 'dsh-plugin-err.log') }
    'remove' = @{ Out = (Join-Path $logDir 'dsh-plugin-rm-out.log'); Err = (Join-Path $logDir 'dsh-plugin-rm-err.log') }
}

function Write-TrayLog($msg) {
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    Add-Content -Path $trayLog -Value $line -Encoding UTF8
}

function Show-TrayBalloon($text, $icon) {
    $tray.BalloonTipTitle = 'DeepSeek Harness'
    $tray.BalloonTipText = $text
    $tray.BalloonTipIcon = $icon
    $tray.ShowBalloonTip(3000)
}

# 截取日志尾部作为气泡内容：失败时把真实报错直接摆在用户面前，而不是"详见日志"。
function Get-LogTail($path, $lines = 3) {
    try {
        if (-not (Test-Path $path)) { return '' }
        $t = (Get-Content $path -Tail $lines -ErrorAction SilentlyContinue) -join ' / '
        if ("$t".Length -gt 220) { $t = "$t".Substring(0, 220) + '…' }
        return "$t".Trim()
    } catch { return '' }
}

# ---- 界面地址解析 ----
# 新版 dsh web（≥0.1.7）给 Web UI 加了鉴权：只有带 `?token=` 的地址能直接打开，
# 用裸地址会被要求“reopen the URL printed by dsh web”。托盘从 harness 的 stdout
# 日志里取最后一次打印的带 token 地址；取不到（旧版 harness）再退回配置里的 url。
$script:harnessUrl = $null
function Get-HarnessUrl {
    if ($script:harnessUrl) { return $script:harnessUrl }
    try {
        if (Test-Path $outLog) {
            $m = Select-String -Path $outLog -Pattern 'dsh web:\s+(https?://\S+)' -AllMatches -ErrorAction SilentlyContinue |
                Select-Object -Last 1
            if ($m) {
                $u = $m.Matches[$m.Matches.Count - 1].Groups[1].Value.Trim()
                if ($u -match '^https?://') { $script:harnessUrl = $u; return $u }
            }
        }
    } catch {}
    return $url
}

# 单实例保护：同名实例只允许一个（默认 Global\dsh-tray-launcher）
$createdNew = $null
$mutex = New-Object System.Threading.Mutex($true, ('Global\' + $InstanceId), [ref]$createdNew)
if (-not $createdNew) {
    # 上一个同名托盘被强杀时会留下"被放弃"的互斥体：此时当前线程已持有它，
    # 属于异常但可安全接手，不能误判成"已有实例"而直接退出（那会让托盘再也起不来）。
    $abandoned = $false
    try { [void]$mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $abandoned = $true } catch {}
    if ($abandoned) {
        Write-TrayLog 'previous tray instance was killed abruptly; taking over'
    } else {
        # 已有实例在跑（连点两次快捷方式 / 自启与插件同时拉起）：静默退出。
        # 这里绝不能再开浏览器——持有托盘的那个实例会在端口就绪后开且只开一次，
        # 本分支再开一次就是"启动时同时弹出多个浏览器界面"的来源之一。
        Write-TrayLog 'another tray instance is running; exiting silently'
        exit 0
    }
}
Write-TrayLog 'tray launcher started'
Write-TrayLog ('dsh-tray-launcher version: ' + $script:TrayVersion)
Write-TrayLog ('node: ' + $node)
Write-TrayLog ('dsh bin: ' + $bin)

# UI 线程兜底：菜单/定时器回调里的未处理异常默认会弹 ThreadExceptionDialog（模态、
# 托盘像死了一样只能杀进程）。接住、记日志、继续跑——长跑托盘不能被单个回调拖死。
try {
    [System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
    [System.Windows.Forms.Application]::add_ThreadException({
        param($sender, $e)
        Write-TrayLog ('ui thread exception: ' + $e.Exception.Message)
    })
} catch { }

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

function Save-CfgValue($name, $value) {
    $cfg = $null
    try { $cfg = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
    if (-not $cfg) { $cfg = [pscustomobject]@{} }
    $cfg | Add-Member -MemberType NoteProperty -Name $name -Value $value -Force
    $cfg | ConvertTo-Json | Set-Content -Path $configPath -Encoding UTF8
    $script:cfg = $cfg
}

function Save-IconConfig($value) {
    Save-CfgValue 'icon' $value
}

# ---- 内置用量仪表（dsh-plugin-usage-meter）----
function Compare-Version($a, $b) {
    $pa = @(); $pb = @()
    foreach ($x in ($a -split '\.')) { try { $pa += [int]$x } catch { $pa += 0 } }
    foreach ($x in ($b -split '\.')) { try { $pb += [int]$x } catch { $pb += 0 } }
    for ($i = 0; $i -lt 3; $i++) {
        $va = if ($i -lt $pa.Count) { $pa[$i] } else { 0 }
        $vb = if ($i -lt $pb.Count) { $pb[$i] } else { 0 }
        if ($va -gt $vb) { return 1 }
        if ($va -lt $vb) { return -1 }
    }
    return 0
}

function Find-BundledPlugin {
    # 纯 PowerShell 定位随包依赖（不执行任何外部命令，避免无控制台进程弹黑窗）。
    # 落点取决于这个包是怎么装的：
    #   ① 安装目录同级 / 包自身的 node_modules（npm install -g 的嵌套布局）
    #   ② npm 全局根下的 dsh-tray-launcher\node_modules\...
    #      —— 从开发检出运行时 $PSScriptRoot 下没有 node_modules，必须查这里
    #   ③ 全局根同级（pnpm 提升布局）
    $cands = @(
        (Join-Path $PSScriptRoot 'node_modules\dsh-plugin-usage-meter'),
        (Join-Path (Split-Path $PSScriptRoot -Parent) 'node_modules\dsh-plugin-usage-meter'),
        (Join-Path (Split-Path $PSScriptRoot -Parent) 'dsh-plugin-usage-meter')
    )
    if ($script:dataDir -ne $PSScriptRoot) {
        $cands += (Join-Path $script:dataDir 'node_modules\dsh-plugin-usage-meter')
    }
    $globalRoots = @()
    if ($env:NPM_CONFIG_PREFIX) { $globalRoots += $env:NPM_CONFIG_PREFIX }
    foreach ($rc in @((Join-Path $env:USERPROFILE '.npmrc'))) {
        if (Test-Path $rc) {
            $m = Select-String -Path $rc -Pattern '^\s*prefix\s*=\s*(.+)\s*$' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($m) {
                $v = (($m.Lines | Select-Object -First 1) -split '=', 2)[1].Trim()
                if ($v) { $globalRoots += $v }
            }
        }
    }
    $globalRoots += (Join-Path $env:APPDATA 'npm')
    foreach ($r in $globalRoots) {
        if (-not $r) { continue }
        $cands += (Join-Path $r 'dsh-tray-launcher\node_modules\dsh-plugin-usage-meter')
        $cands += (Join-Path $r 'dsh-plugin-usage-meter')
    }
    foreach ($c in $cands) {
        if ($c -and (Test-Path (Join-Path $c 'package.json'))) { return $c }
    }
    return $null
}

function Find-NpmCmd {
    if ($node -and (Test-Path $node)) {
        $p = Join-Path (Split-Path $node -Parent) 'npm.cmd'
        if (Test-Path $p) { return $p }
    }
    $c = Get-Command npm.cmd -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $c2 = Get-Command npm -ErrorAction SilentlyContinue
    if ($c2) { return $c2.Source }
    return $null
}

function New-HiddenProcess($cmdLine, $workDir) {
    # cmd /c + 重定向的隐藏进程模板：CreateNoWindow 防黑窗，
    # UseShellExecute=false + 关闭 stdin 防子进程等待输入而挂死。
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $env:ComSpec
    $psi.Arguments = $cmdLine
    if ($workDir) { $psi.WorkingDirectory = $workDir }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    return $p
}

function Start-LoggedCommand($cmdLine, $workDir) {
    # 启动并立即返回进程对象：调用方自行等待（异步路径用定时器轮询 HasExited）。
    $p = New-HiddenProcess $cmdLine $workDir
    [void]$p.Start()
    try { $p.StandardInput.Close() } catch {}
    return $p
}

function Wait-LoggedCommand($cmdLine, $timeoutMs, $workDir) {
    # 同步执行（仅用于必须拿到退出码才能继续的短命令）。
    $p = Start-LoggedCommand $cmdLine $workDir
    [void]$p.WaitForExit($timeoutMs)
    try { if (-not $p.HasExited) { $p.Kill() } } catch {}
    return $p.ExitCode
}

# ---- 自更新：日志文件与部署副本同步 ----
function Test-IsDeployed {
    # 只有"安装在 %LOCALAPPDATA%\Programs\DSHTray 的副本"才需要同步部署文件。
    # 从 npm 包目录或 git 检出里运行时不能覆盖自身（否则会污染检出或正在安装的包）。
    if (($PSScriptRoot -split '[\\/]') -contains 'node_modules') { return $false }
    if (Test-Path (Join-Path $PSScriptRoot '.git')) { return $false }
    return $true
}

function Sync-DeployedFiles($pkgDir) {
    # npm install -g 只更新全局包，不会动部署副本；不补这一步托盘重启后仍是旧版。
    $src = Join-Path $pkgDir 'tray.ps1'
    if (-not (Test-Path $src)) { Write-TrayLog ('deploy sync skipped: no tray.ps1 in ' + $pkgDir); return $false }
    Copy-Item $src (Join-Path $script:dataDir 'tray.ps1') -Force
    foreach ($f in @('launch-hidden.vbs', 'package.json')) {
        $s = Join-Path $pkgDir $f
        if (Test-Path $s) { Copy-Item $s (Join-Path $script:dataDir $f) -Force }
    }
    $iconDest = Join-Path $script:dataDir 'icons'
    New-Item -ItemType Directory -Path $iconDest -Force | Out-Null
    foreach ($f in @('liangzu.ico', 'whale-girl.ico', 'deepseek.ico')) {
        $s = Join-Path $pkgDir ('icons\' + $f)
        if (Test-Path $s) { Copy-Item $s (Join-Path $iconDest $f) -Force }
    }
    return $true
}

function Find-GlobalPackageDir($name) {
    # npm root -g 的结果写进临时文件：cmd /c 重定向需要无人占用的目标。
    $npm = Find-NpmCmd
    if (-not $npm) { return $null }
    $tmp = Join-Path $env:TEMP ('dsh-npm-root-' + [guid]::NewGuid().ToString('N') + '.txt')
    try {
        [void](Wait-LoggedCommand ('/c ""' + $npm + '" root -g > "' + $tmp + '" 2>nul "') 15000 $null)
        if (-not (Test-Path $tmp)) { return $null }
        $root = (Get-Content $tmp -Raw).Trim()
        if (-not $root) { return $null }
        $dir = Join-Path $root $name
        if (Test-Path (Join-Path $dir 'package.json')) { return $dir }
        return $null
    } catch {
        return $null
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Get-LatestTrayVersion {
    # 隐藏执行 npm view；结果写自有临时文件（重定向目标无人占用，这条路一直是通的）
    $npm = Find-NpmCmd
    if (-not $npm) { return '' }
    $tmp = Join-Path $script:dataDir 'npm-view.txt'
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    [void](Wait-LoggedCommand ('/c ""' + $npm + '" view dsh-tray-launcher version > "' + $tmp + '" 2>nul "') 20000 $null)
    try {
        if (Test-Path $tmp) {
            $v = (Get-Content $tmp -Raw).Trim()
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
            if ($v -match '^[0-9]+\.[0-9]+\.[0-9]+') { return $Matches[0] }
        }
    } catch {}
    return ''
}

function Start-PluginCommand($action, $target) {
    # 隐藏执行 dsh plugin add/remove（add 同路径幂等；路径变化则切换链接）。
    # 日志必须写专属文件：dsh-out/err.log 在 Harness 运行时被独占持有。
    $logs = $pluginLogs[$action]
    if (-not $logs) { $logs = $pluginLogs['add'] }
    $cmdLine = '/c ""' + $node + '" "' + $bin + '" plugin --profile web ' + $action + ' "' + $target + '" >> "' + $logs.Out + '" 2>> "' + $logs.Err + '" "'
    return Start-LoggedCommand $cmdLine $null
}

function Install-BundledUsageMeter($bundled) {
    # 把随包依赖复制到部署目录并注册进 web profile；返回 @{ Ok; Version; Error }
    # -Encoding UTF8 不能省：依赖的 package.json 带中文描述，PS 5.1 按 ANSI 读会解析失败
    $ver = ''
    try { $ver = (Get-Content (Join-Path $bundled 'package.json') -Raw -Encoding UTF8 | ConvertFrom-Json).version } catch {}
    $pluginDir = Get-CfgValue 'pluginDir' (Join-Path $script:dataDir 'plugins\usage-meter')
    try {
        New-Item -ItemType Directory -Path $pluginDir -Force | Out-Null
        foreach ($item in @('lib', 'cordis.patch.yml', 'package.json', 'README.md', 'LICENSE')) {
            $src = Join-Path $bundled $item
            if (Test-Path $src) { Copy-Item $src $pluginDir -Recurse -Force }
        }
        $p = Start-PluginCommand 'add' $pluginDir
        [void]$p.WaitForExit(120000)
        try { if (-not $p.HasExited) { $p.Kill() } } catch {}
        if ($p.ExitCode -ne 0) {
            # dsh plugin 是 pnpm 的转发器：机器上没有 pnpm 时必然失败
            $tail = Get-LogTail $pluginLogs['add'].Err 2
            $hint = if (-not (Get-Command pnpm -ErrorAction SilentlyContinue)) { '（未安装 pnpm：请先 npm install -g pnpm）' } else { '' }
            Write-TrayLog ('dsh plugin add exited ' + $p.ExitCode + ' ' + $tail)
            return @{ Ok = $false; Version = $ver; Error = ('注册失败（dsh plugin add 退出码 ' + $p.ExitCode + '）' + $hint + ' ' + $tail) }
        }
        Write-TrayLog ('dsh plugin add exited 0, usage meter v' + $ver)
        if ($ver) {
            Save-CfgValue 'pluginVersion' $ver
            Save-CfgValue 'pluginDir' $pluginDir
            $script:pluginVersion = $ver
        }
        return @{ Ok = $true; Version = $ver; Error = '' }
    } catch {
        Write-TrayLog ('usage meter install failed: ' + $_.Exception.Message)
        return @{ Ok = $false; Version = $ver; Error = $_.Exception.Message }
    }
}

function Test-PluginRegistered {
    # 判断用量仪表是否注册进 web profile（dump-config 不需要 pnpm）
    $tmp = Join-Path $script:dataDir 'dsh-plugin-dump.txt'
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    $cmdLine = '/c ""' + $node + '" "' + $bin + '" --profile web --dump-config > "' + $tmp + '" 2>nul "'
    [void](Wait-LoggedCommand $cmdLine 30000 $null)
    try {
        if (Test-Path $tmp) {
            return ((Get-Content $tmp -Raw -Encoding UTF8) -match 'dsh-plugin-usage-meter')
        }
    } catch {} finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
    return $false
}

function Remove-BundledUsageMeter {
    # 卸载用量仪表：注销 profile 注册 + 删除本地副本；返回 @{ Ok; Error }
    $pluginDir = Get-CfgValue 'pluginDir' (Join-Path $script:dataDir 'plugins\usage-meter')
    if (-not (Test-PluginRegistered)) {
        # 本来就没注册：只清本地副本与版本号，不去调 remove（否则必然报错）
        Write-TrayLog 'usage meter not registered; only removing local copy'
        if (Test-Path $pluginDir) {
            try { Remove-Item $pluginDir -Recurse -Force -ErrorAction Stop }
            catch { Write-TrayLog ('plugin dir removal failed: ' + $_.Exception.Message) }
        }
        Save-CfgValue 'pluginVersion' ''
        $script:pluginVersion = ''
        return @{ Ok = $true; Error = '' }
    }
    try {
        $p = Start-PluginCommand 'remove' 'dsh-plugin-usage-meter'
        [void]$p.WaitForExit(120000)
        try { if (-not $p.HasExited) { $p.Kill() } } catch {}
        if ($p.ExitCode -ne 0) {
            $tail = Get-LogTail $pluginLogs['remove'].Err 2
            $hint = if (-not (Get-Command pnpm -ErrorAction SilentlyContinue)) { '（未安装 pnpm：请先 npm install -g pnpm）' } else { '' }
            Write-TrayLog ('dsh plugin remove exited ' + $p.ExitCode + ' ' + $tail)
            return @{ Ok = $false; Error = ('注销失败（dsh plugin remove 退出码 ' + $p.ExitCode + '）' + $hint + ' ' + $tail) }
        }
        Write-TrayLog 'dsh plugin remove exited 0'
    } catch {
        Write-TrayLog ('usage meter remove failed: ' + $_.Exception.Message)
        return @{ Ok = $false; Error = $_.Exception.Message }
    }
    # 本地副本删不掉不算失败（profile 已注销，界面不再加载它）
    if (Test-Path $pluginDir) {
        try { Remove-Item $pluginDir -Recurse -Force -ErrorAction Stop }
        catch { Write-TrayLog ('plugin dir removal failed: ' + $_.Exception.Message) }
    }
    Save-CfgValue 'pluginVersion' ''
    Save-CfgValue 'pluginDir' ''
    $script:pluginVersion = ''
    return @{ Ok = $true; Error = '' }
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
        $dest = Join-Path $script:dataDir 'custom.ico'
        Copy-Item $dlg.FileName $dest -Force
        Apply-Icon $dest $dest
    }
})
$miIcon.DropDownItems.Add($script:customMenuItem) | Out-Null
$menu.Items.Add($miIcon) | Out-Null

# 开机自启（勾选 = 启动文件夹里有快捷方式；点击即切换）
function Get-ShortcutPath {
    $p = Get-CfgValue 'shortcut' ''
    if ($p -and (Test-Path $p)) { return $p }
    return $null
}
function Ensure-DesktopShortcut {
    $existing = Get-ShortcutPath
    if ($existing) { return $existing }
    try {
        $name = 'DeepSeek Harness'
        $desktop = [Environment]::GetFolderPath('Desktop')
        $lnkPath = Join-Path $desktop ($name + '.lnk')
        $ws = New-Object -ComObject WScript.Shell
        $lnk = $ws.CreateShortcut($lnkPath)
        $vbs = Join-Path $PSScriptRoot 'launch-hidden.vbs'
        if (Test-Path $vbs) {
            $lnk.TargetPath = 'C:\WINDOWS\System32\wscript.exe'
            $lnk.Arguments = '"' + $vbs + '"'
        } else {
            $lnk.TargetPath = 'C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe'
            $lnk.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $PSScriptRoot 'tray.ps1') + '"'
        }
        $lnk.WorkingDirectory = $PSScriptRoot
        $iconFile = Join-Path $PSScriptRoot 'icons\liangzu.ico'
        if (Test-Path $iconFile) { $lnk.IconLocation = $iconFile + ',0' }
        $lnk.Description = 'DeepSeek Harness 系统托盘启动器'
        $lnk.WindowStyle = 7
        $lnk.Save()
        Write-TrayLog ('desktop shortcut created: ' + $lnkPath)
        return $lnkPath
    } catch {
        Write-TrayLog ('shortcut creation failed: ' + $_.Exception.Message)
        return $null
    }
}
$script:miAutostart = New-Object System.Windows.Forms.ToolStripMenuItem('开机自启')
$script:miAutostart.CheckOnClick = $false
$script:miAutostart.add_Click({
    $shortcutPath = Ensure-DesktopShortcut
    if (-not $shortcutPath) {
        $tray.BalloonTipTitle = 'DeepSeek Harness'
        $tray.BalloonTipText = '未找到桌面快捷方式，无法设置开机自启'
        $tray.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Warning
        $tray.ShowBalloonTip(2500)
        return
    }
    $name = [System.IO.Path]::GetFileName($shortcutPath)
    $startupPath = Join-Path ([Environment]::GetFolderPath('Startup')) $name
    if (Test-Path $startupPath) {
        Remove-Item $startupPath -Force
        $script:miAutostart.Checked = $false
        $tray.BalloonTipTitle = 'DeepSeek Harness'
        $tray.BalloonTipText = '已关闭开机自启'
        Write-TrayLog 'autostart disabled'
    } else {
        Copy-Item $shortcutPath $startupPath -Force
        $script:miAutostart.Checked = $true
        $tray.BalloonTipTitle = 'DeepSeek Harness'
        $tray.BalloonTipText = '已开启开机自启'
        Write-TrayLog 'autostart enabled'
    }
    $tray.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
    $tray.ShowBalloonTip(2500)
})
$menu.Items.Add($script:miAutostart) | Out-Null
# 初始勾选状态：启动文件夹里存在对应快捷方式
$shortcutForCheck = Get-ShortcutPath
if ($shortcutForCheck) {
    $startupCheck = Join-Path ([Environment]::GetFolderPath('Startup')) ([System.IO.Path]::GetFileName($shortcutForCheck))
    $script:miAutostart.Checked = (Test-Path $startupCheck)
}

# 内置用量仪表：状态 + 一键更新
$script:pluginVersion = Get-CfgValue 'pluginVersion' ''
$script:miUsage = New-Object System.Windows.Forms.ToolStripMenuItem('用量仪表')
$script:miUsageStatus = New-Object System.Windows.Forms.ToolStripMenuItem('未安装')
$script:miUsageStatus.Enabled = $false
$script:miUsageUpdate = New-Object System.Windows.Forms.ToolStripMenuItem('更新用量仪表')
function Update-UsageStatusText {
    $ver = $script:pluginVersion
    if ($ver) { $script:miUsageStatus.Text = '当前 v' + $ver } else { $script:miUsageStatus.Text = '未安装' }
}
Update-UsageStatusText
$script:miUsageUpdate.add_Click({
    $bundled = Find-BundledPlugin
    if (-not $bundled) {
        Show-TrayBalloon '未找到随包的用量仪表（npm 依赖缺失）' ([System.Windows.Forms.ToolTipIcon]::Warning)
        return
    }
    $r = Install-BundledUsageMeter $bundled
    Update-UsageStatusText
    if ($r.Ok) {
        Show-TrayBalloon ('用量仪表已更新到 v' + $r.Version + '，请重启 Harness 生效（菜单 → 重启 Harness）') ([System.Windows.Forms.ToolTipIcon]::Info)
        Write-TrayLog ('usage meter updated to v' + $r.Version)
    } else {
        Show-TrayBalloon ('用量仪表更新失败：' + $r.Error) ([System.Windows.Forms.ToolTipIcon]::Error)
    }
})

# 卸载用量仪表：注销 profile 注册 + 删本地副本（用完菜单里不再显示"当前 vX"）
$script:miUsageRemove = New-Object System.Windows.Forms.ToolStripMenuItem('卸载用量仪表')
$script:miUsageRemove.add_Click({
    $r = Remove-BundledUsageMeter
    Update-UsageStatusText
    if ($r.Ok) {
        Show-TrayBalloon '用量仪表已卸载，重启 Harness 后从界面消失（菜单 → 重启 Harness）' ([System.Windows.Forms.ToolTipIcon]::Info)
        Write-TrayLog 'usage meter uninstalled'
    } else {
        Show-TrayBalloon ('用量仪表卸载失败：' + $r.Error) ([System.Windows.Forms.ToolTipIcon]::Error)
    }
})
$script:miUsage.DropDownItems.Add($script:miUsageStatus) | Out-Null
$script:miUsage.DropDownItems.Add($script:miUsageUpdate) | Out-Null
$script:miUsage.DropDownItems.Add($script:miUsageRemove) | Out-Null
$menu.Items.Add($script:miUsage) | Out-Null

# 启动器自更新：npm 查询最新版 + 一键更新（异步执行，不冻结托盘 UI）
$script:latestTrayVersion = ''
$script:selfCheckDone = $false
$script:updateProc = $null
$script:miSelf = New-Object System.Windows.Forms.ToolStripMenuItem('更新启动器')
$script:miSelfStatus = New-Object System.Windows.Forms.ToolStripMenuItem(('当前 v' + $script:TrayVersion))
$script:miSelfStatus.Enabled = $false
$script:miSelfCheck = New-Object System.Windows.Forms.ToolStripMenuItem('检查更新')
$script:miSelfUpdate = New-Object System.Windows.Forms.ToolStripMenuItem('更新到最新版')
$script:miSelfUpdate.Enabled = $false

# 轮询等待专用定时器：只等更新进程退出（500ms 粒度），比冻结消息循环好得多。
$script:waitTimer = New-Object System.Windows.Forms.Timer
$script:waitTimer.Interval = 500

function Complete-SelfUpdate($exitCode) {
    $newVer = $script:latestTrayVersion
    if (-not $newVer) { $newVer = Get-PackageVersion (Find-GlobalPackageDir 'dsh-tray-launcher') }
    if (-not $newVer) { $newVer = $script:TrayVersion }

    if ($exitCode -ne 0) {
        $tail = Get-LogTail $updateErrLog 2
        if (-not $tail) { $tail = Get-LogTail $updateOutLog 2 }
        $script:miSelfStatus.Text = ('当前 v' + $script:TrayVersion)
        Show-TrayBalloon ('更新失败（npm 退出码 ' + $exitCode + '）' + $tail) ([System.Windows.Forms.ToolTipIcon]::Error)
        Write-TrayLog ('tray launcher self-update failed, exit ' + $exitCode + ' ' + $tail)
        return
    }

    # 关键补充：npm install -g 只更新全局包目录，不刷新正在运行的手工部署副本，
    # 不补这一步就会出现"更新成功但重启后还是旧版"的死循环。
    $synced = $false
    $warning = ''
    if (Test-IsDeployed) {
        $pkgDir = Find-GlobalPackageDir 'dsh-tray-launcher'
        try {
            if ($pkgDir -and (Sync-DeployedFiles $pkgDir)) {
                $fresh = Get-PackageVersion $script:dataDir
                if ($fresh) { $newVer = $fresh }
                $synced = $true
                Write-TrayLog ('deployed files synced from ' + $pkgDir)
            } else {
                $warning = '；但未能定位全局包目录，请重跑 dsh-tray-install'
                Write-TrayLog 'deploy sync failed: global package dir not found'
            }
        } catch {
            $warning = '；部署副本同步失败，请重跑 dsh-tray-install'
            Write-TrayLog ('deploy sync failed: ' + $_.Exception.Message)
        }
    }

    $script:miSelfStatus.Text = ('已更新 v' + $newVer + '，重启托盘生效')
    $script:miSelfUpdate.Enabled = $false
    $script:latestTrayVersion = ''
    if ($synced) {
        Show-TrayBalloon ('托盘启动器已更新到 v' + $newVer + '，重启托盘后生效（已同步部署副本）') ([System.Windows.Forms.ToolTipIcon]::Info)
    } else {
        Show-TrayBalloon ('托盘启动器已更新到 v' + $newVer + '，重启托盘后生效' + $warning) ([System.Windows.Forms.ToolTipIcon]::Info)
    }
    Write-TrayLog ('tray launcher updated to v' + $newVer + $warning)
}

$script:waitTimer.add_Tick({
    if (-not $script:updateProc) { $script:waitTimer.Stop(); return }
    $exited = $false
    try { $exited = $script:updateProc.HasExited } catch { $exited = $true }
    if (-not $exited) {
        if (((Get-Date) - $script:updateStarted).TotalSeconds -ge 600) {
            try { $script:updateProc.Kill() } catch {}
        }
        return
    }
    $script:waitTimer.Stop()
    $code = 1
    try { $code = $script:updateProc.ExitCode } catch {}
    $script:updateProc = $null
    Complete-SelfUpdate $code
})

function Start-TrackedUpdate($cmdLine) {
    # 后台执行 npm 命令并立刻返回：完成结果由 $waitTimer 回填。
    # 10 分钟未结束视为卡死，杀掉后按失败上报（托盘不再无限期显示"正在更新"）。
    $p = Start-LoggedCommand $cmdLine $null
    $script:updateProc = $p
    $script:updateStarted = Get-Date
    $script:waitTimer.Start()
    return $p
}

$script:miSelfCheck.add_Click({
    $script:miSelfStatus.Text = '检查中…'
    $latest = Get-LatestTrayVersion
    if (-not $latest) {
        $script:miSelfStatus.Text = ('当前 v' + $script:TrayVersion)
        Show-TrayBalloon '检查更新失败（网络或 npm 不可用），详见日志' ([System.Windows.Forms.ToolTipIcon]::Warning)
        return
    }
    $script:miSelfStatus.Text = ('当前 v' + $script:TrayVersion + ' · 最新 v' + $latest)
    if ((Compare-Version $latest $script:TrayVersion) -gt 0) {
        $script:latestTrayVersion = $latest
        $script:miSelfUpdate.Text = '更新到 v' + $latest
        $script:miSelfUpdate.Enabled = $true
        Show-TrayBalloon ('托盘启动器有新版本 v' + $latest) ([System.Windows.Forms.ToolTipIcon]::Info)
        Write-TrayLog ('tray launcher update available: v' + $latest)
    } else {
        $script:miSelfUpdate.Enabled = $false
        Show-TrayBalloon ('已是最新版 v' + $script:TrayVersion) ([System.Windows.Forms.ToolTipIcon]::Info)
    }
})

$script:miSelfUpdate.add_Click({
    if ($script:updateProc) {
        Show-TrayBalloon '已有更新任务在进行中，请稍候' ([System.Windows.Forms.ToolTipIcon]::Info)
        return
    }
    $npm = Find-NpmCmd
    if (-not $npm) {
        Show-TrayBalloon '未找到 npm，无法更新' ([System.Windows.Forms.ToolTipIcon]::Error)
        return
    }
    # 输出写托盘专属日志：dsh-out/err.log 被运行中的 Harness 独占持有，
    # 用它做重定向目标会让 cmd 打不开文件、直接以退出码 1 结束且不留任何报错。
    $cmdLine = '/c ""' + $npm + '" install -g dsh-tray-launcher >> "' + $updateOutLog + '" 2>> "' + $updateErrLog + '" "'
    try {
        [void](Start-TrackedUpdate $cmdLine)
    } catch {
        Write-TrayLog ('self-update start failed: ' + $_.Exception.Message)
        Show-TrayBalloon ('更新失败：' + $_.Exception.Message) ([System.Windows.Forms.ToolTipIcon]::Error)
        return
    }
    $script:miSelfStatus.Text = '正在更新…'
    $script:miSelfUpdate.Enabled = $false
    Show-TrayBalloon '正在下载并更新托盘启动器…' ([System.Windows.Forms.ToolTipIcon]::Info)
    Write-TrayLog 'tray launcher self-update started'
})

$script:miSelf.DropDownItems.Add($script:miSelfStatus) | Out-Null
$script:miSelf.DropDownItems.Add($script:miSelfCheck) | Out-Null
$script:miSelf.DropDownItems.Add($script:miSelfUpdate) | Out-Null
$menu.Items.Add($script:miSelf) | Out-Null

# 托盘菜单：重启 Harness
$miRestart = $menu.Items.Add('重启 Harness')
$miRestart.add_Click({
    Write-TrayLog 'restart requested'
    $tray.BalloonTipTitle = 'DeepSeek Harness'
    $tray.BalloonTipText = '正在重启…'
    $tray.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
    $tray.ShowBalloonTip(2000)
    Stop-Harness
    # 等端口真正释放再拉新的：杀树后监听socket关闭有一瞬间，不等的话新 harness
    # 会 EADDRINUSE 秒退（旧版托盘还跟着退出丢图标）。10s 超时后照样尝试，真有
    # 残留也只是转挂靠模式，托盘不退。
    $waited = 0
    while ((Test-PortOpen $script:webPort) -and ($waited -lt 10000)) {
        Start-Sleep -Milliseconds 250
        $waited += 250
    }
    if ($waited -gt 0) { Write-TrayLog ('port ' + $script:webPort + ' released after ' + $waited + ' ms') }
    Start-Sleep -Milliseconds 500
    try {
        Start-HarnessProcess
        # 重启不再自动弹浏览器：$script:opened 保持不变（平时已是 true），
        # dsh 侧也用 --no-open 关掉了它自己的打开动作。想开界面：双击托盘图标或菜单"打开界面"。
        Write-TrayLog 'restart completed'
    } catch {
        Write-TrayLog ('restart failed: ' + $_.Exception.Message)
        $tray.BalloonTipTitle = 'DeepSeek Harness'
        $tray.BalloonTipText = '重启失败，详见日志'
        $tray.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Error
        $tray.ShowBalloonTip(3000)
    }
})
$sepR = New-Object System.Windows.Forms.ToolStripSeparator
$menu.Items.Add($sepR) | Out-Null

$sep3 = New-Object System.Windows.Forms.ToolStripSeparator
$menu.Items.Add($sep3) | Out-Null
$miExit = $menu.Items.Add('退出')
$tray.ContextMenuStrip = $menu
Update-IconMenuChecks

$miOpen.add_Click({ Start-Process (Get-HarnessUrl) })
$miLog.add_Click({ Start-Process notepad $outLog })

# ---- 托盘图标自愈：任务栏重建后自动重新注册 ----
# explorer 崩溃/重启会重建任务栏并广播 TaskbarCreated 消息；NotifyIcon 不处理它的话
# 图标会永久消失（托盘进程和 harness 都活着，却只能手动重启托盘找回图标）。
# 广播只投递给顶层窗口（message-only 窗口收不到），所以挂一个不可见的顶层窗口来接。
$script:taskbarWatch = $null
try {
    Add-Type -TypeDefinition @'
using System;
using System.Windows.Forms;

namespace DshTray
{
    public class TaskbarWatch : NativeWindow
    {
        public event EventHandler TaskbarRecreated;

        [System.Runtime.InteropServices.DllImport("user32.dll")]
        private static extern uint RegisterWindowMessage(string lpString);

        private readonly uint _msg;

        public TaskbarWatch()
        {
            _msg = RegisterWindowMessage("TaskbarCreated");
            CreateHandle(new CreateParams());
        }

        protected override void WndProc(ref Message m)
        {
            if (_msg != 0 && (uint)m.Msg == _msg)
            {
                EventHandler handler = TaskbarRecreated;
                if (handler != null) handler(this, EventArgs.Empty);
            }
            base.WndProc(ref m);
        }
    }
}
'@ -ReferencedAssemblies System.Windows.Forms
    $script:taskbarWatch = New-Object DshTray.TaskbarWatch
    $script:taskbarWatch.add_TaskbarRecreated({
        try {
            $tray.Visible = $false
            $tray.Visible = $true
            Write-TrayLog 'taskbar recreated; tray icon re-registered'
        } catch {
            Write-TrayLog ('tray icon re-register failed: ' + $_.Exception.Message)
        }
    })
    Write-TrayLog 'taskbar watcher armed'
} catch {
    Write-TrayLog ('taskbar watcher unavailable: ' + $_.Exception.Message)
}

# ---- 端口占用者查询（GetExtendedTcpTable，纯 iphlpapi，不加载 NetTCPIP/CIM 模块）----
# Stop-Harness 用它找 web 端口的监听进程 = harness node 本体（杀 cmd 后的孤儿、外部
# 启动的实例都能覆盖，比按进程名猜准得多）。查询任何进程的 TCP 表都不需要管理员。
try {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace DshTray
{
    public static class PortOwner
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct MibTcpRowOwnerPid
        {
            public uint State;
            public uint LocalAddr;
            public uint LocalPort;
            public uint RemoteAddr;
            public uint RemotePort;
            public uint OwningPid;
        }

        [DllImport("iphlpapi.dll", SetLastError = true)]
        private static extern uint GetExtendedTcpTable(IntPtr pTcpTable, ref int dwOutBufLen, bool sort, uint ipVersion, int tblClass, uint reserved);

        // 返回在 127.0.0.1:port 处 LISTEN 的进程 PID；找不到返回 0
        public static int FindListenerPid(int port)
        {
            uint AF_INET = 2;
            const int TCP_TABLE_OWNER_PID_LISTEN = 3;
            const uint MIB_TCP_STATE_LISTEN = 2;
            int size = 0;
            GetExtendedTcpTable(IntPtr.Zero, ref size, false, AF_INET, TCP_TABLE_OWNER_PID_LISTEN, 0);
            if (size <= 0) return 0;
            IntPtr buf = Marshal.AllocHGlobal(size);
            try
            {
                if (GetExtendedTcpTable(buf, ref size, false, AF_INET, TCP_TABLE_OWNER_PID_LISTEN, 0) != 0) return 0;
                int count = Marshal.ReadInt32(buf, 0);
                long rowPtr = buf.ToInt64() + 4;
                int rowSize = Marshal.SizeOf(typeof(MibTcpRowOwnerPid));
                for (int i = 0; i < count; i++)
                {
                    MibTcpRowOwnerPid row = (MibTcpRowOwnerPid)Marshal.PtrToStructure(new IntPtr(rowPtr), typeof(MibTcpRowOwnerPid));
                    // dwLocalPort 的高 16 位才是端口号（网络字节序存在 dword 前 16 位）
                    int localPort = ((int)((row.LocalPort >> 8) & 0xFF)) | ((int)(row.LocalPort & 0xFF) << 8);
                    if (row.State == MIB_TCP_STATE_LISTEN && localPort == port) return (int)row.OwningPid;
                    rowPtr += rowSize;
                }
            }
            finally { Marshal.FreeHGlobal(buf); }
            return 0;
        }
    }
}
'@ -ReferencedAssemblies System.Windows.Forms
    Write-TrayLog 'port owner query armed'
} catch {
    Write-TrayLog ('port owner query unavailable: ' + $_.Exception.Message)
}

# ---- 端口探测（纯 .NET，避免加载 NetTCPIP/CIM 模块）----
# 实测：Import-Module NetTCPIP 会让常驻内存 +29MB；托盘每 3 秒轮询一次，
# 用 TcpClient 直连判断端口就绪，既不加载模块也不产生 CIM 对象。
function Test-PortOpen([int]$Port = 3080) {
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne(300) -and $client.Connected) { return $true }
        return $false
    } catch {
        return $false
    } finally {
        if ($client) { try { $client.Close() } catch {} }
    }
}

# ---- 内存回收（GC + 回收工作集）----
# PowerShell 5.1 + WinForms 基线约 75MB，托盘逻辑再叠几十 MB。定期 GC 并把
# 工作集还给系统，让常驻占用回落到实际在用的页（任务管理器读数显著下降）。
function Invoke-MemoryTrim {
    try {
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
        [System.GC]::Collect()
        [void][Win32.K32Mem]::EmptyWorkingSet([Win32.K32Mem]::GetCurrentProcess())
    } catch {}
}

# ---- 停止 Harness（cmd 包装器 + 端口占用者，整条链不留孤儿）----
# $script:proc 只是 cmd /c 包装器：只杀它会把 node 留成孤儿继续占着 3080（实测复现），
# 重启的新 harness 就会 EADDRINUSE 秒退、托盘跟着退出丢图标（"重启后托盘消失但 dsh
# 还在跑"的完整链条）。杀完包装器后用 GetExtendedTcpTable 找出端口的监听者（node
# 本体，无论它是孤儿还是外部启动的）一并杀，再以 CIM 按 bin 路径兜底扫一遍。
function Stop-Harness {
    $pids = @()
    if ($script:spawned -and $script:proc) {
        try { if (-not $script:proc.HasExited) { $pids += $script:proc.Id } } catch {}
    }
    # 端口监听者 = harness node 本体（孤儿/外部启动都覆盖）；$PID 排除自己
    try {
        $owner = [DshTray.PortOwner]::FindListenerPid($script:webPort)
        if ($owner -and ($owner -ne $PID)) { $pids += $owner }
    } catch {
        Write-TrayLog ('port owner query failed: ' + $_.Exception.Message)
    }
    # 兜底：命令行含本 bin 的 node 进程（CIM 不可用时跳过，上面的端口占用者已覆盖主路径）
    try {
        $escaped = [regex]::Escape($bin)
        $dshProcs = Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" |
            Where-Object { $_.CommandLine -match $escaped } |
            Select-Object -ExpandProperty ProcessId
        $pids += $dshProcs
    } catch {
        Write-TrayLog ('cim query failed: ' + $_.Exception.Message)
    }
    $targets = @($pids | Where-Object { $_ } | Sort-Object -Unique)
    foreach ($target in $targets) {
        Stop-Process -Id $target -Force -ErrorAction SilentlyContinue
    }
    $label = '(none found)'
    if ($targets.Count -gt 0) { $label = ($targets -join ',') }
    Write-TrayLog ('stop requested, targets: ' + $label)
    Invoke-MemoryTrim
}

$miExit.add_Click({
    # 退出 = 全部退出：先停 harness，再关托盘
    Write-TrayLog 'exit requested: stopping harness and closing tray'
    Stop-Harness
    $tray.Visible = $false
    [System.Windows.Forms.Application]::Exit()
})
$tray.add_DoubleClick({ Start-Process (Get-HarnessUrl) })

# ---- 启动 harness 进程（CreateNoWindow：从 API 层面禁止控制台）----
# --no-open：dsh web 默认自己会开一次浏览器（openBrowser 默认 true），托盘这边端口就绪
# 后又开一次——"启动时同时弹出多个浏览器界面"正是这两次叠加。统一改由托盘开且只开一次。
# 旧版 dsh 不认该参数时会在启动几秒内退出，轮询处探测到后摘掉开关重试一次。
$script:harnessNoOpen = $true
$script:harnessStartedAt = Get-Date
function Start-HarnessProcess {
    $openArg = ''
    if ($script:harnessNoOpen) { $openArg = ' --no-open' }
    $cmdLine = '/c ""' + $node + '" "' + $bin + '" web' + $openArg + ' >> "' + $outLog + '" 2>> "' + $errLog + '" "'
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
    $script:harnessStartedAt = Get-Date
    Write-TrayLog ('harness started hidden, pid ' + $script:proc.Id)
}

# ---- 启动 harness（已运行则只挂托盘）----
$script:spawned = $false
$script:proc = $null

$already = Test-PortOpen $script:webPort
if ($already) {
    Write-TrayLog ('harness already listening on ' + $script:webPort + '; tray attached')
    $tray.BalloonTipTitle = 'DeepSeek Harness'
    $tray.BalloonTipText = '已在运行'
    $tray.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
    $tray.ShowBalloonTip(2500)
} else {
    try {
        Start-HarnessProcess
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

# 用量仪表版本检查：随包依赖比已装版本新时提醒一次
try {
    $bundledNow = Find-BundledPlugin
    if ($bundledNow) {
        $bundledVer = (Get-Content (Join-Path $bundledNow 'package.json') -Raw -Encoding UTF8 | ConvertFrom-Json).version
        if ($bundledVer -and $script:pluginVersion -and (Compare-Version $bundledVer $script:pluginVersion) -gt 0) {
            $tray.BalloonTipTitle = 'DeepSeek Harness'
            $tray.BalloonTipText = ('用量仪表有新版本 v' + $bundledVer + '（托盘菜单 → 用量仪表 → 更新）')
            $tray.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
            $tray.ShowBalloonTip(4000)
            Write-TrayLog ('usage meter update available: v' + $bundledVer)
        }
    }
} catch {}

# ---- 轮询：端口就绪后打开浏览器；监视退出 ----
$script:opened = $false
$script:tick = 0
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 3000
$timer.add_Tick({
    $script:tick += 1
    # 每 20 个 tick（约 1 分钟）回收一次工作集：长跑进程的消息循环 + 轮询会产生
    # 大量短命对象，定期 GC + EmptyWorkingSet 能把常驻读数压回实际在用的量。
    if ($script:tick % 20 -eq 0) { Invoke-MemoryTrim }
    if (-not $NoOpen -and -not $script:opened) {
        if (Test-PortOpen $script:webPort) {
            $script:opened = $true
            Start-Process (Get-HarnessUrl)
            Write-TrayLog 'browser opened'
        }
    }
    # 启动后首次 tick 检查托盘启动器自身更新（只查一次；放在浏览器检测之后，
    # 端口就绪开页面不受检查阻塞影响；图标已显示，短暂阻塞可接受）
    if (-not $script:selfCheckDone) {
        $script:selfCheckDone = $true
        try {
            $latest = Get-LatestTrayVersion
            if ($latest -and (Compare-Version $latest $script:TrayVersion) -gt 0) {
                $script:latestTrayVersion = $latest
                $script:miSelfStatus.Text = ('当前 v' + $script:TrayVersion + ' · 最新 v' + $latest)
                $script:miSelfUpdate.Text = '更新到 v' + $latest
                $script:miSelfUpdate.Enabled = $true
                Show-TrayBalloon ('托盘启动器有新版本 v' + $latest + '（托盘菜单 → 更新启动器）') ([System.Windows.Forms.ToolTipIcon]::Info)
                Write-TrayLog ('tray launcher update available: v' + $latest)
            } else {
                Write-TrayLog ('tray launcher self-check: up to date (v' + $script:TrayVersion + ')')
            }
        } catch {}
    }
    if ($script:spawned -and $script:proc -and $script:proc.HasExited) {
        if (Test-PortOpen $script:webPort) {
            # 我们拉起的进程退了，但端口仍有人在听：外部 harness 抢先/并存（插件拉起托盘、
            # 或用户自己在终端跑 dsh web 的竞态）。转挂靠模式继续活着——托盘图标不能跟着
            # 消失，否则就是"dsh 还在跑、托盘却没了、只能手动再启动"。
            $script:spawned = $false
            $script:proc = $null
            Write-TrayLog 'spawned harness exited but port 3080 is served; attaching to external harness'
            $tray.BalloonTipTitle = 'DeepSeek Harness'
            $tray.BalloonTipText = '已在运行'
            $tray.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
            $tray.ShowBalloonTip(2500)
        } elseif ($script:harnessNoOpen -and ((Get-Date) - $script:harnessStartedAt).TotalSeconds -lt 15) {
            # 旧版 dsh 不认 --no-open：启动几秒内就退且端口没人听。摘掉开关重试一次。
            $script:harnessNoOpen = $false
            Write-TrayLog 'harness exited right after start; retrying without --no-open (old dsh?)'
            try { Start-HarnessProcess } catch { }
        } else {
            Write-TrayLog 'harness exited'
            $tray.BalloonTipTitle = 'DeepSeek Harness'
            $tray.BalloonTipText = '已停止'
            $tray.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Warning
            $tray.ShowBalloonTip(2500)
            Start-Sleep -Seconds 2
            $tray.Visible = $false
            [System.Windows.Forms.Application]::Exit()
        }
    }
})
$timer.Start()
# 启动完成即回收一次：WinForms + 图标加载后是常驻内存的峰值点
Invoke-MemoryTrim

# ---- 消息循环 ----
[System.Windows.Forms.Application]::Run()

# ---- 清理 ----
$timer.Stop()
$script:waitTimer.Stop()
$tray.Visible = $false
$tray.Dispose()
try { $mutex.ReleaseMutex() } catch {}
Write-TrayLog 'tray launcher exited'
# 归一化退出码：优雅退出路径固定 0，别让消息循环收尾状态被外层读成异常退出（exit 1）
exit 0
