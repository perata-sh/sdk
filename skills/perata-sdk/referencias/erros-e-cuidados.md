# Erros e cuidados

## O formato do erro

Todo erro da API tem a mesma forma:

```json
{
  "error": "invalid_request",
  "message": "quantity: Envie uma quantidade de pelo menos 1, ou omita para usar 1.",
  "fields": { "quantity": ["Envie uma quantidade de pelo menos 1, ou omita para usar 1."] }
}
```

- `error`: o código, em inglês. **É o que o programa lê.**
- `message`: o motivo em português, para uma pessoa. Num 422 traz cada campo e a primeira mensagem dele.
- `fields`: o problema de cada campo (`{"campo": ["motivo"]}`). Só aparece quando há campo.
- Um 401 ou 404 pode vir só com `error`.
- Na ingestão de consumo vem também `record`, a posição do evento recusado.
- No SDK, a recusa vira o erro tipado da linguagem (tabela em `linguagens.md`), com `status`, `code`, `message`, `fields` e `retry_after`; o texto do erro já mostra o motivo (`perata: 422 invalid_request: customer_email: ...`).

| `error` | Status | Quando | O que fazer |
|---|---|---|---|
| `invalid_credential` | 401 | chave ausente, errada ou de outro ambiente | confira `Authorization: Bearer` e o prefixo `prk_test_`/`prk_live_` |
| `forbidden` | 403 | a chave não tem o escopo da rota | a `message` diz qual escopo falta e onde marcar; crie outra chave (`conceitos.md`) |
| `not_found` | 404 | o recurso não existe neste ambiente e showcase | confira o id e o ambiente da chave |
| `method_not_allowed` | 405 | método errado na rota | veja o cabeçalho `Allow` |
| `conflict` | 409 | o estado não permite a ação (checkout já pago, cartão em uso, assinatura que não está suspensa) | leia o contexto da rota |
| `idempotency_conflict` | 409 | a `Idempotency-Key` já foi usada em outra requisição (outro corpo ou outra rota) | use outra chave para o novo pedido |
| `idempotency_in_progress` | 409 | uma requisição com esta chave ainda está em andamento | espere o `Retry-After` (1 s) e repita |
| `invalid_idempotency_key` | 400 | `Idempotency-Key` ausente onde é obrigatória (reembolso), com mais de 255 caracteres ou com caractere fora do ASCII (acento, emoji) | corrija a chave |
| `unsupported_media_type` | 415 | o corpo não é `application/json` | envie `Content-Type: application/json` |
| `invalid_request` | 422 | campo inválido ou desconhecido, filtro que a lista não aceita | corrija o que `fields` aponta |
| `body_too_large` | 413 | corpo grande demais (na ingestão, mais de 65536 bytes) | divida em lotes |
| `rate_limited` | 429 | muitas requisições | espere o `Retry-After` |
| `unavailable` | 500 | falha do lado da Peráta | repita com a mesma `Idempotency-Key` |

## Idempotency-Key

Serve para repetir uma escrita sem fazê-la duas vezes (um tempo esgotado na rede, por exemplo).

- Vai no cabeçalho `Idempotency-Key`, até 255 caracteres ASCII (sem acento), em qualquer escrita. **O reembolso a exige.**
- A mesma chave com o **mesmo corpo** (e a mesma rota) repete a resposta original, com o cabeçalho `Idempotent-Replayed: true`.
- A mesma chave com **outro corpo**, ou em outra rota, dá 409 `idempotency_conflict`.
- Uma resposta **2xx** fica guardada sob a chave. Uma recusa **4xx** ou uma falha **5xx** a **libera**: repita com a mesma chave, com o corpo corrigido ou como estava. (Até 18/11/2026 uma recusa prendia a chave; hoje não.)
- Um segredo que a resposta mostra uma vez (o `client_secret` do checkout, o `secret` do endpoint de webhook) **não é guardado**: na repetição ele vem vazio.
- Componha a chave com o fato do negócio, não com um sorteio: `pedido-123-50508-2026-12-01` (pedido, valor, dia); `estorno-pedido-123-1`. Uma chave por intenção.
- Os SDKs mandam sozinhos uma chave aleatória (UUID v4) em todo POST que não leva a sua. Isso serve para a regra do reembolso, mas **não protege uma repetição**: cada tentativa leva uma chave nova. Em toda escrita que mexe com dinheiro, passe a sua. Um `PATCH` e um `DELETE` não recebem chave automática.
- A ingestão de consumo não usa `Idempotency-Key`: o evento se identifica pelo `external_event_id` (`uso.md`).

## O que repetir e o que não

| Situação | Repetir? |
|---|---|
| Rede caiu, tempo esgotado, 5xx | sim, com a **mesma** chave, devagar (espera crescente) |
| 429 | sim, depois do `Retry-After` |
| 409 `idempotency_in_progress` | sim, depois de 1 s |
| Outro 4xx (401, 403, 404, 409, 422) | não: o pedido está errado; corrija e envie de novo |

Nenhum SDK repete sozinho. Exemplo em Go:

```go
func comRepeticao(ctx context.Context, fn func() error) error {
	var err error
	for tentativa := 0; tentativa < 5; tentativa++ {
		if err = fn(); err == nil {
			return nil // fn usa a MESMA Idempotency-Key em toda chamada
		}
		var apiErr *perata.Error
		isAPI := errors.As(err, &apiErr)
		var espera time.Duration
		switch {
		case isAPI && apiErr.StatusCode == http.StatusTooManyRequests:
			espera = apiErr.RetryAfter
		case isAPI && apiErr.Code == "idempotency_in_progress":
			espera = time.Second
		case !isAPI || apiErr.StatusCode >= 500: // rede ou falha da Peráta
			espera = time.Duration(1<<tentativa) * time.Second
		default:
			return err // 4xx: corrija o pedido
		}
		select {
		case <-time.After(espera):
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	return err
}
```

## Listas, filtros e paginação

- Toda lista aceita `page` (de 1 a 1000000; além da última vem vazia) e `limit` (de 1 a 100; 10 por padrão). A resposta é `{"data": {"items": [...], "pagination": {"total_count", "max_page"}}}`.
- Cada SDK tem um iterador que percorre todas as páginas com o filtro (`ListIter`, `listIter`, `list_iter`... em `linguagens.md`): prefira-o a escrever o laço de páginas.
- Filtros comuns: `client_reference_id`, `status`, `customer_id`, `external_customer_id`, `created_after` e `created_before` (RFC 3339), `sorting` (`created_at`, e `amount` onde há valor; `-` na frente inverte; o padrão é `-created_at`), `metadata[chave]=valor` (até 10 pares). Quais filtros cada lista aceita está em `pos-venda.md`.
- **Um filtro que a lista não aceita volta 422**, não é ignorado: o filtro de `subscription_id`, por exemplo, só existe em pedidos e pagamentos.
- `status` tem valores diferentes por lista: checkouts `active`/`archived`; pedidos só `succeeded`; pagamentos `unknown`, `pending`, `authorized`, `captured`, `refused`, `canceled`, `refunded`, `partially_refunded`; reembolsos `requested`, `pending`, `unknown`, `succeeded`, `failed`, `canceled`; assinaturas `trialing`, `active`, `past_due`, `suspended`, `paused`, `canceled`; disputas `opened`, `needs_evidence`, `submitted`, `under_review`, `won`, `lost`, `closed`.
- Os valores de filtro de data precisam de fuso (`2026-11-17T00:00:00-03:00`).

## 429 e Retry-After

Um 429 traz o cabeçalho `Retry-After`, em segundos: espere esse tempo antes de tentar de novo, sem martelar. No SDK ele vem pronto (`RetryAfter` em Go, `retryAfter` em TypeScript, `retry_after` em Python). Para ler muitos registros, use o iterador com `limit` 100 e uma pausa curta entre páginas em vez de várias consultas em paralelo.

## Validações que costumam pegar quem integra

- `client_reference_id` (até 255), `label`, nome de linha (até 200) e `metadata`: sem tabulação, quebra de linha, ESC nem marcas invisíveis de direção do texto (U+202E). Limpe antes de enviar.
- `metadata`: até 50 pares; chave de 1 a 40 caracteres; valor texto de 1 a 500 caracteres, número ou booleano.
- `amount_cents` só num preço de valor livre; a soma das linhas tem de igualar o valor (`checkout.md`).
- `external_id` do cliente: até 120 caracteres, sem `/`, e só pode ser definido uma vez.
- Datas de `created_after`/`created_before` entre os anos 1970 e 9999.
- Corpo com campo que o contrato não tem é recusado: não envie campos "por precaução".
- Sempre `Content-Type: application/json` nas escritas (a ingestão também).

## Segurança que não se negocia

- A chave `prk_` e a credencial `pus_` só no servidor; nunca em app, no navegador, em log ou no repositório.
- Valor e desconto sempre calculados no servidor.
- Webhook sempre com assinatura verificada sobre o corpo cru.
- Ao navegador, só o `url` ou o `client_secret`.
- O número do cartão nunca passa pelo seu servidor: use os campos seguros da Peráta (`checkout.md`).
