# Catálogo: produtos, preços, descontos e benefícios

O catálogo é de cada ambiente. Monte-o primeiro no Teste e, quando for à Produção, crie tudo de novo lá e guarde os novos ids (veja `producao.md`).

## Produtos

| Ação | Rota | Escopo |
|---|---|---|
| Criar | `POST /api/v1/products` com `name` (obrigatório) e `description` | `products:write` |
| Ler, listar | `GET /api/v1/products/{id}`, `GET /api/v1/products` | `products:read` |
| Alterar nome ou descrição de um produto ativo | `PATCH /api/v1/products/{id}` | `products:write` |
| Arquivar | `POST /api/v1/products/{id}/archive` | `products:write` |

Arquivar tira o produto das vendas novas; o que já foi vendido continua apontando para ele. O produto não guarda preço nem benefício: o preço se cria à parte, e a ligação de um benefício a um produto se faz no painel.

## Preços

`POST /api/v1/prices` (escopo `products:write`) cria um preço em reais; `GET /api/v1/prices?product_id=...` lista (`products:read`). Não há rota para ler um preço sozinho, alterar nem arquivar: um preço errado se corrige criando outro.

Campos do corpo:

| Campo | Regra |
|---|---|
| `product_id` | obrigatório |
| `amount_cents` | o valor do preço fixo (`pricing_model` `fixed`, o padrão), em centavos; obrigatório nele, `0` é gratuito. Nos outros modelos é recusado com 422 |
| `type` | obrigatório: `one_time` (cobra uma vez) ou `recurring` (assinatura) |
| `interval` | `day`, `week`, `month` ou `year`; obrigatório no recorrente, proibido no avulso |
| `interval_count` | de quantos em quantos intervalos renova; 1 se omitido. Com `day` ou `week`, de 1 a 999; com `month`, de 1 a 12 (`3` é trimestral, `6` semestral); com `year`, só 1. O avulso não tem |
| `pricing_model` | como o valor é calculado: `fixed` (padrão), `per_unit`, `seat`, `volume` ou `graduated`. São os mesmos modelos que o painel cria |
| `unit_amount_cents` | o valor de uma unidade (`per_unit`) ou de um assento (`seat`), em centavos; obrigatório nesses dois e recusado nos outros |
| `tiers` | as faixas de `volume` e `graduated`, de 1 a 50, em ordem: `[{"up_to": 1, "unit_amount_cents": 25000}, {"up_to": null, "unit_amount_cents": 15000}]`. `up_to` é o limite da faixa, inclusive, crescente; `null` só na última, que não tem limite |
| `unit_label`, `unit_label_plural` | como o preço chama a unidade (`câmera`, `câmeras`), até 40 caracteres; só em `per_unit`, `volume` e `graduated` |
| `minimum_units`, `maximum_units` | o menos e o mais que uma compra leva de unidades; só nos mesmos três modelos |

### Preço por quantidade

O checkout cobra o preço vezes a quantidade (`quantity`), pelo modelo do preço:

- `per_unit` e `seat`: `unit_amount_cents` por unidade ou assento.
- `graduated`: cada faixa cobra as suas unidades ao seu valor. Com a 1ª unidade a R$ 250,00 e as seguintes a R$ 150,00, três unidades custam 250 + 150 + 150 = R$ 550,00.
- `volume`: a quantidade inteira é cobrada pelo valor da faixa em que ela cai. Com até 10 a R$ 5,00 e acima disso a R$ 4,00, 11 unidades custam 11 x 4,00 = R$ 44,00.

Um mensal por câmera, a 1ª a R$ 250,00 e as demais a R$ 150,00 (o mesmo corpo com `"interval": "day"` é o preço diário):

```json
{
  "product_id": "<id do produto>",
  "type": "recurring",
  "interval": "month",
  "pricing_model": "graduated",
  "tiers": [
    {"up_to": 1, "unit_amount_cents": 25000},
    {"up_to": null, "unit_amount_cents": 15000}
  ],
  "unit_label": "câmera",
  "unit_label_plural": "câmeras"
}
```

No SDK, `PricesCreateParams` aceita esses campos a partir da 0.5.7 (antes, `amount_cents` era obrigatório e não havia `pricing_model` nem `tiers`: crie o preço pela API REST). O preço devolvido traz `pricing_model`, `unit_amount_cents`, `tiers` (vazio fora de `volume` e `graduated`) e `amount_cents` 0 nos modelos por quantidade. Uma escada que não fecha (`up_to` repetido ou fora de ordem, última faixa com limite, faixa sem valor) volta 422 com o campo `tiers`. Ao abrir o checkout, envie `quantity` (`POST /api/v1/checkouts`): a sessão devolve o total já calculado em `amount_cents`.

Os tipos de preço que aparecem nas integrações:

1. **Fixo**: o checkout cobra o valor do preço (`amount_cents`), uma vez no `one_time`.
2. **Recorrente** (`recurring`): vira uma assinatura. Veja `assinaturas.md`. Todo preço lido pela API devolve `interval_count`.
3. **Valor livre** (`custom`): o valor não é do preço, é de cada checkout. Serve quando o seu sistema calcula o total do pedido (multa, juros, desconto, lista de itens). O checkout envia `amount_cents` e `items`; sem `amount_cents` é o comprador quem digita o valor. O preço de valor livre tem um mínimo e um máximo que **se definem no painel**: a API de preços ainda não cria esse tipo (`type` só aceita `one_time` e `recurring`), então peça ao dono que o crie em Teste e em Produção e passe os dois ids. Um `amount_cents` fora do mínimo ou do máximo é recusado com 422.

Exemplo, Go (um produto com preço trimestral):

```go
product, err := client.Products.Create(ctx,
	perata.ProductsCreateParams{Name: "Plano Câmera"},
	perata.WithIdempotencyKey("produto-plano-camera"))
if err != nil {
	return err
}
price, err := client.Prices.Create(ctx, perata.PricesCreateParams{
	ProductID:     product.ID,
	AmountCents:   14970,
	Type:          "recurring",
	Interval:      ptr("month"),
	IntervalCount: ptr(int64(3)),
}, perata.WithIdempotencyKey("preco-plano-camera-trimestral"))
```

TypeScript:

```ts
const product = await perata.products.create({ name: "Plano Câmera" }, { idempotencyKey: "produto-plano-camera" });
const price = await perata.prices.create(
  { product_id: product.id, amount_cents: 14970, type: "recurring", interval: "month", interval_count: 3 },
  { idempotencyKey: "preco-plano-camera-trimestral" },
);
```

Python:

```python
product = perata.products.create({"name": "Plano Câmera"}, idempotency_key="produto-plano-camera")
price = perata.prices.create(
    {"product_id": product.id, "amount_cents": 14970, "type": "recurring", "interval": "month", "interval_count": 3},
    idempotency_key="preco-plano-camera-trimestral",
)
```

Idempotency-Key também vale aqui: sem uma chave sua, repetir o script cria outro produto.

## Descontos

`POST /api/v1/discounts` (`discounts:write`); `GET /discounts`, `GET /discounts/{id}` (`discounts:read`); `PATCH` e `DELETE /discounts/{id}`.

| Campo | Regra |
|---|---|
| `name` | obrigatório; aparece para o cliente quando o desconto é aplicado |
| `type` | obrigatório: `percentage` ou `fixed` |
| `basis_points` | de 1 a 10000 (10000 é 100%); obrigatório no `percentage` |
| `amount_cents` | em centavos; obrigatório no `fixed` |
| `duration` | obrigatório: `once` (só a primeira fatura), `repeating` ou `forever` |
| `duration_in_months` | de 1 a 120; só no `repeating` |
| `code` | opcional, até 64 letras, números, hífen ou sublinhado. O que o comprador digita. Sem ele o desconto só vale por link de checkout ou pela API |
| `max_redemptions`, `max_redemptions_per_customer` | limites de uso (por cliente, de 1 a 100) |
| `starts_at`, `ends_at` | RFC 3339; `starts_at` é agora se omitido |
| `product_ids` | restringe a estes produtos; vazio vale para todos |

Regras: o tipo e a duração não mudam depois de criado; depois do primeiro uso, o valor e os meses também não. Excluir libera o código e não apaga o que o desconto já descontou. Três maneiras de usar:

- O comprador digita o `code` no checkout (o checkout precisa de `allow_discount_codes: true`).
- O seu servidor aplica sozinho com `discount_id` ao criar o checkout (SDK 0.5.6+). Um desconto limitado a outros produtos é recusado com 422.
- Fixo num link de checkout (`discount_id` do link).

Um desconto vale sobre o preço inteiro. Desconto só numa parte do valor (só na câmera, e não na conexão, por exemplo) ainda não existe: para um pedido de valor livre, mande a linha negativa em `items` (veja `checkout.md`).

## Benefícios

Benefício é o que o cliente ganha ao comprar (uma licença, uma flag de recurso, créditos de consumo).

- Criar pela API (`POST /api/v1/benefits`, `benefits:write`): tipos `custom`, `license_key`, `feature_flag` e `meter_credit`. Os tipos `downloadable`, `discord` e `github_repository` se configuram no painel.
- Corpo: `type` e `name` (até 80 caracteres) são obrigatórios; `description`; `visibility` (`public` ou `private`); `properties` do tipo; `metadata`.
- `properties`: `custom` leva `note`; `license_key` leva `prefix`, `expires_in`, `expires_unit` (`day`, `month`, `year`), `activation_limit`, `customer_can_deactivate`, `usage_limit`; `meter_credit` leva `meter_id`, `units`, `rollover`; `feature_flag` não leva nada (os valores da flag ficam em `metadata`).
- `PATCH` muda nome, visibilidade, propriedades e metadados; o tipo e a descrição não mudam. `DELETE` tira o benefício dos produtos e o revoga de quem o tem.
- `GET /api/v1/benefits/{id}/grants` (`benefits:read`) lista as concessões; filtros `customer_id` e `is_granted` (`true` vigentes, `false` revogadas).

Para saber o que um cliente pode usar agora, o seu aplicativo lê `GET /api/v1/customers/{id}/state` (`customers:read`): devolve as assinaturas ativas ou em teste (`active_subscriptions`) e os benefícios vigentes (`granted_benefits`), inclusive as flags. Esta é a leitura certa para decidir acesso, no lugar de guardar uma cópia por conta própria.

## Links de checkout

Um link de checkout (`POST /api/v1/checkout-links`, `checkout_links:write`) é uma oferta durável de um ou mais produtos: cada visita abre uma sessão nova. Campos: `label`, `product_id` com `price_id` (ou `price_ids`, um preço de cada produto, até 20), `discount_id`, `quantity`, `allow_discount_codes`, `require_billing_address`, `capture_mode`, `max_installments` (de 0 a 12; 0 segue a organização), `success_url`, `cancel_url`, `expires_at`, `trial_interval`, `trial_interval_count`, `metadata`. Serve para vender sem código no servidor (um botão, um e-mail). Para vender um pedido de um cliente específico, com valor e referência, crie um checkout (`checkout.md`).
