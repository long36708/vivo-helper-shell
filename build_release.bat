@echo off
REM ============================================================
REM  Build Release APK
REM  Output: app/build/outputs/apk/release/
REM  Note: Release build is minified/shrunk. If a keystore is
REM  configured (see below), the APK will be signed; otherwise it
REM  falls back to the debug signing config (still installable).
REM
REM  Signing (optional):
REM    Set in local.properties, or as environment variables:
REM      KEYSTORE_PATH = path\to\your.keystore
REM      KEYSTORE_PASS = store password
REM      KEY_ALIAS     = key alias
REM      KEY_PASSWORD  = key password
REM ============================================================
setlocal
cd /d "%~dp0"

REM Prefer mise-managed JDK 21 if available (the toolchain required by AGP/Kotlin).
REM This avoids Gradle trying to download JDK 21 from foojay.io (unreachable here).
for /f "tokens=*" %%i in ('mise where java@21 2^>nul') do set "JAVA_HOME=%%i"
if defined JAVA_HOME (
    echo [INFO] JAVA_HOME = %JAVA_HOME%
) else (
    echo [WARN] No JDK 21 detected via mise, falling back to current JAVA_HOME/PATH (JDK 21 required)
)
REM Tell Gradle to look for toolchains in the local JDK install dir as well.
if defined JAVA_HOME set "GRADLE_OPTS=-Dorg.gradle.java.installations.paths=%JAVA_HOME%"

echo [INFO] Building Release APK ...
call gradlew.bat :app:clean :app:assembleRelease --no-configuration-cache
if errorlevel 1 (
    echo [ERROR] Release build failed. Check the output above.
    pause
    exit /b 1
)

echo.
echo [OK] Release build finished. Output directory:
echo      app/build/outputs/apk/release/
echo.
REM Do not block in non-interactive environments (e.g. CI)
if not defined CI pause
endlocal
