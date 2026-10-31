@echo off
rem Forwards to the Python this checkout installs with mise (mise.toml, [tools]).
rem Without it, `python` from inside build scripts resolves to the WindowsApps
rem App Execution Alias, which just prints "Python was not found" and exits 9009.
rem `mise where` reads the installed tool from its registry rather than PATH, so
rem this cannot resolve to itself again.
setlocal
for /f "delims=" %%i in ('mise where python 2^>nul') do set "ANDROPI_PYTHON_DIR=%%i"
if not defined ANDROPI_PYTHON_DIR (
  echo python: mise could not resolve a Python for this checkout. Run `mise install`. 1>&2
  exit /b 9009
)
"%ANDROPI_PYTHON_DIR%\python.exe" %*