@echo off
REM Task Board 로컬 런처 (Windows) - 더블클릭으로 실행
cd /d "%~dp0"
where py >nul 2>nul
if %errorlevel%==0 (
  py run.py %*
) else (
  python run.py %*
)
pause
