@ECHO OFF
REM ===========================================================================
REM  build.bat - builds the hwBro deliverable (Harbour + MSVC x64)
REM ---------------------------------------------------------------------------
REM  Autonomous on purpose: it does NOT call c:\bat\compi65.bat. It sets up the
REM  MSVC environment itself and runs hbmk2 on src\hwbro.hbp.
REM
REM  Usage:   build.bat
REM  Output:  hwbro.exe in the project root
REM  Exit:    0 = built, 1 = build failed, 2 = toolchain missing,
REM           3 = a running hwBro.exe holds the previous binary
REM ===========================================================================
SETLOCAL
CD /D "%~dp0"

SET "HARBOUR_DIR=C:\harbour"
SET "VCVARS=%ProgramFiles(x86)%\Microsoft Visual Studio\2019\Community\VC\Auxiliary\Build\vcvarsall.bat"
SET "PROJECT=src\hwbro.hbp"
SET "TARGET=hwbro.exe"

REM --- 1. toolchain sanity ---------------------------------------------------
SET "PATH=%PATH%;%SystemRoot%\system32;%SystemRoot%;%SystemRoot%\System32\Wbem"
SET "PATH=%PATH%;%HARBOUR_DIR%\bin"

IF NOT EXIST "%HARBOUR_DIR%\bin\hbmk2.exe" (
   ECHO [build] ERROR: hbmk2.exe not found in "%HARBOUR_DIR%\bin"
   EXIT /B 2
)
IF NOT EXIST "%PROJECT%" (
   ECHO [build] ERROR: "%PROJECT%" not found - run this script from the project root
   EXIT /B 2
)

REM --- 2. MSVC x64 environment (skipped when it is already loaded) -----------
IF DEFINED DevEnvDir GOTO :haveenv
IF NOT EXIST "%VCVARS%" (
   ECHO [build] ERROR: vcvarsall.bat not found:
   ECHO [build]        "%VCVARS%"
   ECHO [build]        install VS 2019 C++ tools or export DevEnvDir
   EXIT /B 2
)
ECHO [build] loading MSVC x64 environment...
REM  A inherited INCLUDE/LIB (this machine carries C:\OpenSSL-win64, which is
REM  what `vcvarsall.bat` finds in the shell) mixes foreign headers into the
REM  compile: measured twice - once as a false red in zmmintrin.h inside
REM  run-tests.bat, once as a syntax error inside stdio.h here - and it is
REM  INTERMITTENT, which is the worst part. run-tests.bat already clears them
REM  inside its SETLOCAL; the deliverable's build does the same, so the MSVC
REM  include path is the one vcvarsall sets and nothing else.
SET "INCLUDE="
SET "LIB="
CALL "%VCVARS%" x86_amd64
IF ERRORLEVEL 1 (
   ECHO [build] ERROR: "vcvarsall.bat x86_amd64" failed
   EXIT /B 2
)
:haveenv
SET HB_COMPILER=msvc64

REM --- 3. never leave a stale binary behind a failed link --------------------
REM  When the link fails the previous hwbro.exe stays on disk and the automatic
REM  captures show the old program: the verification lies. Delete it first, and
REM  stop when a running instance holds it.
IF EXIST "%TARGET%" (
   DEL "%TARGET%" >NUL 2>&1
   IF EXIST "%TARGET%" (
      ECHO [build] ERROR: "%TARGET%" is locked - close hwBro and try again
      EXIT /B 3
   )
)

REM --- 4. build --------------------------------------------------------------
ECHO [build] hbmk2 %PROJECT%
hbmk2 %PROJECT% %*
IF ERRORLEVEL 1 (
   ECHO [build] BUILD FAILED - no "%TARGET%" was produced
   EXIT /B 1
)
IF NOT EXIST "%TARGET%" (
   ECHO [build] BUILD FAILED - hbmk2 did not produce "%TARGET%"
   EXIT /B 1
)

FOR %%F IN ("%TARGET%") DO ECHO [build] OK - %%~fF (%%~zF bytes)
ENDLOCAL
EXIT /B 0
