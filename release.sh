#!/bin/sh
dub build --compiler=ldc2 --build=release --arch=x86_64 || exit 1
strip bin/serve-d
VERSION=$(./bin/serve-d --version 2>&1 | grep -oh "serve-d standalone v[0-9]*\.[0-9]*\.[0-9]*" | sed "s/serve-d standalone v//")
echo $VERSION > version.txt
echo $VERSION
tar cfJ serve-d_$VERSION-linux-x86_64.tar.xz bin/serve-d

