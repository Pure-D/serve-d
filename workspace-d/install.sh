#!/bin/sh
cd installer
dub build
cd ..
./installer/iworkspaced .
