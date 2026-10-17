# SDKs da Peráta

Os SDKs oficiais da API da Peráta, num monorepo no padrão do Polar: um contrato, um gerador e um pacote por linguagem.

| Linguagem | Pasta | Pacote |
|---|---|---|
| Go | [`go/`](go) | `github.com/perata-sh/sdk/go` |
| TypeScript / JavaScript | [`typescript/`](typescript) | `@perata-sh/sdk` (npm) |
| Python | [`python/`](python) | `perata` (PyPI) |
| PHP | [`php/`](php) | `perata/perata-php` (Packagist) |

Todos fazem o mesmo, com a mesma versão (`VERSION`):
- a chave da organização (`prk_test_…` ou `prk_live_…`), que define organização e ambiente;
- os recursos da API (produtos, preços, clientes, checkouts, pedidos, pagamentos, cartões salvos, assinaturas, reembolsos);
- listas paginadas com iterador que percorre todas as páginas;
- `Idempotency-Key` nas escritas;
- erros tipados, com o problema de cada campo e o `Retry-After`;
- verificação dos webhooks (Standard Webhooks).

Nenhum depende de biblioteca de terceiros.

## Como é feito

```
openapi.json      o contrato da API pública, exportado pelo perata.sh
generator/        OpenAPI → IR neutra → um emissor por linguagem (templates)
cmd/sdkgen        o comando que gera
go/ typescript/ python/ php/   saída do gerador: nunca editada à mão
```

```sh
go run ./cmd/sdkgen -sync ../perata.sh/docs/contracts/api.openapi.json   # contrato novo
go run ./cmd/sdkgen                                                      # regenerar
./check.sh                                                               # todos os gates
```

Licença MIT.
