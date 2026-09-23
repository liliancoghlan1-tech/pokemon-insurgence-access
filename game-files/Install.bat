@echo off
setlocal
title Pokemon Insurgence Accessibility Pack - installer
set "SRC=%~dp0Game files"

echo.
echo   POKEMON INSURGENCE ACCESSIBILITY PACK
echo.
echo   This copies the accessibility mod, and the engine it needs, into your
echo   Pokemon Insurgence folder. Nothing that is already there is deleted,
echo   and the game's own Game.exe is left untouched.
echo.

if not exist "%SRC%\Insurgence-mkxpz.exe" goto nosrc

rem If this pack was unzipped inside the game folder, just use that.
for %%I in ("%~dp0..") do set "GAME=%%~fI"
if exist "%GAME%\Game.rgssad" goto gotgame

:ask
echo   Type or paste the full path of your Pokemon Insurgence folder, then
echo   press Enter. That is the folder that contains Game.exe and Game.rgssad.
echo   For example:  C:\Games\Pokemon Insurgence
echo.
set "GAME="
set /p "GAME=Folder: "
if not defined GAME goto ask
set GAME=%GAME:"=%
if not exist "%GAME%\Game.rgssad" goto badfolder

:gotgame
echo.
echo   Installing into:
echo   %GAME%
echo.
xcopy "%SRC%\*" "%GAME%\" /E /I /Y /Q
if errorlevel 1 goto copyfail

rem The 3D sound library ships as a separate download because of its size.
set "PHONON=no"
if exist "%~dp0phonon.dll" goto addphonon
if exist "%GAME%\accessibility\lib\phonon.dll" set "PHONON=yes"
goto donephonon

:addphonon
copy /Y "%~dp0phonon.dll" "%GAME%\accessibility\lib\phonon.dll" >nul
if errorlevel 1 goto donephonon
set "PHONON=yes"

:donephonon
echo.
echo   DONE.
echo.
if "%PHONON%"=="yes" echo   3D sound: installed.
if "%PHONON%"=="no"  echo   3D sound: NOT installed - see "READ ME FIRST" for the second file.
echo.
echo   From now on start the game with "Play Pokemon Insurgence.bat", which is
echo   now in that folder. Do NOT start Game.exe - that is the old engine and
echo   the mod cannot load into it.
echo.
echo   Start your screen reader before you start the game.
echo.
pause
exit /b 0

:badfolder
echo.
echo   There is no Game.rgssad in that folder, so that is not the game folder.
echo   Try again, or close this window.
echo.
goto ask

:nosrc
echo   Could not find the "Game files" folder next to this installer.
echo   Unzip the whole pack, keeping its folders together, then run this again.
echo.
pause
exit /b 1

:copyfail
echo.
echo   The copy did not finish. The usual causes are: the game is running
echo   (close it and try again), or the game folder is somewhere Windows
echo   protects, such as Program Files (run this installer as administrator).
echo.
pause
exit /b 1
