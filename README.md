# SDKs da Peráta

Os SDKs oficiais da API da Peráta, num monorepo no padrão do Polar: um contrato, um gerador e um pacote por linguagem.

| Linguagem | Pasta | Pacote |
|---|---|---|
| Go | [`go/`](go) | `github.com/perata-sh/sdk/go` |
| TypeScript / JavaScript | [`typescript/`](typescript) | `@perata-sh/sdk` (npm) |
| Python | [`python/`](python) | `perata-sdk` (PyPI) |
| PHP | [`php/`](php) | `perata-sh/sdk` (Packagist) |
| Ruby | [`ruby/`](ruby) | `perata-sdk` (RubyGems) |
| Java (e Kotlin) | [`java/`](java) | `sh.perata:sdk` (Maven Central) |
| C# / .NET | [`csharp/`](csharp) | `PerataSh.Sdk` (NuGet) |
| Elixir | [`elixir/`](elixir) | `perata_sdk` (Hex) |
| Dart / Flutter | [`dart/`](dart) | `perata_sdk` (pub.dev) |
| Rust | [`rust/`](rust) | `perata-sdk` (crates.io) |
| Swift (iOS, macOS) | [`swift/`](swift) | Swift Package Manager: `https://github.com/perata-sh/sdk` |

Os nomes seguem o GitHub: organização `perata-sh`, pacote `sdk`; onde o registro não aceita barra, `perata-sdk` (ou `perata_sdk`). Em cada registro o pacote pertence à organização `perata-sh`.

Todos fazem o mesmo, com a mesma versão (`VERSION`):
- a chave da organização (`prk_test_…` ou `prk_live_…`), que define organização e ambiente;
- os recursos da API (produtos, preços, clientes, checkouts, pedidos, pagamentos, cartões salvos, assinaturas, reembolsos);
- listas paginadas com iterador que percorre todas as páginas;
- `Idempotency-Key` nas escritas;
- erros tipados, com o problema de cada campo e o `Retry-After`;
- verificação dos webhooks (Standard Webhooks).

Só usam a biblioteca padrão da linguagem, com duas exceções onde ela não tem HTTP, JSON ou HMAC: Dart (`http` e `crypto`, do próprio time do Dart) e Rust (`serde`, `ureq`, `hmac`, `sha2`, `base64`).

## Como é feito

```
openapi.json      o contrato da API pública, exportado pelo perata.sh
generator/        OpenAPI → IR neutra → um emissor por linguagem (templates)
cmd/sdkgen        o comando que gera
<linguagem>/      saída do gerador, uma pasta por linguagem: nunca editada à mão
Package.swift     o manifesto do Swift na raiz, que o SwiftPM exige
composer.json     o manifesto do PHP na raiz, que o Packagist exige
```

```sh
go run ./cmd/sdkgen -sync ../perata.sh/docs/contracts/api.openapi.json   # contrato novo
go run ./cmd/sdkgen                                                      # regenerar
./check.sh                                                               # todos os gates
```

Licença MIT.
