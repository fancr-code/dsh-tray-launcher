// 静态回归守卫：把 issue 里那四类"静默失败"钉死在源码上。
//
// 为什么用文本断言而不是跑 PowerShell：CI 上不一定有 pwsh，而这几个坑的共同特征是
// "命令拼错/重定向到被占用的文件"，用字面量断言既跨平台又能精确指出被改坏的那一行。
// 需要真正执行行为的验证见 debug/ 下的 PowerShell 测试（test-tray-*.ps1）。
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const read = (name) => readFileSync(fileURLToPath(new URL(`../${name}`, import.meta.url)), "utf8");

const tray = read("tray.ps1");
const inst = read("install.ps1");
const uninstall = read("uninstall.ps1");
const pkg = JSON.parse(read("package.json"));

let failed = 0;
const check = (label, ok) => {
  console.log(`  ${ok ? "✓" : "✗"} ${label}`);
  if (!ok) failed += 1;
};
/** 包含 $needle 的那一行（用于把断言限定在单条语句上） */
const lineWith = (text, needle) => text.split(/\r?\n/).filter((l) => l.includes(needle));

console.log("启动器静态回归检查");

// 1) 版本号：读部署目录的 package.json，硬编码兜底值与包版本一致
check("tray.ps1 从 package.json 读版本号", tray.includes("function Get-PackageVersion"));
check("tray.ps1 依次查 dataDir 与脚本目录", tray.includes("foreach ($verDir in @($script:dataDir, $PSScriptRoot))"));
const fallback = tray.match(/\$script:TrayVersion = '([0-9.]+)'/);
check(`硬编码兜底 == package.json (${fallback?.[1]} vs ${pkg.version})`, fallback?.[1] === pkg.version);
check("install.ps1 复制 package.json 到安装目录", inst.includes("Copy-Item $pkgSource"));

// 2) respawn：开关必须在 -File 之前，控制台判定用 IsWindowVisible
const respawnCall = lineWith(tray, "$psi.Arguments = $respawnArgs");
check("respawn 把 -File 放在开关之后", respawnCall.some((l) => l.includes("$respawnArgs + ' -File ")));
check("respawnArgs 本身不含 -File", !tray.includes("$respawnArgs = $respawnArgs + ' -File"));
check("可见控制台判定存在", tray.includes("function Test-VisibleConsole"));
check("判定使用 IsWindowVisible", tray.includes("[Win32.K32Win]::IsWindowVisible("));
check("声明了 IsWindowVisible", tray.includes("public static extern bool IsWindowVisible"));

// 3) 自更新：日志写专属文件（dsh-out/err.log 被 Harness 独占），异步等待，补部署同步
const selfCmd = lineWith(tray, "install -g dsh-tray-launcher >> ");
check("自更新 stdout 写专属日志", selfCmd.some((l) => l.includes("$updateOutLog")));
check("自更新 stderr 写专属日志", selfCmd.some((l) => l.includes("$updateErrLog")));
check("自更新不碰 Harness 日志", selfCmd.every((l) => !l.includes("$outLog") && !l.includes("$errLog")));
const pluginCmd = lineWith(tray, "plugin --profile web add");
check("插件注册写专属日志表", tray.includes("pluginLogs") && tray.includes(">> \"' + $logs.Out + '\" 2>> \"' + $logs.Err"));
check("插件注册不碰 Harness 日志", pluginCmd.every((l) => !l.includes("$outLog") && !l.includes("$errLog")));
// Harness 自身的启动命令仍然把输出写进 dsh-out.log / dsh-err.log（那两份锁由它自己持有），
// 且必须带 --no-open：dsh web 默认自己开一次浏览器，托盘还会开一次，叠加就是"启动时
// 同时弹出多个浏览器界面"——统一由托盘开且只开一次。
const harnessCmd = lineWith(tray, `web' + $openArg + ' >> "`);
check("Harness 启动仍写自己的日志", harnessCmd.some((l) => l.includes("$outLog") && l.includes("$errLog")));
check("Harness 启动带 --no-open（dsh 不再自开浏览器）", harnessCmd.some((l) => l.includes("$openArg")) && tray.includes("$openArg = ' --no-open'"));
check("失败气泡回显真实报错", tray.includes("Get-LogTail $updateErrLog"));
check("没有阻塞消息循环的 WaitForExit()", !tray.includes("$p.WaitForExit()"));
check("更新用定时器异步等待", tray.includes("$script:waitTimer.Start()"));
check("实现了部署副本同步", tray.includes("function Sync-DeployedFiles"));
check("同步有自身覆盖保护", tray.includes("if (Test-IsDeployed)"));
check("同步包含 package.json 与图标", tray.includes("'launch-hidden.vbs', 'package.json'") && tray.includes("'liangzu.ico', 'whale-girl.ico', 'deepseek.ico'"));
check("用 npm root -g 定位全局包", tray.includes('root -g > "'));
check("拒绝覆盖 npm 包/检出里的自身", tray.includes("') -contains 'node_modules'"));

// 4) 用量仪表：嵌套 node_modules 定位 + pnpm 缺失诊断
check("安装器遍历包根与其父目录找依赖", inst.includes("foreach ($b in $bases) { $cands += (Join-Path $b 'node_modules\\dsh-plugin-usage-meter') }"));
check("安装器查全局包内的 node_modules", inst.includes("'dsh-tray-launcher\\node_modules\\dsh-plugin-usage-meter'"));
check("安装器有插件定位函数", inst.includes("function Resolve-BundledPlugin"));
check("安装器探测 pnpm", inst.includes("Get-Command pnpm"));
check("安装器给出 pnpm 修复命令", inst.includes("npm install -g pnpm"));
check("注册失败不写 pluginVersion", /-eq 0\) \{[\s\S]*?\} else \{[\s\S]*?\$pluginVersion = ''/.test(inst));
check("托盘也查全局包内的 node_modules", tray.includes("'dsh-tray-launcher\\node_modules\\dsh-plugin-usage-meter'"));

// 6) 编码陷阱：JSON 读取必须显式 -Encoding UTF8。
// PS 5.1 默认按 ANSI 解码无 BOM 的 UTF-8；依赖与配置里带中文，
// 漏掉就会解析失败并静默回落（"未安装"、版本号空串、配置项全部失效）。
for (const [name, text] of [["tray.ps1", tray], ["install.ps1", inst]]) {
  const bareReads = [...text.matchAll(/Get-Content[^\r\n]*-Raw(?!\s*-Encoding)[^\r\n]*\|\s*ConvertFrom-Json/g)];
  check(`${name} 无裸 ConvertFrom-Json 读取`, bareReads.length === 0);
  for (const m of bareReads) console.log(`      ${m[0].slice(0, 90)}`);
}

// 5) 重复安装：先读已有配置、校验后复用有效字段
check("安装器读取已有配置", inst.includes("function Read-ExistingConfig"));
check("配置用 UTF8 读取（PS 5.1 中文安全）", inst.includes("Get-Content $path -Raw -Encoding UTF8"));
check("有字段探测函数", inst.includes("function Get-Prop"));
check("复用前校验路径存在", inst.includes("if ($v -and (Test-Path $v)) { $pickNode = $v"));
check("复用 url / cwd / 图标", inst.includes("$pickUrl = $v") && inst.includes("$cwd = $v") && inst.includes("$pickIcon = $v"));
check("复用摘要会打印忽略原因", inst.includes("function Get-SkipReason") && inst.includes("$reuse['dshBin'] ="));
check("提供 -NoReuse 逃生口", inst.includes("[switch]$NoReuse") && inst.includes("if ($NoReuse) {"));
check("显式 -ShortcutName 优先于配置", inst.includes("$PSBoundParameters.ContainsKey('ShortcutName')"));
check("配置损坏时不复用", inst.includes("无法解析，将重新生成"));
check("安装器不写三元运算符（PS 5.1 不支持）", !/\?\s[^()]*:\s/.test(inst.replace(/\$[A-Za-z]+:/g, "")));

// 5.5) 快捷方式图标必须写 ico 全路径：预设名裸拼进 IconLocation（"deepseek,0"）Windows 解析不了 → 桌面白板
check("快捷方式图标解析成 ico 全路径", inst.includes("if ($PresetNames -contains $iconSetting) { $iconFile = Join-Path $iconDir ($iconSetting + '.ico') }"));
check("IconLocation 不再写裸预设名", !inst.includes("$lnk.IconLocation = $iconSetting + ',0'"));
check("图标文件缺失时回退默认梁祖", inst.includes("if (-not (Test-Path $iconFile)) { $iconFile = $defaultIcon }"));

// 7) 仪表盘可选 + 可卸载
check("安装器提供 -UsageMeter/-NoUsageMeter", inst.includes("[switch]$UsageMeter") && inst.includes("[switch]$NoUsageMeter"));
check("安装器提供 -RemoveUsageMeter", inst.includes("[switch]$RemoveUsageMeter"));
check("安装器交互式询问是否安装", inst.includes("是否安装内置用量仪表"));
check("卸载分支在安装动作之前", inst.indexOf("$PSBoundParameters.ContainsKey('RemoveUsageMeter')") < inst.indexOf("New-Item -ItemType Directory -Path $InstallDir"));
check("卸载调用 dsh plugin remove", inst.includes("plugin --profile web remove dsh-plugin-usage-meter"));
check("卸载支持 DryRun 演练", inst.includes("Uninstall-UsageMeter -DryRunOnly:$DryRun"));
// 关键约定：这两个函数会被 where 到返回值上，函数体内必须只用 Write-Host 输出
// （先去掉注释行，避免注释里提到 Write-Output 造成误判）
for (const fn of ["Install-UsageMeter", "Uninstall-UsageMeter"]) {
  const raw = inst.slice(inst.indexOf(`function ${fn}`), inst.indexOf("\n}", inst.indexOf(`function ${fn}`)));
  const code = raw.split(/\r?\n/).filter((l) => !l.trim().startsWith("#")).join("\n");
  check(`${fn} 只用 Write-Host 输出（不污染返回值）`, !/\bWrite-Output\b/.test(code));
}
check("卸载失败以非 0 退出", inst.includes("if (-not $ok) { exit 1 }"));
check("托盘菜单有卸载项", tray.includes("'卸载用量仪表'") && tray.includes("Remove-BundledUsageMeter"));
check("托盘卸载注销后清空配置版本", tray.includes("Save-CfgValue 'pluginVersion' ''"));
check("uninstall.ps1 会注销插件", read("uninstall.ps1").includes("plugin --profile") && read("uninstall.ps1").includes("remove dsh-plugin-usage-meter"));
check("uninstall.ps1 支持 -KeepUsageMeter", read("uninstall.ps1").includes("[switch]$KeepUsageMeter"));
check("自定义快捷方式按配置路径清理", uninstall.includes("$configuredShortcut") && uninstall.includes("$cfg.shortcut"));
check("KeepUsageMeter 保留插件目录", uninstall.includes("$KeepUsageMeter") && uninstall.includes("$_.Name -ne 'plugins'"));
check("卸载注销失败保留现场并返回非 0", uninstall.includes("$usageMeterCleanupOk = $false") && uninstall.includes("exit 1"));
check("卸载进程匹配排除自身", uninstall.includes("$_.ProcessId -ne $PID"));
check("卸载文件删除失败返回非 0", uninstall.includes("$cleanupOk = $false") && uninstall.includes("-ErrorAction Stop"));

// 8) 窗口去重 / 重启静默 / 托盘图标自愈（v1.5.4）
const pluginJs = read("src/plugin.js");
const mutexChunk = tray.slice(tray.indexOf("$createdNew = $null"), tray.indexOf("Write-TrayLog 'tray launcher started'"));
check("互斥冲突分支静默退出不开浏览器", mutexChunk.includes("exiting silently") && !mutexChunk.includes("Start-Process"));
const restartChunk = tray.slice(tray.indexOf("$miRestart.add_Click"), tray.indexOf("$sepR ="));
check("重启 Harness 不再重置 opened（不自动开界面）", restartChunk.length > 0 && !restartChunk.includes("$script:opened = $false"));
check("重启前等端口释放再拉新 harness", restartChunk.includes("Test-PortOpen $script:webPort") && restartChunk.includes("released after"));
const stopChunk = tray.slice(tray.indexOf("function Stop-Harness"), tray.indexOf("$miExit.add_Click"));
check("停止 harness 追杀端口监听者（GetExtendedTcpTable，不留 node 孤儿）", stopChunk.includes("FindListenerPid($script:webPort)") && stopChunk.includes("Stop-Process -Id $target -Force"));
check("CIM 按 bin 路径找 harness node（不误杀无关进程）", stopChunk.includes("[regex]::Escape($bin)"));
check("PortOwner C# 就绪（GetExtendedTcpTable）", tray.includes("GetExtendedTcpTable") && tray.includes("port owner query armed"));
check("优雅退出固定 exit 0", tray.trimEnd().endsWith("exit 0"));
const tickChunk = tray.slice(tray.indexOf("$timer.add_Tick"), tray.indexOf("$timer.Start()"));
check("端口被外部 harness 抢占时转挂靠不退出", tickChunk.includes("attaching to external harness"));
check("旧版 dsh 秒退时摘掉 --no-open 重试一次", tickChunk.includes("retrying without --no-open"));
check("监听 TaskbarCreated 自愈托盘图标", tray.includes('RegisterWindowMessage("TaskbarCreated")') && tray.includes("tray icon re-registered"));
check("UI 线程异常不弹窗卡死托盘", tray.includes("add_ThreadException") && tray.includes("UnhandledExceptionMode]::CatchException"));
check("插件拉起托盘带 -NoOpen", pluginJs.includes('"-NoOpen"'));
check("托盘异常退出时插件自动重启", pluginJs.includes("if (code === 0) return;") && pluginJs.includes("attempts > 5"));
check("dispose 后停止重启", pluginJs.includes("disposed = true"));
check("插件 spawn 失败不会触发未处理异常", pluginJs.includes('child.on("error", scheduleRestart)'));
check("托盘启动和轮询使用配置端口", tray.includes("$already = Test-PortOpen $script:webPort") && tickChunk.includes("Test-PortOpen $script:webPort"));

if (failed > 0) {
  console.error(`\n${failed} 项静态检查未通过`);
  process.exit(1);
}
console.log("\n静态检查全部通过");
