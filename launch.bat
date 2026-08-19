@echo off
rem dsh-tray-launcher 控制台模式：前台运行 dsh web，日志直接显示在本窗口。
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tray.ps1" -ConsoleMode
echo.
echo Harness 已停止，按任意键关闭本窗口。
pause >nul
