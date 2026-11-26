# Erros comuns

A primeira parte reúne casos que aconteceram de verdade numa integração (o alpr.sh, que cobra os pedidos dos clientes pela Peráta) entre 17 e 19 de novembro de 2026. A segunda reúne armadilhas que o contrato da API prevê e que quem integra costuma encontrar. Cada item diz o sintoma, a causa e o que fazer.

## Parte 1. Casos reais do alpr.sh

### 1. O webhook de Produção recusa os avisos com 401

- **Sintoma:** os avisos `checkout_payment.captured` e `order.paid` de pagamentos reais chegavam ao servidor, e o servidor os recusava com 401. A Peráta continuava tentando entregar.
- **Causa:** o servidor verificava a assinatura com o segredo `whsec_` do endpoint de **Teste**. Cada endpoint, em cada ambiente, tem o seu segredo; o aviso de Produção é assinado com o segredo do endpoint de Produção.
- **Correção:** abra o endpoint no ambiente **Produção**, copie o `whsec_` **dele** e ponha-o na variável de ambiente de Produção. Os avisos pendentes voltam a ser entregues enquanto houver tentativas (a escada vai até 10 horas); o que esgotou aparece em `GET /webhooks/deliveries?status=exhausted`, e a conferência diária de pedidos (`pos-venda.md`) acha o que ficou. Se 20 avisos seguidos esgotarem as tentativas, o endpoint é desligado: religue com `enabled: true`.
- **Prevenção:** um segredo por ambiente, em variáveis diferentes, e recusar o `environment` errado.

### 2. 422 ao sincronizar um cliente que já existe

- **Sintoma:** `POST /customers` com `external_id` e o e-mail de alguém que já tinha comprado respondia 422 no campo `email`, porque o checkout já criara o cliente pelo e-mail (sem `external_id`).
- **Causa:** o e-mail é único por organização.
- **Correção:** a Peráta passou a **ligar** o `external_id` a esse cliente, atualizar os dados enviados e responder **200** (cliente novo continua 201). Trate 200 e 201 como sucesso e repita a sincronização normal. Continua 422 se o e-mail é de um cliente com **outro** `external_id`: aí o seu sistema decide qual é o cliente certo (`GET /customers?email=...`). Os próximos checkouts com `external_customer_id` abrem com o CPF preenchido e sem pedir código.
- **Prevenção:** sincronize o cliente antes do primeiro checkout (`clientes.md`).

### 3. 403 com a chave sem escopo

- **Sintoma:** criar ou administrar uma assinatura respondia 403 `forbidden`, com a mesma chave funcionando para o resto.
- **Causa:** a chave não tinha os escopos da rota. Para assinaturas: `products:read`, `subscriptions:read` e `subscriptions:write` (e `checkouts:write` para criar o checkout).
- **Correção:** o 403 diz qual escopo falta e onde marcar (Configurações › Tokens de acesso). Crie uma chave nova marcando as permissões e troque no servidor.
- **Prevenção:** ao pedir a chave ao dono, entregue a lista de escopos de `conceitos.md`.

### 4. O estorno de um Pix foi recusado (código 37)

- **Sintoma:** um reembolso de Pix não concluía; ele era recusado com o código 37 (o split ainda não estava liberado).
- **Causa:** o dinheiro do Pix ainda não tinha sido liberado para a devolução; é uma recusa temporária.
- **Correção:** nenhuma. A Peráta reenviou o estorno de hora em hora e ele foi aceito horas depois; saíram `order.refunded`, `checkout_payment.refunded` e `refund.succeeded`, e o servidor respondeu 200. **Todo estorno conclui sozinho**: erro temporário é reenviado por até 72 horas; só uma recusa definitiva, ou 72 horas sem aceite, vira `refund.failed` com `failure_reason` e `failure_code`.
- **Do lado do seu sistema:** confira que os créditos foram tirados **uma vez** (chave `refund_id`) e não tente "forçar" o estorno de novo.

### 5. Um Pix pago que o sistema só viu horas depois

- **Sintoma:** o cliente pagou o Pix e o aviso demorou.
- **Causa:** o aviso do pagamento chegou, mas ficou parado atrás de avisos antigos da fila do sandbox. Foi corrigido na Peráta.
- **Lição:** o webhook é o caminho principal, e a **conferência diária** (`GET /orders?created_after=...`) é a rede de segurança. Mantenha as duas.

### 6. O tipo do evento `order.*` mudou

- **Sintoma:** erro de tipo em `order.*` depois de atualizar o SDK.
- **Causa:** a partir da 0.5.3, o dado dos eventos `order.*` é `WebhookOrder` (o pedido mais os campos do estorno), não `Order`.
- **Correção:** troque o tipo onde o código espera `Order`.

### 7. Filtro por `metadata` que o SDK não tem

- **Sintoma:** não existe `Metadata` nos parâmetros da lista, mas a assinatura de uma câmera precisa ser achada pelo `camera_id`.
- **Causa:** o filtro `metadata[chave]=valor` chega ao SDK na 0.5.5; a API o aceita antes.
- **Correção:** atualize o SDK, ou chame a rota direto com `metadata[camera_id]=cam-77` na consulta (`linguagens.md`).

### 8. O nome no app do banco não é o do lojista

No app do banco, quem recebe um Pix da Peráta aparece com o nome do processador de pagamentos da Peráta, não com o do lojista (exigência do Banco Central). A tela do QR code já avisa isso; repasse a explicação ao cliente que perguntar.

## Parte 2. Armadilhas que o contrato prevê

### 9. 409 ao encerrar o checkout

`POST /checkouts/{id}/expire` devolve 409 quando o checkout já foi pago (ou emitiu boleto) enquanto o valor mudava. **Não abra outro checkout**: o pedido está pago, e o `order.paid` confirma. Só abra um novo se o `expire` respondeu 200.

### 10. O mesmo pedido cobrado duas vezes

Acontece quando o valor muda e o código abre um checkout novo sem encerrar o antigo, ou reenvia o link velho. Faça `expire` no antigo, depois `create` com `Idempotency-Key` nova, e nunca reenvie o link antigo (`checkout.md`).

### 11. Crédito devolvido duas vezes num estorno

Use o `refund_id` como chave e o `refund_amount_cents` (só deste estorno) como valor. O `refunded_amount_cents` é o acumulado do pedido: somá-lo a cada aviso soma o mesmo dinheiro de novo.

### 12. 422 por caractere invisível

422 em `client_reference_id`, nome de linha ou `metadata`, com valores que "parecem normais": tabulação, quebra de linha, ESC ou marca invisível de direção do texto (U+202E), muitas vezes de um campo copiado. Limpe antes de enviar.

### 13. Soma das linhas diferente do valor

422 em `items` ou `amount_cents` quando a soma de `quantity` vezes `unit_amount_cents` não é igual a `amount_cents`, quando `quantity` é diferente de 1 junto com `amount_cents`, quando o valor está fora do mínimo e do máximo do preço, ou quando o preço não é de valor livre. Calcule o total a partir das linhas, no código, e envie os dois do mesmo cálculo.

### 14. Repetir a criação e perder o `client_secret`

Na repetição de uma criação com a mesma chave, o `client_secret` vem vazio, e o `url` volta a ser o do link, que abre uma sessão nova a cada visita. Grave `url`, `session_id` e `status_key` e entregue o `client_secret` da **primeira** resposta; só repita a criação se não recebeu resposta nenhuma.

### 15. Confundir os ids

`GET /orders/{id}` com o `id` de `POST /checkouts` dá 404: esse `id` é o do **link**. O pedido e o `checkout_id` dos webhooks são o `session_id`. Guarde os dois e ligue pelo `client_reference_id` (`conceitos.md`).

### 16. A recusa de cartão não cancela o pedido

`checkout_payment.refused` e a recusa na tela são normais: o pedido segue em aberto até um pagamento passar. Não cancele o pedido por causa de uma recusa; se o pedido mudou, use `expire`.

### 17. Desconto recusado (422 em discount_id)

`POST /checkouts` e as assinaturas respondem **422** `invalid_request` com `fields.discount_id` quando o desconto não se aplica: o cliente já o usou o número de vezes permitido, o limite total acabou, ele terminou ou ainda não começou, não cobre os produtos do carrinho, falta a identidade do cliente para o limite por cliente, ou o código não existe. A `message` e `fields.discount_id[0]` dizem o motivo em português, prontos para mostrar.

- **O que fazer:** mostre a mensagem ao comprador. Se fizer sentido para o seu negócio, crie o checkout de novo **sem** o desconto (com `Idempotency-Key` nova): o comprador ainda pode digitar outro código na tela do checkout. Não repita a mesma chamada com o mesmo código, porque a resposta será a mesma.
- **Como ler:** todo SDK entrega `fields` como mapa de campo para lista de mensagens (`linguagens.md` traz o tipo de erro de cada linguagem). Em TypeScript e PHP o `message` do erro vem com o prefixo `perata: 422 invalid_request:`; para mostrar ao comprador, use `fields`.

```go
checkout, err := client.Checkouts.Create(ctx, params)
var apiErr *perata.Error
if errors.As(err, &apiErr) && apiErr.Code == "invalid_request" {
	if reasons := apiErr.Fields["discount_id"]; len(reasons) > 0 {
		showToBuyer(reasons[0]) // por exemplo "Este desconto já foi usado por este cliente..."
		params.DiscountID = nil // o mesmo checkout, sem o desconto
		checkout, err = client.Checkouts.Create(ctx, params, perata.WithIdempotencyKey(newKey()))
	}
}
```

```ts
try {
  return await perata.checkouts.create(params);
} catch (error) {
  if (error instanceof PerataError && error.code === "invalid_request" && error.fields["discount_id"]?.length) {
    showToBuyer(error.fields["discount_id"][0]);
    return await perata.checkouts.create({ ...params, discount_id: undefined }, { idempotencyKey: newKey() });
  }
  throw error;
}
```
