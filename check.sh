#!/bin/sh
# The gates every change passes: the generator and its tests, the SDKs being
# exactly what the generator writes, and each language's own tests and type
# checks. CHECK_DRIFT=1 (CI) also fails when a regenerated SDK differs from
# what is committed. MYPY and PHPSTAN name those tools when they are not on
# the PATH.
set -eu
cd "$(dirname "$0")"
export GOWORK=off

echo "== generator"
unformatted=$("$(go env GOROOT)/bin/gofmt" -l generator cmd go)
if [ -n "$unformatted" ]; then
	echo "not gofmt'd:"
	echo "$unformatted"
	exit 1
fi
go vet ./...
go test -count=1 ./...
go run ./cmd/sdkgen
if [ "${CHECK_DRIFT:-}" = 1 ] && [ -n "$(git status --porcelain -- openapi.json go typescript python php)" ]; then
	echo "the SDKs differ from what the generator writes: run go run ./cmd/sdkgen and commit"
	git status --porcelain -- go typescript python php
	exit 1
fi

echo "== go"
(cd go && go vet ./... && go test -count=1 ./...)

echo "== typescript"
(cd typescript && npm install --no-audit --no-fund --silent && npx tsc -p tsconfig.json --noEmit && node --test test/)

echo "== python"
(cd python && PYTHONPATH=src python3 -m unittest discover -s tests && "${MYPY:-mypy}" --strict --python-version 3.11 src/perata)

echo "== php"
(cd php && php tests/run.php && "${PHPSTAN:-phpstan}" analyse --no-progress --level 8 src)
