@echo off
cd /d "%~dp0"
powershell -ExecutionPolicy Bypass -File "%~dp0SoundModTuner.ps1"
pause
