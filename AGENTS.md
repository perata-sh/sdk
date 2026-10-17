# Working in this repository

Peráta's SDKs, one package per language, generated from the public API's
contract the way Polar generates its own. Read this before changing anything.

## What is generated and what is written

- `go/`, `typescript/`, `python/` and `php/` are **output**. The generator
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
- php: `tests/run.php` and PHPStan level 8.

CI also fails when the committed SDKs differ from what the generator writes.

Use `$(go env GOROOT)/bin/gofmt`: a Homebrew gofmt on the PATH may be a newer
release that formats differently from CI.

## Rules

- Every SDK does the same thing, under the same version (`VERSION`). A feature
  goes into every language, with the same test in each, or into none.
- No third-party runtime dependency in any SDK: Go's standard library, `fetch`
  and WebCrypto, Python's standard library, PHP's curl and json.
- Each SDK keeps its language's idiom: Go `ListIter`, TypeScript `listIter`
  async iterators, Python `list_iter`, PHP `listIter` generators.
- Webhook verification is Standard Webhooks, exactly what perata.sh signs
  (`app/Services/Webhooks.go`). Change both together or neither.
- Code, comments and commits are in English; the READMEs are in Brazilian
  Portuguese. Commits are authored by `HYZIS <admin@hyz.is>` without AI
  attribution.

## Release

One version for every language. Bump `VERSION`, regenerate, commit
`sdk: release X.Y.Z`, then tag `go/vX.Y.Z` (the Go module) and `vX.Y.Z`.
Publishing to npm, PyPI and Packagist needs the organization's accounts and is
not automated yet; Packagist reads a repository whose root is the package, so
PHP is published from a split of `php/`.
