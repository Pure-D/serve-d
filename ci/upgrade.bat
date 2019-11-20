dub upgrade
if %errorlevel% == 0 goto :eof

timeout /t 30 /nobreak > NUL
dub upgrade

if %errorlevel% == 0 goto :eof

timeout /t 90 /nobreak > NUL
dub upgrade

:eof
