@echo off
rem Starts the Sims 2 DS map editor with the Godot binary of this folder (no install, no Python).
cd /d "%~dp0"
for %%G in (Godot_v4*_win64.exe) do (
  start "" "%%G" --path "%~dp0" %*
  goto :eof
)
echo No Godot_v4.x_win64.exe found next to this file.
echo Download Godot 4.7 (standard, not .NET) from https://godotengine.org/download and put the exe here.
pause
