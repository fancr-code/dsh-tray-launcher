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
#   -NoReuse           忽略已有配置，全部按当前环境重新探测
#   -UsageMeter        安装内置用量仪表（不指定时交互式询问；配合 -Yes 默认安装）
#   -NoUsageMeter      不安装内置用量仪表（也不改动已有的注册）
#   -RemoveUsageMeter  只卸载已注册的用量仪表（注销 profile 注册 + 删本地副本），不做安装
#
# 重复安装是安全的：安装目录里已有的 dsh-tray.config.json 会先读取并校验，
# 有效的用户设置（node / dshBin 路径、自定义图标、cwd、已注册的插件版本）会被复用，
# 只有缺失或失效的字段才重新探测。显式传入的参数永远优先于配置。
param(
    [string]$DshPath = "",
    [string]$Icon = "",
    [string]$ShortcutName = "DeepSeek Harness",
    [switch]$Autostart,
    [switch]$Yes,
    [switch]$DryRun,
    [switch]$NoReuse,
    [switch]$UsageMeter,
    [switch]$NoUsageMeter,
    [switch]$RemoveUsageMeter
)

$ErrorActionPreference = 'Stop'

$RepoOwner = 'fancr-code'
$RepoName  = 'dsh-tray-launcher'
$Branch    = 'main'
$InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\DSHTray'
$ConfigPath = Join-Path $InstallDir 'dsh-tray.config.json'

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

# 读取已有配置：解析失败/内容不合法就不复用（返回 $null，全部走重新探测）。
# 注意必须显式 -Encoding UTF8：Windows PowerShell 5.1 会把无 BOM 的 UTF-8 当 ANSI 读。
function Read-ExistingConfig($path) {
    if (-not (Test-Path $path)) { return $null }
    try {
        $raw = Get-Content $path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        $obj = $raw | ConvertFrom-Json
        if ($obj -isnot [psobject]) { return $null }
        if ($obj.PSObject.Properties.Name.Count -eq 0) { return $null }
        return $obj
    } catch {
        return $null
    }
}

function Get-Prop($obj, $name) {
    if (-not $obj) { return '' }
    if ($obj.PSObject.Properties.Name -notcontains $name) { return '' }
    $v = $obj.$name
    if ($null -eq $v) { return '' }
    return "$v".Trim()
}

# 图标预设名（与 tray.ps1 的 $PresetIcons 一致）
$PresetNames = @('liangzu', 'whale-girl', 'deepseek')

# --- 探测已有配置并挑出可复用字段 ---
$existing = Read-ExistingConfig $ConfigPath
if ($NoReuse) {
    if ($existing) { Write-Output "-NoReuse：忽略已有配置，全部按当前环境重新探测" }
    $existing = $null
}
$reuse = [ordered]@{}
$pickNode = ''
$pickUrl = ''
$pickIcon = ''
$pickShortcut = ''
$cwd = ''
$pickPluginVersion = ''

# 复用摘要里的"忽略"原因（不用三元运算符：Windows PowerShell 5.1 不支持）
function Get-SkipReason($value) {
    if ($value) { return ('忽略（' + $value + '）') }
    return '忽略（未配置）'
}

if ($existing) {
    Write-Output "发现已有配置，尝试复用: $ConfigPath"

    # node：必须是真实存在的文件；不满足就重新探测
    $v = Get-Prop $existing 'node'
    if ($v -and (Test-Path $v)) { $pickNode = $v; $reuse['node'] = $v } else { $reuse['node'] = Get-SkipReason $v }

    # dshBin：同样要求文件存在
    $v = Get-Prop $existing 'dshBin'
    if ($v -and (Test-Path $v)) { $reuse['dshBin'] = $v } else { $reuse['dshBin'] = Get-SkipReason $v }

    # url / cwd：纯字符串，验形状后原样沿用
    $v = Get-Prop $existing 'url'
    if ($v -match '^https?://') { $pickUrl = $v; $reuse['url'] = $v } else { $reuse['url'] = Get-SkipReason $v }

    $v = Get-Prop $existing 'cwd'
    if ($v -and (Test-Path $v)) { $cwd = $v; $reuse['cwd'] = $v } else { $reuse['cwd'] = Get-SkipReason $v }

    # icon：预设名要求图标文件在安装目录里；自定义图标要求文件存在
    $v = Get-Prop $existing 'icon'
    if ($v -and $PresetNames -contains $v) {
        if (Test-Path (Join-Path $InstallDir ('icons\' + $v + '.ico'))) { $pickIcon = $v; $reuse['icon'] = $v }
        else { $reuse['icon'] = "忽略（缺少图标文件 icons\$v.ico）" }
    } elseif ($v -and (Test-Path $v)) {
        $pickIcon = $v; $reuse['icon'] = $v
    } else {
        $reuse['icon'] = Get-SkipReason $v
    }

    # shortcut：只认实际存在的快捷方式；显式 -ShortcutName 时不复用（用户就是要改名）
    $v = Get-Prop $existing 'shortcut'
    if ($PSBoundParameters.ContainsKey('ShortcutName')) { $reuse['shortcut'] = '忽略（已显式指定 -ShortcutName）' }
    elseif ($v -and (Test-Path $v)) { $pickShortcut = $v; $reuse['shortcut'] = $v }
    else { $reuse['shortcut'] = Get-SkipReason $v }

    # pluginVersion：只在随包依赖缺失、无法重新判定注册状态时兜底复用
    $v = Get-Prop $existing 'pluginVersion'
    if ($v -match '^[0-9]+\.[0-9]+\.[0-9]+') { $pickPluginVersion = $v; $reuse['pluginVersion'] = $v } else { $reuse['pluginVersion'] = Get-SkipReason $v }

    foreach ($k in $reuse.Keys) { Write-Output ("  {0,-14} {1}" -f $k, $reuse[$k]) }
} else {
    if (Test-Path $ConfigPath) { Write-Output "已有配置无法解析，将重新生成: $ConfigPath" }
}

# 防粘贴事故：把从 README 粘进来的注释垃圾当参数时，恢复默认快捷方式名
if ([string]::IsNullOrWhiteSpace($ShortcutName) -or $ShortcutName.Trim() -in @('+', '#', '-', '.', '/')) {
    $ShortcutName = 'DeepSeek Harness'
}

# 显式参数 > 已有配置 > 自动探测
$cfgDshBin = Get-Prop $existing 'dshBin'
if (-not $DshPath -and $cfgDshBin) { $DshPath = $cfgDshBin }
$dshBin = Resolve-DshBin

# 优先系统正式 node（codex 等工具链 node 可能是转发桩，会导致黑窗）
$nodePath = $pickNode
$cmdNode = Get-Command node.exe -ErrorAction SilentlyContinue
if (-not $nodePath -and $cmdNode -and $cmdNode.Source -notmatch 'codex') { $nodePath = $cmdNode.Source }
if (-not $nodePath -and (Test-Path 'C:\Program Files\nodejs\node.exe')) { $nodePath = 'C:\Program Files\nodejs\node.exe' }
if (-not $nodePath -and $cmdNode) { $nodePath = $cmdNode.Source }
if ($cmdNode -and $cmdNode.Source -match 'codex' -and $nodePath -ne $cmdNode.Source) {
    Write-Output "注意: 检测到工具链 node ($($cmdNode.Source))，已改用系统 node ($nodePath) 以避免黑窗。"
}

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

# ---- 内置用量仪表（dsh-plugin-usage-meter）的定位 / 注册 / 卸载 ----
$pluginVersion = $pickPluginVersion
$pluginDir = Join-Path $InstallDir 'plugins\usage-meter'
$hasPnpm = $false

function Resolve-BundledPlugin {
    # 随包依赖的实际落点取决于怎么拿到这个包，四种布局都要试：
    #   ① <包根>\node_modules\...（npm install -g 的嵌套布局）
    #   ② npm 全局根下的 dsh-tray-launcher\node_modules\...
    #      —— 开发检出里跑安装器时必须查这里，否则明明装了全局包却"找不到"
    #   ③ 包根同级、④ 全局根同级（pnpm 提升布局）
    $bases = @($PSScriptRoot, (Split-Path $PSScriptRoot -Parent))
    $globalRoots = @()
    if ($env:NPM_CONFIG_PREFIX) { $globalRoots += $env:NPM_CONFIG_PREFIX }
    $globalRoots += (Join-Path $env:APPDATA 'npm')
    try {
        $g = & npm root -g 2>$null
        if ($g) { $globalRoots += $g }
    } catch {}

    $cands = @()
    foreach ($b in $bases) { $cands += (Join-Path $b 'node_modules\dsh-plugin-usage-meter') }
    foreach ($r in $globalRoots) {
        if (-not $r) { continue }
        $cands += (Join-Path $r 'dsh-tray-launcher\node_modules\dsh-plugin-usage-meter')
        $cands += (Join-Path $r 'dsh-plugin-usage-meter')
    }
    foreach ($c in $cands) {
        if ($c -and (Test-Path (Join-Path $c 'package.json'))) { return (Resolve-Path $c).Path }
    }
    return $null
}

function Test-PluginRegistered {
    # dump-config 不需要 pnpm，比读 profile 文件更贴近 dsh 的真实视图
    $dump = (& $nodePath $dshBin --profile web --dump-config 2>&1 | Out-String)
    return ($dump -match 'dsh-plugin-usage-meter')
}

function Get-PluginPackageVersion($dir) {
    # -Encoding UTF8 不能省：依赖的 package.json 带中文描述，
    # PS 5.1 按 ANSI 解码会解析失败，版本号就成了空串（托盘显示"未安装"）
    try { return (Get-Content (Join-Path $dir 'package.json') -Raw -Encoding UTF8 | ConvertFrom-Json).version } catch { return '' }
}

function Install-UsageMeter {
    # 复制随包依赖到部署目录并注册进 web profile；返回版本号（失败返回空串）。
    # 注意：本函数只用 Write-Host 输出——Write-Output 会混进返回值，调用方拿到的
    # 就不是版本号而是数组（托盘侧同类函数也是这个约定）。
    $bundled = Resolve-BundledPlugin
    if (-not $bundled) {
        Write-Host '未找到随包的用量仪表依赖，跳过集成（不影响托盘使用）。'
        return ''
    }
    [void](New-Item -ItemType Directory -Path $pluginDir -Force)
    foreach ($item in @('lib', 'cordis.patch.yml', 'package.json', 'README.md', 'LICENSE')) {
        $src = Join-Path $bundled $item
        if (Test-Path $src) { Copy-Item $src $pluginDir -Recurse -Force }
    }
    $ver = Get-PluginPackageVersion $bundled
    if (Test-PluginRegistered) {
        Write-Host ("用量仪表已在 profile 中注册，跳过（内置版本 v" + $ver + "）")
        return $ver
    }
    & $nodePath $dshBin plugin --profile web add $pluginDir 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host ("用量仪表已注册: v" + $ver + "（重启 dsh web 后生效）")
        return $ver
    }
    Write-Host ("用量仪表注册失败（dsh plugin add 退出码 " + $LASTEXITCODE + "，不影响托盘使用）")
    if (-not $hasPnpm) { Write-Host '  原因很可能是缺少 pnpm：npm install -g pnpm 后重跑本安装器即可。' }
    return ''
}

function Uninstall-UsageMeter([switch]$DryRunOnly) {
    # 注销 profile 注册 + 删除部署副本；只返回 $true/$false（输出一律走 Write-Host）
    $removed = $true
    if (Test-PluginRegistered) {
        if ($DryRunOnly) {
            Write-Host '将注销 profile 注册: dsh plugin --profile web remove dsh-plugin-usage-meter'
        } else {
            & $nodePath $dshBin plugin --profile web remove dsh-plugin-usage-meter 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Host '已从 web profile 注销用量仪表'
            } else {
                $removed = $false
                Write-Host ("用量仪表注销失败（dsh plugin remove 退出码 " + $LASTEXITCODE + "）")
                if (-not $hasPnpm) { Write-Host '  原因很可能是缺少 pnpm：npm install -g pnpm 后重跑' }
            }
        }
    } else {
        Write-Host '用量仪表本来就不在 profile 里，无需注销'
    }
    if (Test-Path $pluginDir) {
        if ($DryRunOnly) {
            Write-Host ('将删除本地插件副本: ' + $pluginDir)
        } else {
            try { Remove-Item $pluginDir -Recurse -Force; Write-Host ('已删除本地插件副本: ' + $pluginDir) }
            catch { Write-Host ('本地插件副本删除失败: ' + $_.Exception.Message) }
        }
    }
    if ($removed -and -not $DryRunOnly) {
        Write-Host '重启 dsh web 后仪表盘即从界面消失（托盘菜单 → 重启 Harness）'
    }
    return $removed
}

# dsh plugin 只是 pnpm 的转发器（源码里直接 spawnSync("pnpm")），没有 pnpm 必然注册/卸载失败。
# 先探一次并给出可执行的修复命令，避免用户只看到一句"集成失败"。
try {
    if (Get-Command pnpm -ErrorAction SilentlyContinue) {
        [void](& pnpm --version 2>$null)
        $hasPnpm = $true
    }
} catch {}
if (-not $hasPnpm) {
    Write-Output '未安装 pnpm：插件的注册/卸载需要它（dsh plugin 内部直接调用 pnpm）。'
    Write-Output '  修复：npm install -g pnpm   然后重跑本安装器'
}

# ---- -RemoveUsageMeter：只卸载仪表盘，立即执行并退出（不进入任何安装动作）----
if ($PSBoundParameters.ContainsKey('RemoveUsageMeter')) {
    Write-Output '模式: 只卸载内置用量仪表（不做安装）'
    # 优先用配置里记录的插件目录（托盘可能把它改到别处），没有才用默认路径
    if (Test-Path $ConfigPath) {
        try {
            $c = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $cfgPluginDir = "$($c.pluginDir)".Trim()
            if ($cfgPluginDir) { $pluginDir = $cfgPluginDir }
        } catch {}
    }
    $ok = Uninstall-UsageMeter -DryRunOnly:$DryRun
    if (-not $ok) { exit 1 }
    if (-not $DryRun -and (Test-Path $ConfigPath)) {
        try {
            $c = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $c | Add-Member -MemberType NoteProperty -Name 'pluginVersion' -Value '' -Force
            $c | Add-Member -MemberType NoteProperty -Name 'pluginDir' -Value '' -Force
            $c | ConvertTo-Json | Set-Content -Path $ConfigPath -Encoding UTF8
            Write-Output '已更新托盘配置（pluginVersion 置空，托盘不再显示"已安装"）'
        } catch { Write-Output ('托盘配置更新失败（不影响卸载）: ' + $_.Exception.Message) }
    }
    exit 0
}

# ---- 是否安装仪表盘：参数 > 交互式询问；-Yes / -DryRun 场景不询问（默认安装）----
$installUsageMeter = $true
if ($NoUsageMeter) {
    $installUsageMeter = $false
    Write-Output '按参数跳过内置用量仪表（已有注册不会被改动）'
} elseif ($UsageMeter) {
    Write-Output '按参数安装内置用量仪表'
} elseif (-not $Yes -and -not $DryRun) {
    $ans = Read-Host '是否安装内置用量仪表（dsh-plugin-usage-meter）? [Y/n]'
    if ($ans -and $ans.Trim().ToLower() -in @('n', 'no', '否')) {
        $installUsageMeter = $false
        Write-Output '已选择不安装内置用量仪表'
    }
}

if ($DryRun) {
    Write-Output ('用量仪表: ' + $(if ($installUsageMeter) { '将安装（-NoUsageMeter 可跳过）' } else { '跳过' }))
    Write-Output 'DryRun: 检测完成，未写入任何文件。'
    exit 0
}

# ---- 安装前确认 ----
if (-not $Yes) {
    Write-Host ''
    Write-Host '即将执行以下操作：' -ForegroundColor Cyan
    Write-Host ("  1. 复制脚本与图标到: " + $InstallDir)
    Write-Host ("  2. 创建桌面快捷方式: " + (Join-Path ([Environment]::GetFolderPath('Desktop')) ($ShortcutName + '.lnk')))
    if ($Autostart) { Write-Host '  3. 注册开机自启' }
    if ($existing) { Write-Host '  4. 复用上面列出的已有配置项（其余字段按当前环境重新探测）' }
    if ($installUsageMeter) { Write-Host '  5. 安装内置用量仪表（dsh-plugin-usage-meter）' }
    else { Write-Host '  5. 跳过内置用量仪表' }
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

# package.json：托盘靠它显示真实版本号。此前不拷贝它，安装目录里读不到版本，
# tray.ps1 只能退回硬编码兜底值，于是"更新成功却仍提示有新版"。
$pkgSource = Join-Path $PSScriptRoot 'package.json'
if (Test-Path $pkgSource) {
    Copy-Item $pkgSource (Join-Path $InstallDir 'package.json') -Force
}

# VBS uses the GUI-script host to start PowerShell without attaching a console.
$launcherSource = Join-Path $PSScriptRoot 'launch-hidden.vbs'
$launcherDest = Join-Path $InstallDir 'launch-hidden.vbs'
if (Test-Path $launcherSource) {
    Copy-Item $launcherSource $launcherDest -Force
} else {
    $launcherUrl = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$Branch/launch-hidden.vbs"
    Invoke-WebRequest -Uri $launcherUrl -OutFile $launcherDest -UseBasicParsing
}

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

# 图标设置：-Icon 参数 > 复用已有设置 > 默认梁祖预设
$iconSetting = 'liangzu'
if ($Icon -and (Test-Path $Icon)) {
    $iconCopy = Join-Path $InstallDir 'icon.ico'
    Copy-Item $Icon $iconCopy -Force
    $iconSetting = $iconCopy
} elseif ($pickIcon) {
    $iconSetting = $pickIcon
}

# 桌面快捷方式：沿用配置里已有的快捷方式路径（用户可能改过名字/位置）
$ws = New-Object -ComObject WScript.Shell
$desktop = [Environment]::GetFolderPath('Desktop')
$lnkPath = if ($pickShortcut) { $pickShortcut } else { Join-Path $desktop ($ShortcutName + '.lnk') }
$lnk = $ws.CreateShortcut($lnkPath)
$lnk.TargetPath = 'C:\WINDOWS\System32\wscript.exe'
$lnk.Arguments = '"' + $launcherDest + '"'
$lnk.WorkingDirectory = $InstallDir
# IconLocation 必须是 ico 文件全路径：预设名要解析成安装目录 icons\<名>.ico。
# 曾把预设名原样拼接（写成 "deepseek,0" 这种裸文件名），Windows 解析不了 → 桌面快捷方式白板。
$defaultIcon = Join-Path $iconDir 'liangzu.ico'
$iconFile = $iconSetting
if ($PresetNames -contains $iconSetting) { $iconFile = Join-Path $iconDir ($iconSetting + '.ico') }
if (-not (Test-Path $iconFile)) { $iconFile = $defaultIcon }
$lnk.IconLocation = $iconFile + ',0'
$lnk.Description = 'DeepSeek Harness 系统托盘启动器'
$lnk.WindowStyle = 1
$lnk.Save()

# 按前面的选择安装（或跳过）用量仪表
$pluginVersion = $pickPluginVersion
if ($installUsageMeter) {
    try {
        $v = Install-UsageMeter
        if ($v) { $pluginVersion = $v } elseif (-not (Test-PluginRegistered)) { $pluginVersion = '' }
    } catch {
        $pluginVersion = ''
        Write-Output ("用量仪表集成失败（不影响托盘使用）: " + $_.Exception.Message)
    }
} else {
    Write-Output '已跳过用量仪表安装（托盘菜单「用量仪表 → 卸载用量仪表」可随时移除已有注册）'
}

# 配置文件（复用到的字段原样写回，其余用本次探测值）
$cfg = [ordered]@{
    dshBin        = $dshBin
    node          = $nodePath
    url           = if ($pickUrl) { $pickUrl } else { 'http://127.0.0.1:3080' }
    icon          = $iconSetting
    shortcut      = $lnkPath
    cwd           = $cwd
    pluginVersion = $pluginVersion
    pluginDir     = $pluginDir
}
$cfg | ConvertTo-Json | Set-Content -Path $ConfigPath -Encoding UTF8

# 开机自启
if ($Autostart) {
    $startup = [Environment]::GetFolderPath('Startup')
    Copy-Item $lnkPath (Join-Path $startup ([System.IO.Path]::GetFileName($lnkPath))) -Force
}

Write-Output ''
Write-Output '安装完成。双击桌面快捷方式启动（无窗口，托盘图标）。'
Write-Output ("安装目录: " + $InstallDir)
Write-Output ("配置文件: " + $ConfigPath)
Write-Output ("日志目录: " + (Join-Path $InstallDir 'logs'))
