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

Para o navegador há dois pacotes escritos à mão, que não são SDKs de servidor (nomes propostos, ainda não publicados): [`js/`](js) (`@perata-sh/js`, o carregador e os tipos do Peráta.js) e [`react/`](react) (`@perata-sh/react`, provedor, formulário pronto, campo de cartão e botão de checkout). Cobrem os quatro modos de checkout: redirecionamento, modal, componentes prontos e cartão transparente.

Os nomes seguem o GitHub: organização `perata-sh`, pacote `sdk`; onde o registro não aceita barra, `perata-sdk` (ou `perata_sdk`). Em cada registro o pacote pertence à organização `perata-sh`.

Todos fazem o mesmo, com a mesma versão (`VERSION`):
- a chave da organização (`prk_test_…` ou `prk_live_…`), que define organização e ambiente;
- os recursos da API (produtos, preços, clientes, sessões do portal do cliente, checkouts, pedidos, pagamentos com parcelamento, cartões salvos, assinaturas, reembolsos);
- listas paginadas com iterador que percorre todas as páginas;
- `Idempotency-Key` nas escritas;
- erros tipados, com o problema de cada campo e o `Retry-After`;
- verificação dos webhooks (Standard Webhooks, com mais de uma assinatura durante a rotação do segredo) e o evento tipado pelo `type`: um tipo para cada dado que ele carrega (pedido, assinatura, checkout, disputa, benefício concedido, cliente, reembolso, identificadores) e um tipo desconhecido para o que a versão ainda não conhece.

A ingestão de uso (`usage.ingest`, `POST /api/v1/usage/token-events`) também está nos SDKs: ela usa a credencial de uma fonte de ingestão (`pus_test_…` ou `pus_live_…`) no lugar da chave da organização, então o cliente é montado com ela. Não tem `Idempotency-Key`: o evento se identifica pelo `external_event_id`, e o erro vem em `data` com o evento recusado em `record`.

Só usam a biblioteca padrão da linguagem, com duas exceções onde ela não tem HTTP, JSON ou HMAC: Dart (`http` e `crypto`, do próprio time do Dart) e Rust (`serde`, `ureq`, `hmac`, `sha2`, `base64`).

## Como é feito

```
openapi.json      o contrato da API pública, exportado pelo perata.sh
generator/        OpenAPI → IR neutra → um emissor por linguagem (templates)
cmd/sdkgen        o comando que gera
regen.sh          sincroniza o contrato do perata.sh e gera os 11 SDKs
<linguagem>/      saída do gerador, uma pasta por linguagem: nunca editada à mão
js/, react/       pacotes do navegador, escritos à mão (não gerados)
Package.swift     o manifesto do Swift na raiz, que o SwiftPM exige
composer.json     o manifesto do PHP na raiz, que o Packagist exige
```

```sh
./regen.sh                  # contrato novo (o commitado no develop do perata.sh) e os 11 SDKs de novo
./regen.sh --worktree       # o mesmo, com o arquivo da árvore de trabalho do perata.sh, commitado ou não
go run ./cmd/sdkgen         # regenerar do openapi.json que já está aqui
./check.sh                  # todos os gates
```

Licença MIT.
