@echo off
setlocal EnableExtensions

set "REPO_ROOT=%~dp0.."
for %%i in ("%REPO_ROOT%") do set "REPO_ROOT=%%~fi"
set "BUILD_TOOLS=%REPO_ROOT%\build_tools"
set "QT_VERSION=6.10.1"
set "QT_ARCH=msvc2022_64"
set "QT_HOST_ARCH=win64_msvc2022_64"
echo For MSVC path-length safety, use a short clone path such as C:\src\DesktopEditors.

rem Keep the Qt SDK in ignored build output so a fresh clone can bootstrap it.
if not defined QT_INSTALL_ROOT set "QT_INSTALL_ROOT=%BUILD_TOOLS%\out\win_64\qt"
set "QT_DIR=%QT_INSTALL_ROOT%\%QT_VERSION%"
set "QT_KIT=%QT_DIR%\%QT_ARCH%"

if exist "%QT_KIT%\bin\qmake.exe" if exist "%QT_KIT%\bin\lrelease.exe" if exist "%QT_KIT%\lib\Qt6MultimediaWidgets.lib" goto QT_READY

echo Qt %QT_VERSION% MSVC 2022 kit not found. Bootstrapping from the official Qt archive...
python -m pip show aqtinstall >nul 2>&1
if errorlevel 1 (
  python -m pip install --user aqtinstall
  if errorlevel 1 exit /b %errorlevel%
)

if not exist "%BUILD_TOOLS%\out\win_64" mkdir "%BUILD_TOOLS%\out\win_64"
pushd "%BUILD_TOOLS%\out\win_64"
python -m aqt install-qt windows desktop %QT_VERSION% %QT_HOST_ARCH% --modules qtmultimedia --outputdir "%QT_INSTALL_ROOT%"
set "AQT_EXIT_CODE=%errorlevel%"
popd
if not "%AQT_EXIT_CODE%"=="0" exit /b %AQT_EXIT_CODE%

if not exist "%QT_KIT%\bin\qmake.exe" (
  echo Qt bootstrap did not install qmake at "%QT_KIT%\bin\qmake.exe".
  exit /b 1
)
if not exist "%QT_KIT%\bin\lrelease.exe" (
  echo Qt bootstrap did not install lrelease at "%QT_KIT%\bin\lrelease.exe".
  exit /b 1
)
if not exist "%QT_KIT%\lib\Qt6MultimediaWidgets.lib" (
  echo Qt bootstrap did not install the Multimedia module.
  exit /b 1
)

:QT_READY
set "VSINSTALL="
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not defined VSVCVARS if exist "%VSWHERE%" for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSINSTALL=%%i"
if not defined VSVCVARS if not defined VSINSTALL for %%e in (Community Professional Enterprise BuildTools) do if not defined VSINSTALL if exist "%ProgramFiles%\Microsoft Visual Studio\2022\%%e\VC\Auxiliary\Build\vcvarsall.bat" set "VSINSTALL=%ProgramFiles%\Microsoft Visual Studio\2022\%%e"
if not defined VSVCVARS if defined VSINSTALL set "VSVCVARS=%VSINSTALL%\VC\Auxiliary\Build\vcvarsall.bat"
if not defined VSVCVARS (
  echo Visual Studio 2022 C++ tools were not found. Install the MSVC x64 build tools or set VSVCVARS to vcvarsall.bat.
  exit /b 1
)

if not exist "%VSVCVARS%" (
  echo Visual Studio environment script not found: "%VSVCVARS%"
  exit /b 1
)
for %%i in ("%VSVCVARS%") do set "VSVCVARS_DIR=%%~dpi"
for %%i in ("%VSVCVARS_DIR%.") do set "VSVCVARS_DIR=%%~fi"
for %%i in ("%VSVCVARS_DIR%\..\..\..") do set "VSINSTALL=%%~fi"

if defined VSVCVARS_VER goto VS_VERSION_READY
set "VCTOOLS_FOUND="
for /d %%i in ("%VSINSTALL%\VC\Tools\MSVC\14.29.*") do set "VCTOOLS_FOUND=1"
if defined VCTOOLS_FOUND set "VSVCVARS_VER=14.29"
if defined VSVCVARS_VER goto VS_VERSION_READY
set "VS_TOOLSET_DIR="
for /d %%i in ("%VSINSTALL%\VC\Tools\MSVC\14.*") do set "VS_TOOLSET_DIR=%%~nxi"
if defined VS_TOOLSET_DIR for /f "tokens=1,2 delims=." %%a in ("%VS_TOOLSET_DIR%") do set "VSVCVARS_VER=%%a.%%b"
:VS_VERSION_READY
if not defined VSVCVARS_VER (
  echo No MSVC toolset was found under "%VSINSTALL%\VC\Tools\MSVC".
  exit /b 1
)

rem Regenerate the ignored local config with paths relative to this clone.
pushd "%BUILD_TOOLS%"
python configure.py --update 0 --clean 0 --module desktop --develop 0 --beta 0 --platform win_64 --qt-dir "%QT_DIR%" --compiler msvc2022 --no-apps 0 --git-protocol auto --vs-version 2019 --vs-path "%VSVCVARS_DIR%" --multiprocess 1 --sysroot 0
set "CONFIG_EXIT_CODE=%errorlevel%"
popd
if not "%CONFIG_EXIT_CODE%"=="0" exit /b %CONFIG_EXIT_CODE%

rem The generated Windows makefiles use O:\ paths; map O: to this clone.
if not exist "O:\build_tools\make.py" (
  subst O: "%REPO_ROOT%"
  if errorlevel 1 (
    echo Could not map O: to the repository. Free O: or map it to "%REPO_ROOT%".
    exit /b 1
  )
)
if not exist "O:\build_tools\make.py" (
  echo O:\ does not point to this DesktopEditors clone.
  exit /b 1
)

pushd "%BUILD_TOOLS%"
call "%VSVCVARS%" x64 -vcvars_ver=%VSVCVARS_VER%
if errorlevel 1 (
  popd
  exit /b 1
)
python make.py
set "BUILD_EXIT_CODE=%errorlevel%"
popd
if not "%BUILD_EXIT_CODE%"=="0" exit /b %BUILD_EXIT_CODE%

rem Ensure the packaged application has both Qt and ONLYOFFICE runtime DLLs.
set "APP_DIR=%BUILD_TOOLS%\out\win_64\onlyoffice\DesktopEditors"
set "CORE_DLL_DIR=%REPO_ROOT%\core\build\lib\win_64"
set "ICU_DLL_DIR=%REPO_ROOT%\core\Common\3dParty\icu\icu\bin64"
if not exist "%APP_DIR%\DesktopEditors.exe" (
  echo Build completed without producing "%APP_DIR%\DesktopEditors.exe".
  exit /b 1
)
if not exist "%CORE_DLL_DIR%\kernel.dll" (
  echo Core runtime DLLs were not produced at "%CORE_DLL_DIR%".
  exit /b 1
)
if not exist "%ICU_DLL_DIR%\icuuc74.dll" (
  echo ICU 74 runtime DLLs were not found at "%ICU_DLL_DIR%".
  exit /b 1
)
for %%i in ("%CORE_DLL_DIR%\*.dll") do if exist "%%~fi" copy /y "%%~fi" "%APP_DIR%\" >nul
for %%i in ("%ICU_DLL_DIR%\icu*.dll") do if exist "%%~fi" copy /y "%%~fi" "%APP_DIR%\" >nul

"%QT_KIT%\bin\windeployqt.exe" --release --dir "%APP_DIR%" --no-translations --compiler-runtime --no-system-dxc-compiler "%APP_DIR%\DesktopEditors.exe"
if errorlevel 1 exit /b %errorlevel%

if exist "%REPO_ROOT%\web-apps\deploy\web-apps" (
  robocopy "%REPO_ROOT%\web-apps\deploy\web-apps" "%APP_DIR%\editors\web-apps" /E /COPY:DAT /R:2 /W:2
  if errorlevel 8 exit /b %errorlevel%
)

echo Build and runtime deployment completed: "%APP_DIR%"
exit /b 0
