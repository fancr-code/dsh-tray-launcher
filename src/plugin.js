/**
 * dsh-tray-launcher — host half.
 *
 * A tiny Cordis plugin that keeps the Windows tray launcher alive together
 * with the harness: when `dsh web` starts on Windows it spawns the bundled
 * `tray.ps1` through the same hidden-powershell chain the desktop shortcut
 * uses (no console window, even when Windows Terminal is the default
 * terminal), and kills that child when the plugin is disposed.
 *
 * The script self-locates the `dsh` CLI and an existing harness on port 3080
 * ("harness already listening; tray attached"), and exits silently when
 * another tray instance already holds the global mutex — so the desktop
 * shortcut, `dsh-tray-install` and this plugin can never double-spawn.
 *
 * The tray is spawned with `-NoOpen`: the harness opens its own browser at
 * startup, so a plugin-spawned tray must not open a second one. If the tray
 * process dies abnormally (non-zero exit) while the harness keeps running,
 * it is restarted automatically (max 5 attempts, counter resets after a
 * stable minute) so the icon comes back without a manual relaunch.
 *
 * When started from here, the launcher's own state (dsh-tray.config.json,
 * logs, custom icon) is kept under `%DSH_HOME%\dsh-tray` instead of the npm
 * package directory, so plugin updates never wipe it.
 */
import { spawn } from "node:child_process";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

/** Stable Cordis plugin name. */
const name = "dsh-tray-launcher";

function apply(ctx) {
  if (process.platform !== "win32") return;

  const here = dirname(fileURLToPath(import.meta.url));
  const script = join(here, "..", "tray.ps1");
  const dshHome = process.env.DSH_HOME ?? join(homedir(), ".dsh");
  const dataDir = join(dshHome, "dsh-tray");

  let disposed = false;
  let attempts = 0;
  let startedAt = 0;
  let restartPending = false;
  let child = null;

  const scheduleRestart = () => {
    if (disposed || restartPending) return;
    attempts = Date.now() - startedAt > 60_000 ? 1 : attempts + 1;
    if (attempts > 5) return;
    restartPending = true;
    setTimeout(() => {
      restartPending = false;
      if (!disposed) spawnTray();
    }, 3000);
  };

  const spawnTray = () => {
    // -NoOpen：harness 启动时自己会打开浏览器，插件拉起的托盘不再重复开一个。
    child = spawn(
      "powershell.exe",
      [
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-WindowStyle",
        "Hidden",
        "-File",
        script,
        "-DataDir",
        dataDir,
        "-NoOpen",
      ],
      { windowsHide: true, stdio: "ignore" },
    );
    child.unref();
    startedAt = Date.now();
    child.on("error", scheduleRestart);
    child.on("exit", (code) => {
      if (disposed) return;
      // 退出码 0 = 正常退出（全局互斥锁已被别的托盘实例持有等）；非 0 = 异常崩溃。
      // harness 还在跑而托盘没了，图标就得靠手动再启动找回——这里自动重启补上。
      if (code === 0) return;
      scheduleRestart();
    });
  };
  spawnTray();

  ctx.on("dispose", () => {
    disposed = true;
    try {
      child.kill();
    } catch {
      // already gone
    }
  });
}

export { apply, name };
