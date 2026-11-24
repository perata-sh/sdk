# Depois da venda: pedidos, pagamentos, reembolsos e disputas

## Pedidos e pagamentos

Um **pedido** é um checkout pago; o id dele é o `session_id` do checkout. Um **pagamento** é a tentativa de cobrança dessa venda no cartão, no Pix ou no boleto.

| Ação | Rota | Escopo |
|---|---|---|
| Listar pedidos | `GET /api/v1/orders` | `orders:read` |
| Ler um pedido | `GET /api/v1/orders/{id}` | `orders:read` |
| Fatura do pedido (404 se não houver) | `GET /api/v1/orders/{id}/invoice` | `orders:read` |
| Recibo do pedido | `GET /api/v1/orders/{id}/receipt` | `orders:read` |
| Listar e ler pagamentos | `GET /api/v1/payments`, `GET /api/v1/payments/{id}` | `payments:read` |

Campos que mais importam no **pedido**: `id`, `amount_cents`, `status` (`open`, `confirmed`, `succeeded`, `failed`, `expired`; o do checkout, continua `succeeded` depois de um reembolso), `order_status` (`pending`, `paid`, `partially_refunded`, `refunded`; é o que diz onde o dinheiro está), `paid_at`, `refunded_amount_cents` (soma dos reembolsos que deram certo), `installments`, `installment_interest_cents`, `items`, `metadata`, `client_reference_id`, e, se pagou um ciclo de assinatura, `subscription_id`, `cycle_sequence`, `period_start`, `period_end` (SDK 0.5.6+).

O pedido também diz **qual desconto aplicou**, para o seu sistema gravar o uso do cupom a partir de `order.paid`: `discount_id` (o desconto do catálogo; nulo sem desconto), `discount_code` (o código que o comprador digitou; **nulo quando o desconto veio por `discount_id` ou da assinatura**), `subtotal_cents` (o valor antes do desconto) e `discount_cents` (quanto foi descontado). `subtotal_cents` menos `discount_cents` é sempre o `amount_cents`; sem desconto, `subtotal_cents` é igual a `amount_cents` e `discount_cents` é 0. No pedido de uma **renovação** é o desconto que a assinatura aplicou naquele ciclo: num desconto de uma vez, o ciclo 1 traz `discount_id` e o ciclo 2 vem com `discount_id` nulo e `discount_cents` 0; por alguns meses ou para sempre, os ciclos seguintes repetem o `discount_id` (e `discount_code` fica nulo, porque ninguém digitou código naquele pedido). Os quatro campos são novos: se o SDK instalado ainda não os tem, leia-os do JSON da resposta ou do webhook.

No **pagamento**: `id`, `checkout_id`, `method` (`card`, `pix`, `boleto`), `state` (`unknown`, `pending`, `authorized`, `captured`, `refused`, `canceled`, `refunded`, `partially_refunded`), `amount_cents`, `captured_cents`, `refunded_cents`, `installments`, `installment_amount_cents`.

O pagamento também diz quanto ficou e quando cai: `fee_cents` (a tarifa que a Peráta cobrou da venda) e `net_cents` (`captured_cents` menos `fee_cents`, antes de reembolsos), os dois 0 até a captura; `expected_payout_on` (a data prevista do próximo repasse que paga este pagamento, `AAAA-MM-DD`; nula quando nenhum espera, e num pagamento parcelado é a da próxima parcela); `payout_deposited_on` (o dia em que o último repasse que pagou este pagamento foi depositado; nulo enquanto nenhum foi); `payout_id` (esse repasse, `po_AAAAMMDD`, o id de `GET /payouts/{id}`; nulo enquanto nenhum foi) e `split` (como a venda foi dividida: uma lista com `recipient_id`, `amount_cents`, `fee_cents` e `net_cents` de cada destinatário; uma venda sem divisão tem um só). Os SDKs trazem estes campos a partir da 0.5.9; numa versão anterior, leia o JSON da resposta.

### Achar uma venda: os filtros das listas

As listas de checkouts, pedidos, pagamentos, reembolsos e assinaturas aceitam, conforme a lista:

| Filtro | O que faz |
|---|---|
| `client_reference_id` | o pedido do seu sistema (checkouts, pedidos, pagamentos; as assinaturas não guardam) |
| `status` | situação; nos pedidos só existe `succeeded` |
| `customer_id`, `external_customer_id` | o cliente (um id que não existe não acha nada) |
| `subscription_id` | as vendas de uma assinatura: o primeiro ciclo e cada renovação (pedidos e pagamentos; SDK 0.5.6+) |
| `created_after`, `created_before` | período em RFC 3339, entre 1970 e 9999; o primeiro inclusive e o segundo não |
| `sorting` | `created_at` ou `amount` (onde há valor); um `-` na frente inverte. O padrão é `-created_at`, o mais novo primeiro |
| `metadata[chave]=valor` | os pares que você guardou, até 10; a linha precisa ter todos (SDK 0.5.5+) |
| `page`, `limit` | paginação (veja `erros-e-cuidados.md`) |

Um filtro que a lista não aceita é recusado com 422, nunca ignorado em silêncio.

```go
page, err := client.Orders.List(ctx, &perata.OrdersListParams{ClientReferenceID: "pedido-123"})
```

```ts
const page = await perata.orders.list({ client_reference_id: "pedido-123" });
```

```python
page = perata.orders.list(client_reference_id="pedido-123")
```

### Conferência diária (pegar um aviso que não chegou)

Um webhook pode falhar. Uma vez por dia, liste os pedidos do dia anterior e compare cada `client_reference_id` com os pedidos pagos do seu sistema; o que a Peráta marca como pago e o seu sistema não, você paga a pendência.

```go
since := time.Now().Add(-24 * time.Hour).UTC().Format(time.RFC3339)
for order, err := range client.Orders.ListIter(ctx, &perata.OrdersListParams{CreatedAfter: since}) {
	if err != nil {
		return err
	}
	// confira order.ClientReferenceID contra o pedido local; trate o que faltar como um order.paid
}
```

## Reembolsos

`POST /api/v1/refunds` (escopo `refunds:write`) devolve dinheiro de um pagamento.

| Campo | Regra |
|---|---|
| `payment_id` ou `order_id` | nomeie um dos dois (ou os dois, se forem do mesmo pagamento). `order_id` é o id do pedido, o mesmo de `GET /orders/{id}` |
| `amount_cents` | quanto devolver, de 1 até o que ainda pode ser devolvido. **Sem ele, devolve tudo o que ainda pode ser devolvido.** Com ele, uma parte (reembolso parcial). No cartão pode-se fazer vários, um depois do outro, até zerar: a soma nunca passa do valor capturado (acima do que resta, 409) e um novo pedido só entra quando o anterior terminou (se ele ainda está em andamento, 409: espere e repita). No Pix, um pagamento aceita um só reembolso |
| `reason` | `requested_by_customer` (padrão), `duplicate`, `fraudulent`, `product_unavailable`, `service_disruption` ou `other`; com `other` a `note` é obrigatória |
| `note` | observação sua, até 500 caracteres |
| `metadata` | seus pares, guardados no reembolso; voltam como `refund_metadata` |

- A **`Idempotency-Key` é obrigatória**: sem ela repetir a chamada depois de um tempo esgotado devolveria duas vezes. Passe a **sua**, uma por reembolso desejado (`estorno-pedido-123-1`): o SDK manda uma chave aleatória se você não passar, o que cumpre a regra mas não protege de uma repetição. A mesma chave devolve o mesmo reembolso.
- Resposta 201 com o reembolso: `id`, `payment_id`, `order_id`, `amount_cents`, `status` (`requested`, `pending`, `unknown`, `succeeded`, `failed`, `canceled`), `reason`, `client_reference_id`, `metadata` (**o do pedido**) e `refund_metadata` (**o do reembolso**). `requested` e `pending` esperam a confirmação; `succeeded` devolveu o dinheiro; `unknown` é passageiro: a confirmação não chegou ou ainda não prova a devolução. O valor continua reservado e a Peráta consulta sozinha (a primeira vez em uns 5 minutos) até o reembolso virar `succeeded` ou `failed`. Não peça de novo: espere o webhook `refund.succeeded` ou `refund.failed`, ou leia `GET /api/v1/refunds/{id}`.
- `GET /api/v1/refunds/{id}` lê um reembolso (SDK 0.5.6+); `GET /api/v1/refunds` lista, com `payment_id`, `status`, cliente, período e `metadata[chave]=valor` (os pares do reembolso). Escopo `refunds:read`.
- Em SDK anterior à 0.5.6, `payment_id`, `amount_cents` e `reason` são obrigatórios e não existe `order_id` nem `metadata`: ache o `payment_id` com `GET /payments?client_reference_id=...`.

```go
refund, err := client.Refunds.Create(ctx, perata.RefundsCreateParams{
	OrderID:     ptr(orderID),
	AmountCents: ptr(int64(4700)), // omita para devolver tudo
	Reason:      ptr("requested_by_customer"),
	Metadata:    map[string]any{"ticket": "T-881"},
}, perata.WithIdempotencyKey("estorno-pedido-123-1"))
```

```ts
const refund = await perata.refunds.create(
  { order_id: orderId, amount_cents: 4700, reason: "requested_by_customer", metadata: { ticket: "T-881" } },
  { idempotencyKey: "estorno-pedido-123-1" },
);
```

```python
refund = perata.refunds.create(
    {"order_id": order_id, "amount_cents": 4700, "reason": "requested_by_customer", "metadata": {"ticket": "T-881"}},
    idempotency_key="estorno-pedido-123-1",
)
```

### O que acontece depois do pedido de reembolso

- O estorno **conclui sozinho**. Erro temporário é reenviado de hora em hora por até 72 horas; um estorno aceito e ainda pendente é consultado em intervalos curtos; recusa definitiva, ou 72 horas sem aceite, vira `refund.failed` com `failure_reason` e `failure_code`. Ninguém precisa clicar em nada. Caso real: o estorno de um Pix foi recusado com o código 37 (o split ainda não estava liberado), a Peráta o reenviou sozinha de hora em hora e ele foi aceito horas depois, sem ninguém clicar em nada.
- Os avisos: `refund.requested`, depois `refund.succeeded` (ou `refund.failed`/`refund.canceled`), `checkout_payment.refunded` ou `checkout_payment.partially_refunded`, e `order.refunded`.
- `order.refunded` sai **uma vez por estorno concluído**, parcial ou total, sempre com `refund_id`, `refund_amount_cents` (só deste estorno), `refunded_amount_cents` (o acumulado) e `order_status`. Use o **`refund_id` como chave** para devolver créditos ou dar baixa uma única vez; some o `refund_amount_cents` deste estorno, não o acumulado. Exceção: uma devolução feita fora da plataforma, sem estorno da Peráta, vem com `refund_id` nulo.
- Em `refund.created` e `refund.updated`, `metadata` é o do pedido e `refund_metadata` é o do reembolso.

## Disputas: chargeback e MED

Uma disputa é o comprador contestando um pagamento. Chargeback é a contestação de um **cartão** na bandeira; **MED** (Mecanismo Especial de Devolução) é a devolução que o banco do pagador pede num **Pix**. O campo `kind` diz qual (`chargeback` ou `med`).

- `GET /api/v1/disputes` (filtro `status`: `opened`, `needs_evidence`, `submitted`, `under_review`, `won`, `lost`, `closed`) e `GET /api/v1/disputes/{id}`, escopo `disputes:read`. A API só **lê** disputas; a defesa, com a prova até o prazo `due_by`, é tratada no painel da Peráta (tela Disputas).
- Campos que ligam a disputa ao seu pedido: `order_id` e `checkout_id` (o mesmo valor), `client_reference_id`, `metadata`, `external_customer_id`, `subscription_id`, mais `payment_method` (`card` ou `pix`), `amount_cents`, `reason`, `provider_reason`, `source`, `opened_at`, `due_by`, `decided_at`.
- `dispute.opened` sai primeiro, uma vez por disputa: **pare de entregar o serviço a esse cliente** e envie a defesa até `due_by`.
- `dispute.won`: a decisão foi a seu favor e o valor contestado fica com você. Só chega quando a equipe da Peráta registra o resultado, porque o resultado da defesa não chega por aviso.
- `dispute.lost`: perdida, e o valor contestado mais a taxa são descontados. Sai sozinho quando o prazo da defesa acaba sem defesa.
- Numa disputa de uma venda de assinatura, a assinatura é suspensa na hora (`suspension_reason: dispute`) e sai `subscription.suspended` logo depois de `dispute.opened`. Mesmo ganhando, ela **não volta sozinha**: reative com `POST /subscriptions/{id}/resume` se quiser, ou cancele.

## Saldo e repasses: quanto e quando a organização recebe

Um **repasse** é o que a organização recebe num dia na conta de recebimento: a soma das vendas pagas naquela data, menos as tarifas, os reembolsos e as contestações que o dia compensa. O id é `po_` e a data (`po_20261120`); só há um por dia, em cada ambiente.

| Ação | Rota | Escopo |
|---|---|---|
| Saldo a receber | `GET /api/v1/balance` | `payouts:read` |
| Listar repasses | `GET /api/v1/payouts` | `payouts:read` |
| Ler um repasse, com os lançamentos | `GET /api/v1/payouts/{id}` | `payouts:read` |

No SDK são `balance.get`, `payouts.list` (e `payouts.list_iter`) e `payouts.get`, a partir da 0.5.9; numa versão anterior, chame a API REST com a mesma chave e leia o JSON da resposta. A chave que já existe não ganha o escopo `payouts:read` sozinha; crie outra marcando-o.

**Saldo** (`GET /balance`, filtros `date_from` e `date_to`, `AAAA-MM-DD`):

| Campo | O que é |
|---|---|
| `total_to_receive_cents` | tudo o que ainda vai ser recebido das vendas capturadas, já sem tarifas e reembolsos; é sempre `released_cents + held_cents + scheduled_cents + later_cents` |
| `released_cents` | liberado: a data do repasse chegou e o depósito está em processamento |
| `held_cents` | retido enquanto a conta da organização está em análise; volta a ser liberado quando a análise termina |
| `scheduled_cents` | previsto, com data nos próximos 31 dias |
| `later_cents` | sem data ainda, como as parcelas além dos próximos 31 dias |
| `deposited_cents` | depositado no período de `period_from` a `period_to` (sem `date_from`, os 30 dias até `date_to`; sem `date_to`, hoje); não entra no total |
| `period_from`, `period_to`, `currency` | o período de `deposited_cents` e `BRL` |

**Repasse** (`GET /payouts`, filtros `status`, `date_from`, `date_to` e `sorting`, `date` ou `-date`, o padrão): `id`, `status`, `expected_on` (a data do repasse), `deposited_on` (nulo enquanto não foi depositado), `amount_cents` (as vendas do dia antes das tarifas, já com os reembolsos e contestações que o dia compensa), `fee_cents`, `net_cents` (`amount_cents` menos `fee_cents`, o que é depositado; pode ser negativo quando os reembolsos superam as vendas, e então o saldo é compensado nos próximos repasses), `currency` e `item_count`. O `status` é `scheduled` (previsto), `released` (liberado, em processamento), `held` (retido para análise) ou `deposited` (depositado). `deposited` quer dizer que a data do repasse passou e a Peráta o registrou: para ter certeza do crédito, confira o extrato do banco.

`GET /payouts/{id}` traz os mesmos campos mais `items`, os lançamentos do dia: `kind` (`sale`, `refund`, `chargeback`, `fee`, `adjustment` ou `anticipation`), `payment_id` (o id de `GET /payments/{id}`; nulo numa tarifa ou ajuste que não é de um pagamento), `installment` (a parcela que o lançamento paga; 0 numa venda à vista), `status`, `amount_cents` (negativo em reembolso e contestação), `fee_cents` e `net_cents`. Um repasse com lançamentos em estados diferentes está no menos avançado deles.

Os valores são centavos inteiros. Uma data fora do formato, ou um `date_to` antes de `date_from`, volta 422 com a frase em `fields`; um id que não é de nenhum dia com repasse volta 404.

**Avisos** (webhooks `payout.scheduled`, `payout.released`, `payout.held` e `payout.deposited`): saem a cada vez que o repasse de um dia muda de estado, com o `data` só de identificadores; o `aggregate_id` é o id do repasse, e o valor se lê em `GET /payouts/{id}`. A primeira leitura de uma organização não avisa o passado. Para conciliar o seu financeiro, use o aviso para saber que mudou e a leitura do repasse para saber quanto.
