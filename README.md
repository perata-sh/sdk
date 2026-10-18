# SDKs da Peráta

Os SDKs oficiais da API da Peráta, num monorepo no padrão do Polar: um contrato, um gerador e um pacote por linguagem.

| Linguagem | Pasta | Pacote |
|---|---|---|
| Go | [`go/`](go) | `github.com/perata-sh/sdk/go` |
| TypeScript / JavaScript | [`typescript/`](typescript) | `@perata-sh/sdk` (npm) |
| Python | [`python/`](python) | `perata` (PyPI) |
| PHP | [`php/`](php) | `perata/perata-php` (Packagist) |
| Ruby | [`ruby/`](ruby) | `perata` (RubyGems) |
| Java (e Kotlin) | [`java/`](java) | `sh.perata:perata-java` (Maven Central) |
| C# / .NET | [`csharp/`](csharp) | `Perata` (NuGet) |
| Elixir | [`elixir/`](elixir) | `perata` (Hex) |
| Dart / Flutter | [`dart/`](dart) | `perata` (pub.dev) |
| Rust | [`rust/`](rust) | `perata` (crates.io) |
| Swift (iOS, macOS) | [`swift/`](swift) | Swift Package Manager: `https://github.com/perata-sh/sdk` |

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
```

```sh
go run ./cmd/sdkgen -sync ../perata.sh/docs/contracts/api.openapi.json   # contrato novo
go run ./cmd/sdkgen                                                      # regenerar
./check.sh                                                               # todos os gates
```

Licença MIT.
