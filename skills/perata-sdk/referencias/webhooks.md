# Webhooks

Um webhook é um aviso que a Peráta manda ao seu servidor, por um POST assinado, a cada coisa que acontece (venda paga, reembolso, assinatura, disputa). É por ele que o seu sistema sabe que um pedido foi pago: **o pagamento só vale pelo aviso `order.paid`, não pela volta do comprador à `success_url`.**

## Como a entrega funciona

- A Peráta faz um POST em JSON no endereço do endpoint, com os cabeçalhos `webhook-id`, `webhook-timestamp` e `webhook-signature` (padrão Standard Webhooks).
- Responda **2xx** para dar o aviso por recebido. Qualquer outra resposta (ou demora) é repetida em **30 s, 5 min, 30 min, 2 h, 5 h e 10 h**. Cada tentativa tem 10 segundos para responder. O mesmo aviso chega sempre com o mesmo `webhook-id`.
- Se 20 avisos seguidos esgotam todas as tentativas, o endpoint é desligado (`status: disabled`). Corrija o servidor e religue com `PATCH /api/v1/webhooks/endpoints/{id}` com `enabled: true`.
- O corpo assinado tem no máximo 64 KiB. Cada showcase tem no máximo 20 endpoints por ambiente.
- O contrato não promete a **ordem** dos avisos: trate `order.paid` que chega antes de `checkout.updated`, e o contrário.
- `GET /api/v1/webhooks/deliveries` (`webhooks:read`) lista as últimas 100 entregas (filtros `endpoint_id` e `status`: `pending`, `succeeded`, `exhausted`), com `attempts`, `response_status` e `last_error`. É o lugar de olhar quando um aviso "não chegou".

## Criar o endpoint

No painel: Configurações › Webhooks › Adicionar endpoint. Ou pela API: `POST /api/v1/webhooks/endpoints` (escopo `webhooks:write`).

| Campo | Regra |
|---|---|
| `url` | obrigatório; https público (endereços internos são recusados) |
| `events` | a lista de eventos que o endpoint recebe; **sem eles nenhum é enviado**. Escolha só os que usa |
| `description` | único por organização e ambiente; sem ele vale o domínio do endereço |
| `format` | `raw` (o JSON assinado, o que você quer), `discord` ou `slack` |

A resposta traz o `secret` (`whsec_...`), **só nela**: guarde-o na hora. Um endpoint é do ambiente e do showcase em que foi criado e tem o seu próprio segredo. **O endpoint de Teste e o de Produção têm segredos diferentes**; usar o do Teste em Produção é o erro mais comum (`erros-comuns.md`).

```go
endpoint, err := client.Webhooks.CreateEndpoint(ctx, perata.WebhooksCreateEndpointParams{
	URL: "https://app.exemplo/webhooks/perata",
	Events: []string{
		"order.paid", "order.refunded", "checkout.expired",
		"refund.succeeded", "refund.failed",
		"dispute.opened", "dispute.won", "dispute.lost",
	},
}, perata.WithIdempotencyKey("webhook-endpoint-producao-1"))
// endpoint.Secret: whsec_... (só agora)
```

## O envelope

Todo aviso tem a mesma forma:

```json
{
  "id": "...",
  "type": "order.paid",
  "timestamp": "2026-12-01T13:05:41Z",
  "environment": "live",
  "showcase_id": "...",
  "data": { "id": "...", "amount_cents": 50508, "status": "succeeded", "order_status": "paid",
            "client_reference_id": "pedido-123", "items": [], "metadata": {}, "paid_at": "..." }
}
```

- `id`: o mesmo do cabeçalho `webhook-id`.
- `type`: o evento.
- `timestamp`: quando aconteceu (RFC 3339).
- `environment`: `test` ou `live`, dentro do corpo assinado.
- `showcase_id`: o showcase da venda.
- `data`: o objeto do evento, que varia por família (abaixo).

## Verificar a assinatura

Sem verificar, qualquer pessoa que descobrir a URL poderia fingir um pagamento. Os SDKs verificam em uma chamada; passe sempre o **corpo cru** (os bytes exatos que chegaram, antes de ler o JSON). A conferência é: HMAC-SHA256 de `"{webhook-id}.{webhook-timestamp}.{corpo}"` com a chave que o `whsec_` guarda em base64; uma das assinaturas do cabeçalho `webhook-signature` (`v1,<base64>`, separadas por espaço) tem de bater; o `webhook-timestamp` não pode estar a mais de **5 minutos** de agora. Durante a rotação de um segredo o cabeçalho traz duas assinaturas e basta uma conferir.

Em cada linguagem (todas devolvem o evento tipado, ou falham):

```go
// Go
event, err := perata.VerifyWebhook(os.Getenv("PERATA_WEBHOOK_SECRET"), r.Header, body)
```
```ts
// TypeScript
const event = await verifyWebhook(process.env.PERATA_WEBHOOK_SECRET!, request.headers, await request.text());
```
```python
# Python
event = verify_webhook(os.environ["PERATA_WEBHOOK_SECRET"], request.headers, request.get_data())
```
```php
// PHP
$event = Perata\Webhook::verify(getenv('PERATA_WEBHOOK_SECRET'), getallheaders(), file_get_contents('php://input'));
```
```ruby
# Ruby
event = Perata.verify_webhook(ENV.fetch("PERATA_WEBHOOK_SECRET"), request.headers, request.raw_post)
```
```java
// Java
WebhookEvent event = Webhook.verify(System.getenv("PERATA_WEBHOOK_SECRET"), headers, body);
```
```csharp
// C#
var body = await new StreamReader(Request.Body).ReadToEndAsync();
var webhook = Webhook.Verify(Environment.GetEnvironmentVariable("PERATA_WEBHOOK_SECRET")!, Request.Headers, body);
```
```elixir
# Elixir
{:ok, event} = Perata.verify_webhook(System.fetch_env!("PERATA_WEBHOOK_SECRET"), conn.req_headers, raw_body)
```
```dart
// Dart
final event = verifyWebhook(Platform.environment['PERATA_WEBHOOK_SECRET']!, request.headers, await request.readAsString());
```
```rust
// Rust
let event = perata::verify_webhook(&std::env::var("PERATA_WEBHOOK_SECRET")?, &headers, &body)?;
```
```swift
// Swift
let event = try verifyWebhook(secret: ProcessInfo.processInfo.environment["PERATA_WEBHOOK_SECRET"]!, headers: headers, body: body)
```

Sem SDK (TypeScript sem o pacote do npm, C#), a verificação à mão está em `linguagens.md`.

Ler o corpo cru em frameworks: em Express use `express.raw({ type: "application/json" })` nesta rota (não `express.json()`); em Flask, `request.get_data()`; em Rails, `request.raw_post`; em Laravel, `$request->getContent()`; em Go, `io.ReadAll(r.Body)`. Se o framework já tiver lido e reescrito o JSON, a assinatura não bate.

## O manipulador completo

O padrão que não perde nem repete um pagamento: **verificar, checar o ambiente, gravar o aviso cru com chave única no `webhook-id`, responder 2xx e processar em segundo plano.**

Go:

```go
func webhook(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 1<<20))
	if err != nil {
		http.Error(w, "corpo ilegível", http.StatusBadRequest)
		return
	}
	event, err := perata.VerifyWebhook(os.Getenv("PERATA_WEBHOOK_SECRET"), r.Header, body)
	if err != nil {
		http.Error(w, "assinatura inválida", http.StatusBadRequest)
		return
	}
	if event.Message().Environment != "live" { // endpoint de Produção; no de Teste, "test"
		http.Error(w, "ambiente errado", http.StatusBadRequest)
		return
	}
	// Grave o corpo cru com UNIQUE no webhook-id. Repetido: já gravado, só responda 200.
	novo, err := store.SaveOnce(r.Context(), r.Header.Get("webhook-id"), body)
	if err != nil {
		http.Error(w, "erro ao gravar", http.StatusInternalServerError) // a Peráta repete
		return
	}
	if novo {
		jobs.Enqueue(r.Header.Get("webhook-id")) // o job lê o corpo gravado e age
	}
	w.WriteHeader(http.StatusOK)
}
```

O job lê o corpo gravado. A assinatura já foi conferida no manipulador (e o carimbo de tempo só vale por 5 minutos), então o job não verifica de novo: ele lê o JSON nos tipos do SDK e age pelo `type`:

```go
var msg perata.WebhookMessage
if err := json.Unmarshal(raw, &msg); err != nil {
	return err
}
switch msg.Type {
case "order.paid":
	var e perata.OrderWebhookEvent
	if err := json.Unmarshal(raw, &e); err != nil {
		return err
	}
	return pedidoPago(e.Data.ClientReferenceID, e.Data.ID, e.Data.AmountCents) // idempotente
case "order.refunded":
	var e perata.OrderWebhookEvent
	if err := json.Unmarshal(raw, &e); err != nil {
		return err
	}
	if e.Data.RefundID != nil && e.Data.RefundAmountCents != nil { // nulo só se foi feito fora da plataforma
		return estornar(e.Data.ClientReferenceID, *e.Data.RefundID, *e.Data.RefundAmountCents) // chave: refund_id
	}
case "checkout.expired":
	// anote no pedido que a cobrança foi encerrada
}
return nil // um tipo que você não trata: ignore
```

TypeScript (Express):

```ts
app.post("/webhooks/perata", express.raw({ type: "application/json" }), async (req, res) => {
  const corpo: Buffer = req.body; // os bytes crus, graças ao express.raw
  let event;
  try {
    event = await verifyWebhook(process.env.PERATA_WEBHOOK_SECRET!, req.headers, corpo);
  } catch {
    return res.status(400).send("assinatura inválida");
  }
  if (event.environment !== "live") return res.status(400).send("ambiente errado");
  const novo = await guardarUmaVez(String(req.header("webhook-id")), corpo.toString("utf8")); // UNIQUE no webhook-id
  if (novo) await fila.add("perata", { id: req.header("webhook-id") });
  res.sendStatus(200);
});
```

Python (Flask):

```python
@app.post("/webhooks/perata")
def webhook():
    corpo = request.get_data()
    try:
        event = verify_webhook(os.environ["PERATA_WEBHOOK_SECRET"], request.headers, corpo)
    except WebhookVerificationError:
        return "assinatura inválida", 400
    if event.environment != "live":
        return "ambiente errado", 400
    if guardar_uma_vez(request.headers["webhook-id"], corpo):  # UNIQUE no webhook-id
        fila.enqueue(processar, request.headers["webhook-id"])
    return "", 200
```

### Idempotência: duas camadas

1. **Pelo `webhook-id`**: o mesmo aviso pode chegar mais de uma vez. Grave com chave única e só processe o que for novo.
2. **Pelo fato do negócio**: o mesmo pagamento gera mais de um aviso (`order.paid` e `checkout_payment.captured`, por exemplo). Libere o pedido pelo `client_reference_id`/id do pedido, de modo que liberar duas vezes não faça nada. Para estorno, a chave é o `refund_id`.

### Recusar o ambiente errado

Todo aviso diz `environment` (`test` ou `live`). O seu endpoint de Produção deve recusar `test` (e o de Teste, `live`) para que um teste nunca dê baixa num pedido real. Use um segredo e, de preferência, uma URL por ambiente. A Peráta só manda ao endpoint os eventos do ambiente dele; a checagem protege de uma configuração trocada.

## Os eventos, por família

O contrato lista todos os `type`s abaixo. Assine só os que usa. O `data` de cada família:

| Família | Eventos | `data` | O que fazer |
|---|---|---|---|
| Pedido | `order.created`, `order.paid`, `order.updated`, `order.refunded` | `WebhookOrder` (o pedido: `id` é o id da sessão, `amount_cents`, `items`, `metadata`, `client_reference_id`, `paid_at`, `order_status`, `refunded_amount_cents`, `refund_id`, `refund_amount_cents`, o desconto aplicado (`discount_id`, `discount_code`, `subtotal_cents`, `discount_cents`) e o ciclo se for assinatura) | `order.paid`: libere o que foi vendido. `order.refunded`: estorne, chave `refund_id` |
| Checkout | `checkout.created`, `checkout.updated`, `checkout.expired` | `WebhookCheckout` (a sessão: `id`, `status`, `amount_cents`, `total_cents`, `items`, `metadata`, `client_reference_id`, `expires_at`) | `checkout.expired`: o pedido não foi pago por aquela cobrança; anote |
| Sessão | `checkout_session.opened`, `.confirmed`, `.succeeded`, `.failed`, `.expired` | só identificadores | busque o objeto pela API se precisar |
| Pagamento | `checkout_payment.authorized`, `.captured`, `.refused`, `.canceled`, `.refunded`, `.partially_refunded` | `WebhookSale` (`checkout_id`, `amount_cents`, `method`, `client_reference_id`, `metadata`, `refunded_amount_cents`, e `refund_id`/`refund_amount_cents` nos de reembolso) | detalhe do pagamento (meio, recusa); a baixa vem de `order.paid` |
| Reembolso | `refund.requested`, `refund.succeeded`, `refund.failed`, `refund.canceled` | `WebhookSale` (`checkout_id`, `payment_id`, `refund_id`, `amount_cents`, e em `refund.failed` `failure_reason` e `failure_code`) | `refund.failed`: avise quem pediu; o dinheiro não voltou |
| Reembolso (objeto) | `refund.created`, `refund.updated` | `WebhookRefund` (`id`, `payment_id`, `order_id`, `amount_cents`, `status`; `metadata` é o do **pedido**, `refund_metadata` o do **reembolso**) | acompanhamento |
| Assinatura | `subscription.created`, `.active`, `.updated`, `.cycled`, `.past_due`, `.suspended`, `.paused`, `.resumed`, `.canceled`, `.uncanceled`, `.revoked` | `WebhookSubscription` (com `quantity`, `amount_cents` do ciclo, `client_reference_id`, `metadata` e `first_period_extra_days`; e `payment_failure` em `past_due` e `suspended`) | `assinaturas.md` |
| Disputa | `dispute.opened`, `dispute.won`, `dispute.lost` | `WebhookDispute` (com `kind`, `payment_method`, `checkout_id`, `client_reference_id`, `metadata`, `external_customer_id`, `subscription_id`) | `opened`: suspenda o serviço e defenda |
| Cliente | `customer.created`, `.updated`, `.deleted`, `.archived` | o `Customer` (`archived`: só identificadores) | espelho opcional |
| Catálogo | `product.created`, `.updated`, `.archived`, `price.created`, `.archived` | `Product` (os de preço e `archived`: só identificadores) | espelho opcional |
| Desconto | `discount.created`, `.updated`, `.deleted`, `.redeemed`, `.exhausted`, `.expired`, `.reactivated`, `discount_redemption.released` | `WebhookDiscount` ou identificadores | opcional |
| Benefício | `benefit.created`, `.updated`, `.archived`, `.version_created`, `benefit_grant.created`, `.updated`, `.revoked`, `benefit_product_link.linked`, `.unlinked` | `WebhookBenefit`, `BenefitGrant` ou identificadores | `benefit_grant.*`: dar e tirar acesso |
| Link de checkout | `checkout_link.created`, `checkout_link.archived` | só identificadores | opcional |
| Fatura | `invoice.drafted`, `.issued`, `.settled`, `.uncollectible`, `.voided` | só identificadores | opcional |
| Consumo | `usage_event.recorded`, `usage_period.opened`, `.closed`, `usage_period_adjustment.created` | só identificadores | opcional |
| Assentos | `seat_allocation.opened`, `.resized`, `seat_assignment.invited`, `.claimed`, `.revoked` | só identificadores | opcional |

Use os nomes exatamente como estão na tabela. Pagamento confirmado é `checkout_payment.captured` (o `succeeded` é só o `status` do pedido e o nome `checkout_session.succeeded`); não existe `checkout_payment.succeeded` nem `payment.succeeded`. Para liberar o que foi vendido, escute `order.paid`. A lista completa de nomes é a do contrato (`GET /documentacao/openapi.json`, seção `webhooks`); um nome fora dela não é entregue e o endpoint recusa assiná-lo.

"Só identificadores" quer dizer `data` com `event_id`, `aggregate`, `aggregate_id`, `merchant_id` (o showcase) e `environment`; use o `aggregate_id` para ler o objeto pela API.

Um bom conjunto inicial para uma loja: `order.paid`, `order.refunded`, `checkout.expired`, `refund.succeeded`, `refund.failed`, `dispute.opened`, `dispute.won`, `dispute.lost`. Para assinaturas, some `subscription.created`, `subscription.cycled`, `subscription.past_due`, `subscription.suspended`, `subscription.active` e `subscription.canceled`.

## Segredo e rotação

- O `whsec_` só aparece ao criar o endpoint. Guarde em variável de ambiente.
- Se o segredo vazar, no painel use "Redefinir segredo" no endpoint: o segredo atual **deixa de valer na hora**, então troque a variável de ambiente do servidor logo em seguida. Pela API, o `PATCH` do endpoint não muda o segredo.
- Durante uma rotação o cabeçalho `webhook-signature` pode trazer mais de uma assinatura; os SDKs já aceitam se uma delas confere.
- O SDK recusa um segredo que não seja `whsec_` mais base64.
