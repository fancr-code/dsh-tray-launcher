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
  // 托盘模式：完全无窗口。
  // windowsHide:true -> CREATE_NO_WINDOW，子进程不分配控制台，不会闪黑窗；
  // 不用 detached（它反而会在 Windows 上为控制台程序新开控制台）。
  const child = spawn("powershell.exe", ["-WindowStyle", "Hidden", ...psArgs], {
    stdio: "ignore",
    windowsHide: true,
  });
  // 等子进程真正创建后再退出，避免父进程过早结束打断初始化
  child.on("spawn", () => {
    setTimeout(() => process.exit(0), 500);
  });
  child.on("error", (e) => {
    console.error(`dsh-tray: ${e.message}`);
    process.exit(1);
  });
}
