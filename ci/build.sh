set -e
set -x

dub build --compiler=ldc2 --build=$BUILD --arch=$ARCH
strip serve-d
./serve-d --version

tar cfJ serve-d.tar.xz serve-d
