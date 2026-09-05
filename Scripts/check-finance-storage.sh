#!/bin/sh
set -eu
finance_repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
finance_check_dir=$(mktemp -d)
trap 'rm -rf "$finance_check_dir"' EXIT HUP INT TERM
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcrun swiftc -parse-as-library -module-cache-path "$finance_check_dir/cache" \
    "$finance_repo"/Financium/Models/Core/*.swift \
    "$finance_repo/Tests/FinanceStorage/Regression.swift" \
    -o "$finance_check_dir/check"
"$finance_check_dir/check" "$finance_repo/Tests/FinanceStorage/legacy-fixtures.json"
