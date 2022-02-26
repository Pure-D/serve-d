#!/bin/bash

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
NORMAL="\033[0m"

COMPILER="$1"

if [ -z $COMPILER ]; then
	COMPILER="dmd"
fi

fail_count=0
pass_count=0

echo "Compiling serve-d in release mode with ${COMPILER}..."

pushd ..
dub build --build=release --compiler="${COMPILER}"
popd

tests="${@:2}"
if [ -z "$tests" ]; then
	tests=tc*
fi

echo "Running tests with ${COMPILER}..."

for testCase in $tests; do
	echo -e "${YELLOW}$testCase${NORMAL}"
	pushd $testCase

	if [ -f .needs_dcd ]; then
		pushd ../data/dcd
		dmd -I../../../workspace-d/source -run download_dcd.d
		popd
		cp ../data/dcd/dcd-server* .
		cp ../data/dcd/dcd-client* .
	fi

	dub upgrade >testout.txt 2>&1
	dub --compiler="${COMPILER}" >>testout.txt 2>&1
	if [[ $? -eq 0 ]]; then
		echo -e "${YELLOW}$testCase:${NORMAL} ... ${GREEN}Pass${NORMAL}";
		let pass_count=pass_count+1
	else
		echo -e "${YELLOW}$testCase:${NORMAL} ... ${RED}Fail${NORMAL}";
		cat testout.txt
		let fail_count=fail_count+1
	fi

	popd
done

if [[ $fail_count -eq 0 ]]; then
	echo -e "${GREEN}${pass_count} tests passed and ${fail_count} failed.${NORMAL}"
else
	echo -e "${RED}${pass_count} tests passed and ${fail_count} failed.${NORMAL}"
	exit 1
fi