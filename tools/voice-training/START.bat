@echo off
rem MeshCore Open TAK voice training kit: double-click to start.
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\kit.ps1"
pause
