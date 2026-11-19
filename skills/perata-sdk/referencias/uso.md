# Cobrança por uso: medidores e `usage.ingest`

Para cobrar pelo que o cliente consome (tokens de uma IA, por exemplo), o seu sistema **envia eventos de consumo** e a Peráta os conta com **medidores**. Esta rota só registra o consumo; ela não cobra sozinha.

## As duas peças

- **Medidor** (`meter`): diz quais eventos contar (filtro), como somar (`aggregation.func`: `count`, `sum`, `avg`, `min`, `max` ou `unique`, com `aggregation.property` nas que leem uma propriedade) e a unidade (`unit.type`: `scalar`, `token` ou `custom`, com `label` e `multiplier`). A API só **lê** medidores: `GET /api/v1/meters` (filtro `is_archived`) e `GET /api/v1/meters/{id}`, escopo `meters:read`. Os medidores se configuram no painel (a API não os cria). Um benefício do tipo `meter_credit` (`catalogo.md`) dá créditos de um medidor ao cliente.
- **Evento de consumo**: o que o seu sistema manda. Os eventos recebidos se leem com `GET /api/v1/events` (escopo `events:read`; filtros `customer_id`, `start`, `end` em RFC 3339), do mais novo ao mais antigo.

## A credencial é outra

A ingestão **não usa a chave `prk_`**: usa a credencial de uma **fonte de ingestão** (`pus_test_...` no Teste, `pus_live_...` em Produção), criada em Configurações › Fontes de ingestão. A chave `prk_` é recusada ali com 401, e uma credencial de um ambiente nunca escreve no outro. A credencial expira em 30 dias; a rotação mantém a identidade da fonte. Em Produção a fonte só existe para a organização que a equipe da Peráta liberou. Por isso o cliente do SDK se monta com a credencial da fonte, num segundo cliente:

```go
usage := perata.New(os.Getenv("PERATA_USAGE_KEY")) // pus_test_... ou pus_live_...
```

## Enviar eventos

`POST /api/v1/usage/token-events` com `events` (de 1 a 100 por chamada, no máximo 65536 bytes; tudo ou nada). Cada evento:

| Campo | Regra |
|---|---|
| `customer_id` | o cliente da Peráta (obrigatório) |
| `external_event_id` | o id do evento no **seu** sistema (obrigatório). É a identidade do evento |
| `input_tokens`, `output_tokens`, `cached_tokens` | obrigatórios, **como texto** com inteiro decimal de 0 a 1000000000000 (`"1200"`). Pelo menos um token por evento. A entrada exclui o cache |
| `occurred_at` | RFC 3339 em segundos inteiros, de no máximo 90 dias atrás até 5 minutos à frente |
| `_cost` | opcional: `amount` (centavos, texto decimal com até seis casas, como `"0.42"`) e `currency` (`brl`), o custo de atender o evento; alimenta Análises › Custos |
| `_llm` | opcional: `vendor` e `model` (até 120 caracteres cada) |
| `parent_id` | opcional: o evento pai (id da Peráta ou o `external_event_id` da mesma fonte); o pai tem de chegar antes, inclusive antes no mesmo lote |

Resposta 200: `{"data": {"created": 1, "replayed": 0}}`.

**Não há `Idempotency-Key` aqui.** Repetir uma chamada é seguro: o mesmo `external_event_id` da mesma fonte com o mesmo conteúdo conta como `replayed`, sem consumo adicional. O mesmo id com **outro conteúdo** é 409 (`conflict`). Um evento inválido é 422 (`invalid_request`), com `record` dizendo a posição dele no lote (a partir de 1) e o lote inteiro desfeito. Também há 413 (`body_too_large`), 415 e 429.

Go:

```go
receipt, err := usage.Usage.Ingest(ctx, perata.UsageIngestParams{Events: []perata.UsageIngestEvent{{
	CustomerID:      customerID,
	ExternalEventID: "requisicao-001",
	InputTokens:     "1200",
	OutputTokens:    "300",
	CachedTokens:    "0",
	OccurredAt:      time.Now().UTC().Format(time.RFC3339), // segundos inteiros
}}})
// receipt.Created, receipt.Replayed
```

TypeScript:

```ts
const usage = new Perata({ apiKey: process.env.PERATA_USAGE_KEY! });
const receipt = await usage.usage.ingest({
  events: [{
    customer_id: customerId,
    external_event_id: "requisicao-001",
    input_tokens: "1200",
    output_tokens: "300",
    cached_tokens: "0",
    occurred_at: new Date().toISOString().replace(/\.\d{3}Z$/, "Z"),
  }],
});
```

Python:

```python
from datetime import datetime, timezone

usage = Perata(os.environ["PERATA_USAGE_KEY"])
receipt = usage.usage.ingest({"events": [{
    "customer_id": customer_id,
    "external_event_id": "requisicao-001",
    "input_tokens": "1200", "output_tokens": "300", "cached_tokens": "0",
    "occurred_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}]})
```

## Cuidados

- Mande o evento **depois** que o consumo aconteceu e grave o `external_event_id` junto com o seu registro, para repetir o mesmo id se a rede falhar.
- Agrupe em lotes de até 100 e trate o 422: um evento ruim derruba o lote, e o `record` aponta qual.
- Nunca guarde a credencial `pus_` no navegador: ela vale como senha de escrita.
