# Working in this repository

Peráta's SDKs, one package per language, generated from the public API's
contract the way Polar generates its own. Read this before changing anything.

## What is generated and what is written

- `go/`, `typescript/`, `python/`, `php/`, `ruby/`, `java/`, `csharp/`,
  `elixir/`, `dart/`, `rust/` and `swift/` are **output**. The generator
  empties each one and writes it again, so an edit there is lost on the next
  run. Change the template instead.
- `generator/templates/<language>/` is where every SDK's hand-written part
  lives: client, errors, pagination, webhooks, tests, README. A `.tmpl` file is
  rendered with the IR; any other file is copied. `_dot_` in a name becomes `.`;
  `__model__` and `__service__` write the file once per model or per service.
- `generator/` (Go) reads `openapi.json` into a language-neutral IR
  (`ir.go`) and renders it (`emit.go`, `lang_<language>.go`).
- `openapi.json` is copied from perata.sh (`docs/contracts/api.openapi.json`,
  which perata.sh's CI keeps equal to the routes). Never edit it here: change
  the API in perata.sh, export it, then `go run ./cmd/sdkgen -sync …`.

## The gates

`./check.sh` runs all of them; nothing is finished until it exits zero.
- generator: gofmt, vet, test, regenerate;
- go: vet and test;
- typescript: `tsc --noEmit` and `node --test`;
- python: unittest and `mypy --strict` on 3.11;
- php: `tests/run.php` and PHPStan level 8;
- ruby: minitest under `ruby -w`;
- java: `mvn verify` (`-Xlint:all -Werror`);
- csharp: `dotnet test`, warnings as errors;
- elixir: compile and test with `--warnings-as-errors`;
- dart: `dart format`, `dart analyze --fatal-infos`, `dart test`;
- rust: `cargo fmt --check`, clippy `-D warnings`, `cargo test`;
- swift: `swift test` in `swift/` and `swift build` at the root (macOS only:
  CryptoKit and Network; CI runs it in its own macOS job).

`Package.swift` at the root is hand-written, because SwiftPM resolves a
package from the repository root; keep it in step with `swift/Package.swift`.

CI also fails when the committed SDKs differ from what the generator writes.

Use `$(go env GOROOT)/bin/gofmt`: a Homebrew gofmt on the PATH may be a newer
release that formats differently from CI.

## Rules

- Every SDK does the same thing, under the same version (`VERSION`). A feature
  goes into every language, with the same test in each, or into none.
- No third-party runtime dependency where the language's standard library can
  do HTTP, JSON and HMAC. The two exceptions are deliberate: Dart uses `http`
  and `crypto` from dart.dev, and Rust uses serde, serde_json, ureq, hmac,
  sha2 and base64. Do not add others.
- Each SDK keeps its language's idiom for walking every page: Go `ListIter`,
  TypeScript async iterators, Python and Ruby `list_iter`, PHP generators,
  Java `Iterable`, C# `IAsyncEnumerable`, Elixir `list_stream`, Dart and Swift
  streams, Rust `Iterator`.
- Webhook verification is Standard Webhooks, exactly what perata.sh signs
  (`app/Services/Webhooks.go`). Change both together or neither.
- Code, comments and commits are in English; the READMEs are in Brazilian
  Portuguese. Commits are authored by `Paulo R. Lima <paulorlima@hyz.is>` (Peráta is a product), set with `git config` in the checkout, without AI
  attribution.

## Names

The package is the GitHub repository: organization `perata-sh`, package
`sdk`. npm `@perata-sh/sdk`, Packagist `perata-sh/sdk`, Maven `sh.perata:sdk`,
Go and Swift `github.com/perata-sh/sdk`; where a registry has no namespace,
`perata-sdk` (PyPI, RubyGems, crates.io), `perata_sdk` (Hex, pub.dev)
and `PerataSh.Sdk` (NuGet). In every registry the package belongs to the
`perata-sh` organization. Never rename or add a package without Paulo's
confirmation.

## Release

One version for every language.
1. Bump `VERSION`, run `go run ./cmd/sdkgen` and `./check.sh`, and commit on
   develop; after CI, fast-forward main.
2. Tag `vX.Y.Z` and `go/vX.Y.Z` on that commit and push both. The `v` tag runs
   `.github/workflows/release.yml` (npm and PyPI by trusted publishing); the
   `go/` tag is the Go module's version, and Swift and Packagist read the `v`
   tag from this repository through the root `Package.swift` and
   `composer.json`, which are hand-written and must stay in step with
   `swift/Package.swift` and `php/composer.json`.
