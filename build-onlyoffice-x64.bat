@echo off
setlocal

if "%VSVCVARS%"=="" set VSVCVARS=C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat
if "%VSVCVARS_VER%"=="" set VSVCVARS_VER=14.29

set REPO_ROOT=%~dp0..
for %%i in ("%REPO_ROOT%") do set REPO_ROOT=%%~fi

if not exist O:\build_tools\make.py subst O: "%REPO_ROOT%"
if errorlevel 1 exit /b %errorlevel%

pushd "%~dp0"
call "%VSVCVARS%" x64 -vcvars_ver=%VSVCVARS_VER%
if errorlevel 1 (
  set BUILD_EXIT_CODE=%errorlevel%
  popd
  exit /b %BUILD_EXIT_CODE%
)
python make.py
set BUILD_EXIT_CODE=%errorlevel%
popd
exit /b %BUILD_EXIT_CODE%
