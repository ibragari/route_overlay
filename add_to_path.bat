@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
if "%SCRIPT_DIR:~-1%"=="\" set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$dir = '%SCRIPT_DIR%'; " ^
  "$userPath = [Environment]::GetEnvironmentVariable('Path','User'); " ^
  "$already = $false; " ^
  "if ($userPath) { $already = ($userPath -split ';') | Where-Object { $_.TrimEnd('\') -ieq $dir.TrimEnd('\') } }; " ^
  "if ($already) { Write-Host 'Already on your user PATH -- nothing to do.' } " ^
  "else { $newPath = if ($userPath) { $userPath.TrimEnd(';') + ';' + $dir } else { $dir }; " ^
  "[Environment]::SetEnvironmentVariable('Path', $newPath, 'User'); " ^
  "Write-Host ('Added ' + $dir + ' to your user PATH.'); " ^
  "Write-Host 'Open a NEW terminal window for this to take effect.' }"

echo.
pause
endlocal
