# dsh-tray-launcher 一键安装器
# 用法（克隆仓库后）:
#   powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
# 参数:
#   -DshPath <path>    手动指定 dsh CLI 入口（@deepseek-ai/dsh/lib/bin.js）
#   -Icon <path.ico>   托盘与快捷方式图标（可选；不填用系统默认图标）
#   -ShortcutName <名> 桌面快捷方式名称（默认 DeepSeek Harness）
#   -Autostart         同时注册开机自启
#   -DryRun            只检测与打印，不写入任何文件
param(
    [string]$DshPath = "",
    [string]$Icon = "",
    [string]$ShortcutName = "DeepSeek Harness",
    [switch]$Autostart,
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

$dshBin = Resolve-DshBin
$nodePath = ''
$cmdNode = Get-Command node.exe -ErrorAction SilentlyContinue
if ($cmdNode) { $nodePath = $cmdNode.Source }
if (-not $nodePath -and (Test-Path 'C:\Program Files\nodejs\node.exe')) { $nodePath = 'C:\Program Files\nodejs\node.exe' }

Write-Output "dsh bin : $dshBin"
Write-Output "node    : $nodePath"
Write-Output "install : $InstallDir"
Write-Output "shortcut: $(Join-Path ([Environment]::GetFolderPath('Desktop')) ($ShortcutName + '.lnk'))"
Write-Output "autostart: $Autostart"

if (-not $nodePath) { Write-Error '未找到 node.exe，请先安装 Node.js。' ; exit 1 }
if (-not $dshBin)  { Write-Error '未找到 dsh CLI。请用 -DshPath 指定 @deepseek-ai/dsh/lib/bin.js 的路径。' ; exit 1 }

if ($DryRun) { Write-Output 'DryRun: 检测完成，未写入任何文件。'; exit 0 }

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

# 图标：-Icon 优先；其次仓库自带的梁祖图标；远程安装时从 GitHub 下载内置图标
$iconSource = ''
if ($Icon -and (Test-Path $Icon)) {
    $iconSource = $Icon
} else {
    $bundled = Join-Path $PSScriptRoot 'liangzu-icon.ico'
    if (Test-Path $bundled) { $iconSource = $bundled }
}
if (-not $iconSource -and $remoteMode) {
    $iconSource = Join-Path $env:TEMP 'liangzu-icon.ico'
    $iconUrl = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$Branch/liangzu-icon.ico"
    Invoke-WebRequest -Uri $iconUrl -OutFile $iconSource -UseBasicParsing
}
$iconCopy = ''
if ($iconSource) {
    Copy-Item $iconSource (Join-Path $InstallDir 'icon.ico') -Force
    $iconCopy = Join-Path $InstallDir 'icon.ico'
}

# 配置文件
$cfg = @{
    dshBin = $dshBin
    node   = $nodePath
    url    = 'http://127.0.0.1:3080'
    icon   = $iconCopy
}
$cfg | ConvertTo-Json | Set-Content -Path (Join-Path $InstallDir 'dsh-tray.config.json') -Encoding UTF8

# 桌面快捷方式
$ws = New-Object -ComObject WScript.Shell
$desktop = [Environment]::GetFolderPath('Desktop')
$lnkPath = Join-Path $desktop ($ShortcutName + '.lnk')
$lnk = $ws.CreateShortcut($lnkPath)
$lnk.TargetPath = 'C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe'
$lnk.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $InstallDir 'tray.ps1') + '"'
$lnk.WorkingDirectory = $InstallDir
if ($iconCopy) { $lnk.IconLocation = $iconCopy + ',0' }
$lnk.Description = 'DeepSeek Harness 系统托盘启动器'
$lnk.Save()

# 开机自启
if ($Autostart) {
    $startup = [Environment]::GetFolderPath('Startup')
    Copy-Item $lnkPath (Join-Path $startup ($ShortcutName + '.lnk')) -Force
}

Write-Output ''
Write-Output '安装完成。双击桌面快捷方式启动（无窗口，托盘图标）。'
Write-Output ("安装目录: " + $InstallDir)
Write-Output ("日志目录: " + (Join-Path $InstallDir 'logs'))
