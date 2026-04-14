#!/bin/bash
set -euo pipefail

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
NORMAL="\033[0m"

DC="${DC:-dmd}"

fail_count=0
pass_count=0

in_ci() { [[ -n "${CI:-}" ]]; }

ci_group_start() { in_ci && echo "::group::$1"; }
ci_group_end()   { in_ci && echo "::endgroup::"; }


echo "Compiling serve-d in release mode with ${DC}..."
ci_group_start "Building serve-d"

pushd .. > /dev/null
if [[ "$DC" == "dmd" ]]; then
    echo "(Debug build because using DMD)"
    dub build --compiler="${DC}"
else
    dub build --build=release --compiler="${DC}"
fi
popd > /dev/null

ci_group_end

if [[ $# -gt 0 ]]; then
    tests=("$@")
else
    # Collect matching dirs into an array to avoid word-splitting / glob issues
    tests=(tc*)
fi

if [[ ${#tests[@]} -eq 0 ]]; then
    echo "No test cases found." >&2
    exit 1
fi

echo "Running ${#tests[@]} test(s) with ${DC}..."

for testCase in "${tests[@]}"; do
    echo -e "${YELLOW}${testCase}${NORMAL}"
    ci_group_start "$testCase"

    pushd "$testCase" > /dev/null

    # Optional: download and stage DCD binaries
    if [[ -f .needs_dcd ]]; then
        pushd ../data/dcd > /dev/null
        "$DC" -I../../../workspace-d/source -run download_dcd.d
        popd > /dev/null

        # Only copy if the binaries were actually produced
        for bin in ../data/dcd/dcd-server* ../data/dcd/dcd-client*; do
            [[ -e "$bin" ]] && cp "$bin" .
        done
    fi

    # Upgrade deps; failures are non-fatal (network may be unavailable in CI)
    dub upgrade 2>&1 || true

    # Run the test; capture exit code without breaking set -e
    result=0
    dub --compiler="${DC}" 2>&1 || result=$?

    ci_group_end

    if [[ $result -eq 0 ]]; then
        echo -e "${YELLOW}${testCase}:${NORMAL} ... ${GREEN}Test Pass${NORMAL}"
        (( pass_count++ )) || true
    else
        echo -e "${YELLOW}${testCase}:${NORMAL} ... ${RED}Test Fail${NORMAL}"
        (( fail_count++ )) || true
    fi

    popd > /dev/null
done

if [[ $fail_count -eq 0 ]]; then
    echo -e "${GREEN}${pass_count} tests passed and ${fail_count} failed.${NORMAL}"
else
    echo -e "${RED}${pass_count} tests passed and ${fail_count} failed.${NORMAL}"
    exit 1
fi
