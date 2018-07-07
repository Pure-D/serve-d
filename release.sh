#!/bin/sh
dub upgrade
dub build --compiler=ldc --build=release --arch=x86_64 || exit 1
strip serve-d
VERSION=$(./serve-d --version 2>&1 | grep -oh "serve-d v[0-9]*\.[0-9]*\.[0-9]*" | sed "s/serve-d v//")
echo $VERSION > version.txt
echo $VERSION
tar cfJ serve-d_$VERSION-linux-x86_64.tar.xz serve-d

