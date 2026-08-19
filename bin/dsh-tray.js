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
  // 前台运行：日志直出当前终端
  const child = spawn("powershell.exe", psArgs, { stdio: "inherit" });
  child.on("exit", (code) => process.exit(code ?? 0));
} else {
  // 托盘模式：隐藏窗口、完全脱离当前终端
  const child = spawn("powershell.exe", ["-WindowStyle", "Hidden", ...psArgs], {
    stdio: "ignore",
    detached: true,
  });
  child.unref();
}
