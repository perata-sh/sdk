#!/bin/sh
# Writes every SDK again from the API's contract.
#
#   ./regen.sh              the contract committed at the HEAD of perata.sh's develop
#   ./regen.sh <ref>        the contract committed at another ref (a branch, a tag, a hash)
#   ./regen.sh --worktree   the contract file as it stands in perata.sh's checkout,
#                           uncommitted changes included
#
# PERATA_SH names the perata.sh checkout (../perata.sh by default). The contract
# is copied into openapi.json, then `go run ./cmd/sdkgen` writes the eleven
# server SDKs. The hand-written js/ and react/ are not touched. Run ./check.sh
# afterwards: nothing is finished until it exits zero.
set -eu
cd "$(dirname "$0")"
export GOWORK=off

perata_sh="${PERATA_SH:-../perata.sh}"
contract=docs/contracts/api.openapi.json
ref="${1:-develop}"

if [ "$ref" = "--worktree" ]; then
	source="$perata_sh/$contract"
	[ -f "$source" ] || { echo "regen: $source does not exist" >&2; exit 1; }
	echo "regen: contract from $source (working tree)"
else
	tmp=$(mktemp "${TMPDIR:-/tmp}/perata-contract.XXXXXX")
	trap 'rm -f "$tmp"' EXIT
	git -C "$perata_sh" show "$ref:$contract" >"$tmp" || { echo "regen: $ref has no $contract in $perata_sh" >&2; exit 1; }
	source="$tmp"
	echo "regen: contract from $perata_sh at $ref ($(git -C "$perata_sh" rev-parse --short "$ref"))"
fi

go run ./cmd/sdkgen -sync "$source"
