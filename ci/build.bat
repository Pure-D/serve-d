@echo on

dub build --compiler=ldc2 --arch=x86

serve-d.exe --version

7za a serve-d.zip serve-d.exe libcurl.dll libeay32.dll ssleay32.dll
