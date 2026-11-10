rem Building & compressing serve-d for release inside a virtual machine with Windows 8 or above

pushd %~dp0

@if not exist version.txt (
    echo.
    echo !-- Error: version.txt is missing :/
    echo.
    pause
    popd
    goto :eof
)

rem This will sync this repo with the folder %SystemDrive%\buildwd
robocopy . %SystemDrive%\buildwd /MIR /XA:SH /XD .* /XF .* /XF *.zip
pushd %SystemDrive%\buildwd

set /p Version=<version.txt
dub upgrade
dub build --compiler=ldc2 --arch=x86

if exist windows del /S /Q windows
mkdir windows
copy workspace-d.exe windows\workspace-d.exe
copy libcurl.dll windows\libcurl.dll
copy libeay32.dll windows\libeay32.dll
copy ssleay32.dll windows\ssleay32.dll

if exist windows.zip del windows.zip
powershell -nologo -noprofile -command "& { Add-Type -A 'System.IO.Compression.FileSystem'; [IO.Compression.ZipFile]::CreateFromDirectory('windows', 'windows.zip'); }"
popd

move %SystemDrive%\buildwd\windows.zip "workspace-d_%Version%-windows.zip"
popd
pause