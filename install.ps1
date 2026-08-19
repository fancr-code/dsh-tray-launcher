# dsh-tray-launcher 一键安装器
# 用法（克隆仓库后）:
#   powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
# 参数:
#   -DshPath <path>    手动指定 dsh CLI 入口（@deepseek-ai/dsh/lib/bin.js）
#   -Icon <path.ico>   托盘与快捷方式图标（可选；不填用系统默认图标）
#   -ShortcutName <名> 桌面快捷方式名称（默认 DeepSeek Harness）
#   -Autostart         同时注册开机自启
#   -Yes               跳过安装前确认提示（自动化场景）
#   -DryRun            只检测与打印，不写入任何文件
param(
    [string]$DshPath = "",
    [string]$Icon = "",
    [string]$ShortcutName = "DeepSeek Harness",
    [switch]$Autostart,
    [switch]$Yes,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$RepoOwner = 'fancr-code'
$RepoName  = 'dsh-tray-launcher'
$Branch    = 'main'
$InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\DSHTray'

function Resolve-DshBin {
    if ($DshPath -and (Test-Path $DshPath)) { return $DshPath }
    $candidates = @()
    # 1) dsh 命令在 PATH 上：从 .bin shim 反推真实 bin.js
    $cmd = Get-Command dsh -ErrorAction SilentlyContinue
    if ($cmd) {
        $binDir = Split-Path $cmd.Source -Parent
        $candidates += (Join-Path (Split-Path $binDir -Parent) '@deepseek-ai\dsh\lib\bin.js')
    }
    # 2) 当前 npm 的缓存目录（权威来源，兼容自定义/重定向的缓存路径）
    try {
        $cache = & npm config get cache 2>$null
        if ($cache) {
            $npxDir = Join-Path $cache '_npx'
            if (Test-Path $npxDir) {
                $candidates += Get-ChildItem $npxDir -Directory -ErrorAction SilentlyContinue |
                    ForEach-Object { Join-Path $_.FullName 'node_modules\@deepseek-ai\dsh\lib\bin.js' }
            }
        }
    } catch {}
    # 3) npm 全局安装
    try {
        $g = & npm root -g 2>$null
        if ($g) { $candidates += (Join-Path $g '@deepseek-ai\dsh\lib\bin.js') }
    } catch {}
    # 4) 常见兜底位置
    $candidates += (Join-Path $env:APPDATA 'npm\node_modules\@deepseek-ai\dsh\lib\bin.js')
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

# 防粘贴事故：把从 README 粘进来的注释垃圾当参数时，恢复默认快捷方式名
if ([string]::IsNullOrWhiteSpace($ShortcutName) -or $ShortcutName.Trim() -in @('+', '#', '-', '.', '/')) {
    $ShortcutName = 'DeepSeek Harness'
}

$dshBin = Resolve-DshBin
# 优先系统正式 node（codex 等工具链 node 可能是转发桩，会导致黑窗）
$nodePath = ''
$cmdNode = Get-Command node.exe -ErrorAction SilentlyContinue
if ($cmdNode -and $cmdNode.Source -notmatch 'codex') { $nodePath = $cmdNode.Source }
if (-not $nodePath -and (Test-Path 'C:\Program Files\nodejs\node.exe')) { $nodePath = 'C:\Program Files\nodejs\node.exe' }
if (-not $nodePath -and $cmdNode) { $nodePath = $cmdNode.Source }
if ($cmdNode -and $cmdNode.Source -match 'codex' -and $nodePath -ne $cmdNode.Source) {
    Write-Output "注意: 检测到工具链 node ($($cmdNode.Source))，已改用系统 node ($nodePath) 以避免黑窗。"
}
if (-not $nodePath -and (Test-Path 'C:\Program Files\nodejs\node.exe')) { $nodePath = 'C:\Program Files\nodejs\node.exe' }

Write-Output "dsh bin : $dshBin"
Write-Output "node    : $nodePath"
Write-Output "install : $InstallDir"
Write-Output "shortcut: $(Join-Path ([Environment]::GetFolderPath('Desktop')) ($ShortcutName + '.lnk'))"
Write-Output "autostart: $Autostart"

if (-not $nodePath) { Write-Error '未找到 node.exe，请先安装 Node.js。' ; exit 1 }
if (-not $dshBin) {
    Write-Host ''
    Write-Host '未能自动找到 dsh CLI。' -ForegroundColor Yellow
    Write-Host '  方式一：重新运行并指定路径：'
    Write-Host '    dsh-tray-install -DshPath "<路径>\node_modules\@deepseek-ai\dsh\lib\bin.js"'
    Write-Host '  方式二：现在直接粘贴完整路径并回车（跳过则回车）：'
    $manual = Read-Host '  bin.js 路径'
    if ($manual -and (Test-Path $manual)) { $dshBin = $manual }
    if (-not $dshBin) { Write-Error '未找到 dsh CLI，安装中止。' ; exit 1 }
}

if ($DryRun) { Write-Output 'DryRun: 检测完成，未写入任何文件。'; exit 0 }

# ---- 安装前确认 ----
if (-not $Yes) {
    Write-Host ''
    Write-Host '即将执行以下操作：' -ForegroundColor Cyan
    Write-Host ("  1. 复制脚本与图标到: " + $InstallDir)
    Write-Host ("  2. 创建桌面快捷方式: " + (Join-Path ([Environment]::GetFolderPath('Desktop')) ($ShortcutName + '.lnk')))
    if ($Autostart) { Write-Host '  3. 注册开机自启' }
    $answer = Read-Host '是否继续安装? [Y/n]'
    if ($answer -and $answer.Trim().ToLower() -notin @('y', 'yes', '是')) {
        Write-Host '已取消，未写入任何文件。'
        exit 0
    }
}

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

# tray.ps1：优先用同目录副本（克隆安装），否则从 GitHub 下载（远程一行命令安装）
$remoteMode = -not (Test-Path (Join-Path $PSScriptRoot 'tray.ps1'))
$traySource = Join-Path $PSScriptRoot 'tray.ps1'
if ($remoteMode) {
    $traySource = Join-Path $env:TEMP 'dsh-tray.ps1'
    $rawUrl = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$Branch/tray.ps1"
    Invoke-WebRequest -Uri $rawUrl -OutFile $traySource -UseBasicParsing
}
Copy-Item $traySource (Join-Path $InstallDir 'tray.ps1') -Force

# 预设图标集（icons/：梁祖、鲸鱼娘、DeepSeek）；仓库安装直接复制，远程安装逐个下载
$iconDir = Join-Path $InstallDir 'icons'
New-Item -ItemType Directory -Path $iconDir -Force | Out-Null
$presetFiles = @('liangzu.ico', 'whale-girl.ico', 'deepseek.ico')
foreach ($f in $presetFiles) {
    $srcFile = Join-Path $PSScriptRoot ("icons\" + $f)
    if (Test-Path $srcFile) {
        Copy-Item $srcFile (Join-Path $iconDir $f) -Force
    } else {
        $iconUrl = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$Branch/icons/$f"
        Invoke-WebRequest -Uri $iconUrl -OutFile (Join-Path $iconDir $f) -UseBasicParsing
    }
}

# 自定义图标（-Icon 参数）：复制到安装目录并写绝对路径；默认使用梁祖预设
$iconSetting = 'liangzu'
if ($Icon -and (Test-Path $Icon)) {
    $iconCopy = Join-Path $InstallDir 'icon.ico'
    Copy-Item $Icon $iconCopy -Force
    $iconSetting = $iconCopy
}

# 桌面快捷方式
$ws = New-Object -ComObject WScript.Shell
$desktop = [Environment]::GetFolderPath('Desktop')
$lnkPath = Join-Path $desktop ($ShortcutName + '.lnk')
$lnk = $ws.CreateShortcut($lnkPath)
$lnk.TargetPath = 'C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe'
$lnk.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $InstallDir 'tray.ps1') + '"'
$lnk.WorkingDirectory = $InstallDir
$defaultIcon = Join-Path $iconDir 'liangzu.ico'
if ($iconSetting -ne 'liangzu') { $lnk.IconLocation = $iconSetting + ',0' } else { $lnk.IconLocation = $defaultIcon + ',0' }
$lnk.Description = 'DeepSeek Harness 系统托盘启动器'
$lnk.Save()

# 配置文件
$cfg = @{
    dshBin   = $dshBin
    node     = $nodePath
    url      = 'http://127.0.0.1:3080'
    icon     = $iconSetting
    shortcut = $lnkPath
}
$cfg | ConvertTo-Json | Set-Content -Path (Join-Path $InstallDir 'dsh-tray.config.json') -Encoding UTF8

# 开机自启
if ($Autostart) {
    $startup = [Environment]::GetFolderPath('Startup')
    Copy-Item $lnkPath (Join-Path $startup ($ShortcutName + '.lnk')) -Force
}

Write-Output ''
Write-Output '安装完成。双击桌面快捷方式启动（无窗口，托盘图标）。'
Write-Output ("安装目录: " + $InstallDir)
Write-Output ("日志目录: " + (Join-Path $InstallDir 'logs'))
