@echo off
REM ============================================================
REM  Build Debug APK
REM  Output: app/build/outputs/apk/debug/
REM  Note: Debug build needs no signing and can be installed for testing.
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

echo [INFO] Building Debug APK ...
call gradlew.bat :app:clean :app:assembleDebug --no-configuration-cache
if errorlevel 1 (
    echo [ERROR] Debug build failed. Check the output above.
    pause
    exit /b 1
)

echo.
echo [OK] Debug build finished. Output directory:
echo      app/build/outputs/apk/debug/
echo.
REM Do not block in non-interactive environments (e.g. CI)
if not defined CI pause
endlocal
