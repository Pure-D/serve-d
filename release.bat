rem Building & compressing serve-d for release inside a virtual machine with Windows 8 or above

cd %~dp0

@if not exist version.txt (
	echo.
    echo !-- Error: version.txt is missing :/
    echo.
    pause
    goto :eof
)

rem This will sync this repo with the folder %windir%\..\buildsd
robocopy . %windir%\..\buildsd /MIR /XA:SH /XD .* /XF .* /XF *.zip
pushd %windir%\..\buildsd

set /p Version=<version.txt
dub build --compiler=ldc2 --arch=x86

if exist windows del /S /Q windows
mkdir windows
copy serve-d.exe windows\serve-d.exe
copy libcurl.dll windows\libcurl.dll
copy libeay32.dll windows\libeay32.dll
copy ssleay32.dll windows\ssleay32.dll

if exist windows.zip del windows.zip
powershell -nologo -noprofile -command "& { Add-Type -A 'System.IO.Compression.FileSystem'; [IO.Compression.ZipFile]::CreateFromDirectory('windows', 'windows.zip'); }"
popd

move %windir%\..\buildsd\windows.zip "serve-d-%Version%-windows.zip"
pause
