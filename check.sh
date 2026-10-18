#!/bin/sh
# The gates every change passes: the generator and its tests, the SDKs being
# exactly what the generator writes, and each language's own tests and type
# checks. CHECK_DRIFT=1 (CI) also fails when a regenerated SDK differs from
# what is committed. MYPY and PHPSTAN name those tools when they are not on
# the PATH. Swift needs Apple's toolchain (CryptoKit, Network): it runs only on
# macOS, and SKIP_SWIFT=1 leaves it to the macOS CI job.
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
if [ "${CHECK_DRIFT:-}" = 1 ] && [ -n "$(git status --porcelain -- openapi.json go typescript python php ruby java csharp elixir dart rust swift Package.swift)" ]; then
	echo "the SDKs differ from what the generator writes: run go run ./cmd/sdkgen and commit"
	git status --porcelain -- go typescript python php ruby java csharp elixir dart rust swift Package.swift
	exit 1
fi

echo "== go"
(cd go && go vet ./... && go test -count=1 ./...)

echo "== typescript"
(cd typescript && npm install --no-audit --no-fund --silent && npx tsc -p tsconfig.json --noEmit && node --test 'test/*.test.ts')

echo "== python"
(cd python && PYTHONPATH=src python3 -m unittest discover -s tests && "${MYPY:-mypy}" --strict --python-version 3.11 src/perata)

echo "== php"
(cd php && php tests/run.php && "${PHPSTAN:-phpstan}" analyse --no-progress --level 8 src)

echo "== ruby"
(cd ruby && ruby -w -Ilib -Itest test/perata_test.rb)

echo "== java"
(cd java && mvn -q -B verify)

echo "== csharp"
(cd csharp && dotnet test --nologo)

echo "== elixir"
(cd elixir && mix compile --warnings-as-errors && mix test --warnings-as-errors)

echo "== dart"
(cd dart && dart pub get && dart format --output=none --set-exit-if-changed . && dart analyze --fatal-infos && dart test)

echo "== rust"
(cd rust && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test)

if [ "${SKIP_SWIFT:-}" != 1 ]; then
	echo "== swift"
	swift=swift
	if command -v xcrun >/dev/null; then
		swift="xcrun swift"
	fi
	(cd swift && $swift test) && $swift build
fi
