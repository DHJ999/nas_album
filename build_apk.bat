@echo off
setlocal
REM ============================================================
REM  nas_album release build script   (ASCII ONLY - keep it that way)
REM
REM  Flow:
REM    [1]  pub get
REM    [2]  gradlew assembleRelease                     (normal path)
REM    [2b] if that fails -> manual AOT fallback:
REM           pwsh  <local temp folder>\build_aot_fallback.ps1  (rebuild
REM             app.dill + app.so without forking child processes;
REM             the folder is resolved by wildcard temp* down below)
REM           gradlew assembleRelease -x :app:compileFlutterBuildRelease
REM             (skip the flutter task, package with the artifacts above)
REM    [3]  copy version-numbered APK to Desktop
REM
REM  Why the fallback: this machine has a system-level fault where
REM  Dart/Node cannot spawn child processes (CreateFile failed 231,
REM  process_win.cc:742). It breaks flutter_tools' kernel_snapshot and
REM  AOT steps, and therefore the :app:compileFlutterBuildRelease task.
REM  See build_aot_fallback.ps1 (local temp folder) for details.
REM
REM  Quality gates (analyze / test) are intentionally NOT run here:
REM  they crash under the same fault. Run them manually elsewhere.
REM ============================================================
set "FLUTTER_ROOT=D:/flutter"
set "JAVA_HOME=D:/Android/Android Studio/jbr"
set "ANDROID_HOME=D:/Android/Sdk"
set "ANDROID_SDK_ROOT=D:/Android/Sdk"
set "FLUTTER_SUPPRESS_ANALYTICS=true"
set "PUB_HOSTED_URL=https://pub.flutter-io.cn"
set "FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn"

set "DART=D:/flutter/bin/cache/dart-sdk/bin/dart.exe"
set "SNAP=D:/flutter/bin/cache/flutter_tools.snapshot"
set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not exist "%PWSH%" set "PWSH=pwsh"

set "ROOT=E:\Code\nas_album"
set "PROJ=E:/Code/nas_album/app"
set "LOG=E:/Code/nas_album/_build_log.txt"
set "OUT=E:\Code\nas_album\app\build\app\outputs\flutter-apk\app-release.apk"
set "DEST=F:\Users\%USERNAME%\Desktop"

echo === BUILD START %date% %time% > "%LOG%"

REM ---------- [0/3] generate interface params (not in repo) ----------
echo [0/3] gen secrets ...
pushd "%PROJ%"
"%DART%" tool\gen_secrets.dart >> "%LOG%" 2>&1
if errorlevel 1 echo === [0/3] gen_secrets FAILED - check app\tool\secrets.json >> "%LOG%"
popd

REM ---------- [1/3] pub get (no child process needed, usually OK) ----------
echo [1/3] pub get ...
echo === [1/3] pub get === >> "%LOG%"
pushd "%PROJ%"
"%DART%" "%SNAP%" --no-version-check pub get >> "%LOG%" 2>&1
if errorlevel 1 echo === [1/3] pub get FAILED - continuing, gradle will decide >> "%LOG%"
popd

REM ---------- [2/3] gradle assembleRelease (normal path) ----------
echo [2/3] building release apk with gradle (normal path) ...
echo === [2/3] gradle assembleRelease (normal) === >> "%LOG%"
pushd "%PROJ%\android"
call gradlew.bat assembleRelease --console=plain >> "%LOG%" 2>&1
set "RC=%errorlevel%"
popd
if "%RC%"=="0" goto deliver

REM ---------- [2b/3] manual AOT fallback ----------
echo [2/3] normal path FAILED (rc=%RC%) - trying AOT fallback ...
echo === [2/3] normal path failed rc=%RC% - AOT fallback === >> "%LOG%"
set "FALLBACK="
for /d %%d in ("%ROOT%\temp*") do if exist "%%d\build_aot_fallback.ps1" set "FALLBACK=%%d\build_aot_fallback.ps1"
if not defined FALLBACK if exist "%ROOT%\docs\build_aot_fallback.ps1" set "FALLBACK=%ROOT%\docs\build_aot_fallback.ps1"
if not defined FALLBACK (
  echo === fallback script not found: temp*\build_aot_fallback.ps1 >> "%LOG%"
  echo BUILD FAILED - fallback script missing - see %LOG%
  goto end
)
echo === fallback script: %FALLBACK% >> "%LOG%"
"%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%FALLBACK%" >> "%LOG%" 2>&1
if errorlevel 1 (
  echo === fallback AOT FAILED - see %LOG% >> "%LOG%"
  echo BUILD FAILED - fallback AOT - see %LOG%
  goto end
)
pushd "%PROJ%\android"
call gradlew.bat assembleRelease -x :app:compileFlutterBuildRelease --console=plain >> "%LOG%" 2>&1
set "RC=%errorlevel%"
popd
if not "%RC%"=="0" (
  echo === fallback gradle FAILED - see %LOG% >> "%LOG%"
  echo BUILD FAILED - fallback gradle - see %LOG%
  goto end
)

:deliver
REM ---------- [3/3] deliver version-numbered copy to Desktop ----------
echo [3/3] copying to Desktop ...
echo === [3/3] copy to Desktop === >> "%LOG%"
if not exist "%DEST%" mkdir "%DEST%"
REM Version comes from android\local.properties, because the gradle
REM route does not read pubspec.yaml. No alias copy, no "latest" copy.
set "VER="
for /f "tokens=2 delims==" %%v in ('findstr /b "flutter.versionName=" "%PROJ%\android\local.properties"') do set "VER=%%v"
if "%VER%"=="" (
  echo === WARN: version not found in local.properties - copy skipped >> "%LOG%"
  echo WARN: version not found - apk is at %OUT%
) else (
  copy /y "%OUT%" "%DEST%\nas_album_%VER%.apk" >> "%LOG%" 2>&1
  echo === COPIED nas_album_%VER%.apk >> "%LOG%"
  echo DONE: %DEST%\nas_album_%VER%.apk
)

:end
echo === FINISH %date% %time% >> "%LOG%"
