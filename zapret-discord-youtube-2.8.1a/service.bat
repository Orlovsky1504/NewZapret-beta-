@echo off
rem DEPRECATED: service.bat was replaced by zapret.bat (same menu).
rem Kept so old shortcuts and habits keep working.
chcp 65001 >nul
echo [zapret] service.bat устарел; запускаю zapret.bat. / service.bat is deprecated; forwarding to zapret.bat.
call "%~dp0zapret.bat"
