#!/bin/bash
dub upgrade || (sleep 30 && dub upgrade) || (sleep 90 && dub upgrade)

