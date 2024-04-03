set -e
set -x

dub build --compiler=ldc2 --build=$BUILD --arch=$ARCH
strip serve-d
if [ "$CROSS" = 1 ]; then
	ls serve-d
else
	./serve-d --version
fi

tar cfJ serve-d.tar.xz serve-d
tar czf serve-d.tar.gz serve-d
