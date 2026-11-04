@echo off
rem 重新编译 智屏安播控制台.exe（改了 control_panel.cs 之后用）
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build_panel.ps1"
pause
