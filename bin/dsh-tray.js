#!/usr/bin/env node
// dsh-tray: 启动 DeepSeek Harness 托盘启动器（默认托盘模式，--console 为控制台模式）
import { spawn } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const ps1 = join(root, "tray.ps1");
const rest = process.argv.slice(2);
const consoleMode = rest.includes("-ConsoleMode") || rest.includes("--console");

const psArgs = ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ps1, ...rest];

if (consoleMode) {
  // 控制台模式：前台运行，日志直出当前终端
  const child = spawn("powershell.exe", psArgs, { stdio: "inherit" });
  child.on("exit", (code) => process.exit(code ?? 0));
} else {
  // 托盘模式：无窗口后台运行，包装器负责给终端反馈。
  // windowsHide -> CREATE_NO_WINDOW，子进程不分配控制台（不会闪黑窗）。
  const child = spawn("powershell.exe", ["-WindowStyle", "Hidden", ...psArgs], {
    stdio: ["ignore", "pipe", "pipe"],
    windowsHide: true,
  });
  let errText = "";
  let settled = false;
  child.stderr.on("data", (d) => (errText += d));
  child.on("error", (e) => {
    if (settled) return;
    settled = true;
    console.error(`dsh-tray: 启动失败 — ${e.message}`);
    process.exit(1);
  });
  child.on("exit", (code) => {
    if (settled) return;
    settled = true;
    // 托盘脚本应该常驻；快速退出只有两种情况：单实例锁退场 / 启动失败
    if (code === 0) {
      console.log("dsh-tray: 已有托盘实例在运行，稍候浏览器会自动打开界面（http://127.0.0.1:3080）。");
      process.exit(0);
    }
    const lastLine = errText.trim().split(/\r?\n/).pop();
    console.error(`dsh-tray: 启动失败（退出码 ${code}）${lastLine ? " — " + lastLine : ""}`);
    console.error("       提示：先运行 dsh-tray-install 安装并检测 dsh；日志见安装目录 logs\\dsh-tray.log");
    process.exit(1);
  });
  // 子进程存活超过观察窗口 = 托盘已挂载，视为启动成功
  setTimeout(() => {
    if (settled) return;
    settled = true;
    console.log("dsh-tray: 托盘启动器已后台运行，请查看系统托盘图标（找不到图标就点任务栏 ^ 折叠区）。");
    process.exit(0);
  }, 3000);
}
