# Checkout: cobrar um pedido

Uma venda tem duas metades. O **servidor** cria o checkout com a chave de API. O **comprador** paga numa tela: a página da Peráta, uma janela (modal) sobre o seu site, campos prontos dentro do seu site, ou o seu próprio formulário com só os campos do cartão num quadro seguro da Peráta. O número do cartão nunca passa pelo seu site nem pelo seu servidor.

## 1. Criar o checkout (servidor)

`POST /api/v1/checkouts` (escopo `checkouts:write`; SDK: `checkouts.create`). Corpo:

| Campo | Regra |
|---|---|
| `product_id`, `price_id` | obrigatórios |
| `amount_cents` | o valor do pedido todo, em centavos, que o seu servidor fixa. Só vale em preço de **valor livre**; em outro preço é 422. Respeita o mínimo e o máximo do preço (422 fora). Máximo de 999999999999 |
| `items` | as linhas do pedido, até 50: `name` (até 200 caracteres), `quantity` (1 se omitida), `unit_amount_cents`. Veja a seção 3 |
| `quantity` | com `amount_cents` é sempre 1: envie 1 ou omita; outro valor é 422 |
| `client_reference_id` | o id do pedido no seu sistema, até 255 caracteres |
| `metadata` | até 50 pares guardados e devolvidos em tudo da venda |
| `customer_id`, `external_customer_id`, ou `customer_email` com `customer_name` | quem compra. `customer_id` não vai junto com `external_customer_id`, `customer_email` nem `customer_name` |
| `success_url`, `cancel_url` | endereços https para onde o comprador volta depois de pagar ou se desistir. `return_url` é outro nome de `cancel_url` |
| `expires_in` | segundos de validade da sessão e do `client_secret`, de 60 a 259200 (72 h); 1800 (30 min) se omitido |
| `allow_discount_codes` | deixa o comprador digitar um código de desconto; desligado se omitido |
| `require_billing_address` | pede o endereço completo de todo comprador, não só no boleto; desligado se omitido |
| `discount_id` | aplica um desconto do catálogo sozinho (SDK 0.5.6+) |
| `subscription_start_at` | só em assinatura: dia da primeira cobrança (SDK 0.5.6+). Veja `assinaturas.md` |
| `first_period_extra_days` | só em assinatura: de 1 a 365 dias somados ao primeiro período; cobra hoje o valor cheio. Não vale com `subscription_start_at`. Veja `assinaturas.md` (ainda não está nos SDKs: use a API REST) |
| `label` | nome que você dá ao checkout nas suas telas; o comprador não vê |

A resposta é 201 com `data`:

| Campo | Para que serve |
|---|---|
| `id` | o link do checkout: `GET`/`PATCH /checkouts/{id}` e `expire` |
| `session_id` | a sessão aberta para o comprador (é o `checkout_id` dos webhooks e o id do pedido) |
| `url` | o endereço da página de pagamento daquela sessão. Mande o comprador para cá |
| `client_secret`, `client_secret_expires_at` | a credencial do navegador, **só nesta resposta** |
| `status_key` | acompanhar a sessão depois que o `client_secret` é gasto |
| `amount_cents`, `items`, `metadata`, `client_reference_id`, `expires_at`, `subscription_start_at`, `discount_id`, `first_period_extra_days` | o que você mandou, devolvido |

**Guarde `id`, `session_id` e `status_key` no seu pedido logo.** O `client_secret` só serve ao navegador e não precisa ser guardado.

Go:

```go
checkout, err := client.Checkouts.Create(ctx, perata.CheckoutsCreateParams{
	ProductID:   productID,
	PriceID:     priceID, // preço de valor livre
	AmountCents: ptr(int64(50508)),
	Items: []perata.CheckoutsCreateItem{
		{Name: "Câmera Portaria, 01/12 a 31/12", UnitAmountCents: 49000},
		{Name: "Multa e juros do dia", UnitAmountCents: 1508},
	},
	ClientReferenceID:  ptr("pedido-123"),
	Metadata:           map[string]any{"organizacao": "org-9", "usuario": "u-42"},
	ExternalCustomerID: ptr("cliente-123"),
	SuccessURL:         ptr("https://loja.exemplo/obrigado"),
	CancelURL:          ptr("https://loja.exemplo/pedido/123"),
	ExpiresIn:          ptr(int64(259200)),
}, perata.WithIdempotencyKey("pedido-123-50508-2026-12-01"))
```

TypeScript:

```ts
const checkout = await perata.checkouts.create(
  {
    product_id: productId,
    price_id: priceId,
    amount_cents: 50508,
    items: [
      { name: "Câmera Portaria, 01/12 a 31/12", unit_amount_cents: 49000 },
      { name: "Multa e juros do dia", unit_amount_cents: 1508 },
    ],
    client_reference_id: "pedido-123",
    metadata: { organizacao: "org-9", usuario: "u-42" },
    external_customer_id: "cliente-123",
    success_url: "https://loja.exemplo/obrigado",
    cancel_url: "https://loja.exemplo/pedido/123",
    expires_in: 259200,
  },
  { idempotencyKey: "pedido-123-50508-2026-12-01" },
);
```

Python:

```python
checkout = perata.checkouts.create({
    "product_id": product_id, "price_id": price_id, "amount_cents": 50508,
    "items": [
        {"name": "Câmera Portaria, 01/12 a 31/12", "unit_amount_cents": 49000},
        {"name": "Multa e juros do dia", "unit_amount_cents": 1508},
    ],
    "client_reference_id": "pedido-123",
    "metadata": {"organizacao": "org-9", "usuario": "u-42"},
    "external_customer_id": "cliente-123",
    "success_url": "https://loja.exemplo/obrigado",
    "cancel_url": "https://loja.exemplo/pedido/123",
    "expires_in": 259200,
}, idempotency_key="pedido-123-50508-2026-12-01")
```

## 2. Preço fixo ou valor livre

- **Preço fixo**: envie só `product_id` e `price_id`; o valor é o do preço.
- **Valor livre** (o seu sistema calcula o total): envie `amount_cents` e `items`. O comprador vê o valor e as linhas e **não pode mudá-las**, na página, no modal, nos componentes e no transparente. Vale para cartão de crédito, débito e Pix, e é o valor que volta em pedidos, pagamentos, recibo e eventos. Sem `amount_cents`, quem digita o valor é o comprador.
- Se o comprador parcelar no crédito, os juros do parcelamento são dele e vêm **além** de `amount_cents`: o pedido guarda `installments` e `installment_interest_cents`, e o `amount_cents` dos eventos `checkout_payment.*` já inclui os juros. Para conferir o valor do pedido, compare com `amount_cents` do pedido, não com o total pago.

## 3. `amount_cents` e `items`: as regras

- A soma de `quantity` vezes `unit_amount_cents` de todas as linhas **tem de ser igual** a `amount_cents`, senão 422.
- Uma linha de valor negativo é um desconto ou cupom, desde que a soma continue maior que zero. Isto resolve "desconto em parte do valor": mande a linha negativa.
- Até 50 linhas; nenhuma linha passa de 999999999999 centavos; enviadas sem `amount_cents`, a soma das linhas é o valor.
- Nome de linha com no máximo 200 caracteres, sem tabulação, quebra de linha, ESC nem marcas de direção do texto.
- Nomes curtos e legíveis ("Câmera Portaria, 01/12 a 31/12"), porque o comprador os lê no checkout, no recibo e no portal.
- Em uma **assinatura** (preço recorrente), as linhas só mostram do que o valor é feito: envie-as sem `amount_cents`, com a soma igual ao valor do preço vezes a quantidade (senão 422). O preço continua sendo quem define o que se cobra.

## 4. `client_reference_id` e `metadata`

- `client_reference_id` é o id do pedido no seu sistema. Volta no checkout, no pedido, no pagamento e nos eventos `checkout.*`, `order.*`, `checkout_payment.*` e `refund.*`. É o jeito certo de ligar um aviso ao pedido, e as listas filtram por ele (`GET /orders?client_reference_id=pedido-123`).
- `metadata` guarda o que mais você quiser ligar à venda (a organização, o usuário, o id da câmera): até 50 pares, valor texto, número ou booleano. Volta em tudo da venda. Em listas, filtre com `metadata[chave]=valor` (SDK 0.5.5+).
- Assinaturas não guardam `client_reference_id`; para achar uma assinatura, use `metadata`.

## 5. Validade, Pix e `expires_in`

- `expires_in` é o tempo que o comprador tem para **abrir** a cobrança (60 s a 72 h). Para um pedido que o cliente pode pagar amanhã, use `259200`.
- O Pix, depois de gerado, vale **24 horas**. Passado esse tempo, o comprador abre o mesmo link e gera outro Pix, enquanto a sessão ainda valer.
- A janela do Pix tem "Alterar forma de pagamento". A troca cancela o Pix e continua **na mesma sessão** (`checkout_id` e `session_id` não mudam, e não sai `checkout.expired`). Se o Pix for pago durante a troca, o cartão não é cobrado. Vale para a página e para os componentes.
- O comprador paga no tempo dele: o pedido só está pago quando chega `order.paid`.

## 6. Os modos de pagamento no comprador

| # | Modo | O que o comprador vê | Precisa de |
|---|---|---|---|
| 1 | Redirecionar para a página da Peráta | sai do seu site, paga e volta pela `success_url` | só o `url` |
| 2 | Modal | uma janela por cima do seu site, com botão de fechar | `url` e o site liberado |
| 3 | Componentes prontos | o formulário da Peráta dentro do seu site (carteira do aparelho, crédito, débito, Pix, boleto e cartões salvos) | `client_secret` e o site liberado |
| 4 | Botão da carteira | só o botão do Google Pay ou do Apple Pay no seu layout | `client_secret` e o site liberado |
| 5 | Transparente | o seu formulário; só o campo do cartão é um quadro da Peráta | `client_secret` e o site liberado |

O script é um só, `https://perata.sh/v1/perata.js`, sem chave de API. O servidor entrega ao navegador o `url` ou o `client_secret`, nunca a chave.

```html
<script src="https://perata.sh/v1/perata.js"></script>
<div id="pagamento"></div>
<script>
  var perata = Perata();

  // 1. Redirecionar (url: o que a API devolveu)
  // perata.redirectToCheckout({ url: checkoutUrl });

  // 2. Modal
  // perata.openCheckout({ url: checkoutUrl, theme: "light",
  //   onSuccess: function (event) { /* pago */ }, onClose: function () {},
  //   onError: function (error) { /* origin_not_allowed, load_timeout... */ } });

  // 3. Componentes prontos (clientSecret: o que a API devolveu)
  var pagamento = perata.components.payment({
    clientSecret: clientSecret,
    onSuccess: function (result) { /* result.status, result.pix, result.boleto */ },
    onError: function (error) { /* error.code, error.message */ },
  });
  pagamento.mount("#pagamento");
</script>
```

Modo 4, só a carteira: `perata.components.wallet({ clientSecret, customer: { email, document }, onReady, onSuccess, onCancel, onError }).mount("#carteira")`. Em Produção o seu site precisa estar cadastrado no Google Pay e no Apple Pay pela equipe da Peráta; fale com o suporte.

Modo 5, formulário próprio:

```js
var cartao = perata.components.card({ clientSecret: clientSecret, onChange: function (s) { /* s.complete */ } });
cartao.mount("#cartao");

// no botão de pagar
perata.confirmPayment({
  clientSecret: clientSecret,
  card: cartao,
  method: "card", // "pix" ou "boleto" não usam o campo do cartão
  installments: 1,
  customer: { name: "Ana Souza", email: "ana@exemplo.com", document: "52998224725" },
}).then(function (result) {
  // result.redirectUrl: desafio 3-D Secure do débito, leve o comprador até lá
  // result.error: recusa (não é exceção)
  // result.status: "succeeded", "confirmed" (Pix e boleto esperando) ou "failed"
});
```

`perata.getInstallments({ clientSecret })` devolve as parcelas que a sessão oferece. Em Pix ou boleto, `result.pix` traz o QR (`qrCodeImage`), o copia e cola (`copyPaste`) e o prazo (`expiresAt`); depois de gerado o `client_secret` está gasto, e o comprador acompanha o pagamento com `perata.getStatus({ statusKey })` até um estado final (`succeeded`, `failed`, `expired`; `confirmed` é "esperando o comprador").

Débito: o cartão de débito passa por autenticação 3DS. Na página e nos componentes é a Peráta que conduz o desafio; no transparente, quando `result.redirectUrl` vem preenchido, leve o comprador até ele.

Para fixar a versão do script (e não receber correções sem aviso), carregue o endereço com o hash e a integridade (SRI) de **Configurações › Como integrar**, com `crossorigin="anonymous"`. Se o seu site usa Content-Security-Policy, libere a origem do `perata.js` em `script-src` e em `frame-src`. Para projetos com empacotador e para React existem os pacotes `@perata-sh/js` e `@perata-sh/react`, ainda não publicados.

Ver o estado de uma sessão de qualquer lugar: `GET /api/v1/checkouts/client/status/{status_key}` (sem chave de API) devolve onde ela está (`open`, `confirmed`, `succeeded`, `failed`, `expired`), sem dados do comprador.

### Sites permitidos

Os modos 2 a 5 rodam o `perata.js` no seu site, e a Peráta só aceita os sites que a organização liberou em **Configurações › Checkout incorporado › Sites permitidos**. Sem isso o erro é `origin_not_allowed` (no modal e nos componentes, o motivo chega em `onError`). Libere cada origem (`https://loja.exemplo`) e confira a lista também depois de abrir a Produção. O modo 1 (redirecionar) não precisa de nada liberado.

## 7. O valor mudou? Encerre o checkout velho

Quando o valor do pedido muda (multa do dia, item novo, desconto) ou o pedido é cancelado, o link e o Pix antigos ainda estão vivos. Para o cliente nunca pagar duas vezes:

1. `POST /api/v1/checkouts/{id}/expire` (`checkouts:write`; SDK `checkouts.expire`). O `{id}` é o `id` que guardou (também aceita o `session_id`).
2. A resposta 200 traz `id`, `status: "expired"` e `sessions[]` (`session_id`, `status`, `expired_at`, `payment_id`, `method`, `payment_state`, `canceled`, `already_closed`). A página, o `client_secret` e o QR do Pix deixam de valer, o Pix já gerado é cancelado e chega o evento `checkout.expired`.
3. Repetir é seguro: volta `already_closed: true`.
4. **409** se o checkout já foi pago ou emitiu boleto. Nesse caso o pedido está pago: **não abra outro** e confirme pelo webhook `order.paid`.
5. Se foi 200, abra o novo checkout com o novo `amount_cents` e uma `Idempotency-Key` nova.
6. Nunca reenvie ao cliente o link antigo.

```go
closed, err := client.Checkouts.Expire(ctx, oldCheckoutID)
var apiErr *perata.Error
if errors.As(err, &apiErr) && apiErr.StatusCode == http.StatusConflict {
	// já pago: não abra outro checkout, o pedido está pago
	return nil
}
if err != nil {
	return err
}
_ = closed // closed.Status == "expired"
```

```ts
try {
  await perata.checkouts.expire(oldCheckoutId);
} catch (e) {
  if (e instanceof PerataError && e.status === 409) return; // já pago
  throw e;
}
```

```python
try:
    perata.checkouts.expire(old_checkout_id)
except PerataError as e:
    if e.status == 409:
        return  # já pago
    raise
```

## 8. Idempotency-Key do checkout

Componha a chave com o pedido, o valor e o dia: `pedido-123-50508-2026-12-01`. A mesma chave com o mesmo corpo devolve a mesma sessão; a mesma chave com **outro corpo** (outro valor, por exemplo) dá 409. Por isso, ao mudar o valor, a chave muda.

Cuidado: na repetição de uma criação com a mesma chave, o `client_secret` não vem mais (vem vazio) e o `url` volta a ser o endereço do **link**, que abre uma sessão nova a cada visita. Guarde o `url`, o `session_id` e o `status_key` da **primeira** resposta e reuse-os, em vez de criar de novo para "recuperar" o link.

## 9. Erros do checkout

- 422 `invalid_request` com `fields`: valor fora do mínimo ou do máximo; preço que não é de valor livre; `quantity` diferente de 1; soma das linhas diferente de `amount_cents`; caractere de controle; `customer_id` junto com e-mail ou nome; `discount_id` inexistente ou de outro produto; `subscription_start_at` fora do intervalo (de amanhã até um ano); `first_period_extra_days` fora de 1 a 365, em preço avulso ou grátis, com teste grátis no produto ou junto com `subscription_start_at`. A `message` traz cada campo e o primeiro motivo, em português.
- 403 `forbidden`: a chave não tem `checkouts:write` (ou `products:read` num preço recorrente).
- 409: mesma `Idempotency-Key` com outro corpo, ou `expire` num checkout já pago.
- 410: checkout de `subscription_start_at` aberto depois da data.
- Depois de pago, abrir o mesmo `url` mostra a confirmação e nada é cobrado de novo.

## 10. Testar no ambiente Teste

Cartão `5315281703921200` (validade futura, CVV 123) aprova; `4556839012717832` recusa; o pedido recusado continua em aberto. Teste ainda: um Pix (a tela gera o código), um valor que muda antes do pagamento (o link antigo deixa de abrir e o novo cobra o novo valor), a volta pela `success_url` sem pagar (o pedido não pode ser liberado), e o webhook chegando. Nada é cobrado no Teste.
