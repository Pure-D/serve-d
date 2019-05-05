#!/bin/bash

rm -rf ~/.dub/packages/bmfont-0.1.0
rm -rf workspace/.dub
rm -f workspace/dub.selections.json

if [ -z dcd-server ] || [ -z dcd-client ]; then
	wget https://github.com/dlang-community/DCD/releases/download/v0.11.1/dcd-v0.11.1-linux-x86_64.tar.gz
	tar xvf dcd-v0.11.1-linux-x86_64.tar.gz
	rm dcd-v0.11.1-linux-x86_64.tar.gz
fi

dub -- ../serve-d
