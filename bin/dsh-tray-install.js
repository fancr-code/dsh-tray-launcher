#!/usr/bin/env node
// dsh-tray-install: 一键安装（生成桌面快捷方式 + 托盘脚本 + 配置）
import { spawn } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const ps1 = join(root, "install.ps1");

const args = ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ps1, ...process.argv.slice(2)];
const child = spawn("powershell.exe", args, { stdio: "inherit" });
child.on("exit", (code) => process.exit(code ?? 0));
