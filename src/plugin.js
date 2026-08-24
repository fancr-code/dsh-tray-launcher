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

  const child = spawn(
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
    ],
    { windowsHide: true, stdio: "ignore" },
  );
  child.unref();
  ctx.on("dispose", () => {
    try {
      child.kill();
    } catch {
      // already gone
    }
  });
}

export { apply, name };
