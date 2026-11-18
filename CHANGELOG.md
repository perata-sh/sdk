# Changelog

Todos os SDKs da Peráta saem com a mesma versão (`VERSION`). O histórico de cada versão anterior, com os nomes de cada linguagem, está em [`dart/CHANGELOG.md`](dart/CHANGELOG.md) e nas [releases](https://github.com/perata-sh/sdk/releases).

## Não lançado

### Pacotes de navegador (escritos à mão, ainda não publicados)

- `js/`: `perata.components.wallet` (o botão do Google Pay e do Apple Pay no layout do lojista), os tipos `WalletComponent`, `WalletComponentOptions`, `WalletComponentEvents` e `WalletKind`, `ChangeEvent.available`, `update({ customer })` e os códigos de erro `wallet_element_required`, `customer_incomplete` e `wallet_unavailable`. `components.payment` passa a trazer a carteira do aparelho e os cartões salvos. Seguem o `perata.js` do perata.sh e valem depois do deploy dele.
- `react/`: `WalletComponent`.

## 0.5.2 (17/11/2026)

Gerado a partir do contrato da API 0.1.0. A 0.5.0 e a 0.5.1 saíram só em Go (`go/v0.5.0`, `go/v0.5.1`); esta é a primeira 0.5 publicada nas outras dez linguagens, e traz também tudo o que está na 0.5.0, abaixo.

### Os 11 SDKs de servidor

- **Encerrar um checkout.** `checkouts.expire` (`POST /api/v1/checkouts/{id}/expire`) fecha um checkout que não deve mais ser pago, por exemplo quando o valor do pedido mudou: toda sessão aberta ou à espera do pagamento é encerrada, a Cielo retira o QR do Pix e libera a reserva do cartão. Responde `CheckoutExpired`, com uma `CheckoutExpiredSession` por sessão (`method` é nulo quando o comprador não escolheu um meio). Repetir a chamada é seguro.
- **Filtros nas listas.** `orders.list`, `payments.list`, `checkouts.list`, `refunds.list` e `subscriptions.list` aceitam, conforme a lista, `client_reference_id`, `status`, `customer_id`, `external_customer_id`, `created_after`, `created_before` e `sorting`. Um filtro que a lista não responde é recusado (422), em vez de ignorado. O filtro por metadata (`metadata[chave]=valor`) já vale na API, chamada direto, mas ainda não está no contrato nem nos SDKs.
- **Identidade do cliente.** `Customer` e os parâmetros de criação e alteração ganham `tax_id` e `tax_id_kind` (CPF ou CNPJ), `phone`, `billing_name` e `billing_address`. O CPF vem inteiro só para a chave cuja conta pode lê-lo; mascarado para as outras, também na fatura do pedido.
- **Validação mais estrita na API.** Caracteres de controle e marcas invisíveis de direção do texto são recusados em `client_reference_id`, `label`, nas linhas e no metadata; linhas sem `amount_cents` não podem somar mais de 999999999999 centavos; `created_after` e `created_before` fora de 1970 a 9999 são recusados.

## 0.5.0 (17/11/2026)

Gerado a partir do contrato da API 0.1.0, com o checkout por `client_secret`.

### Os 11 SDKs de servidor

- **Checkout transparente e embutido.** `checkouts.create` (`POST /api/v1/checkouts`) abre também a sessão de compra e devolve o novo modelo `CheckoutCreated`: tudo o que `Checkout` trazia mais `session_id`, `client_secret`, `client_secret_expires_at` e `status_key`. O servidor entrega o `client_secret` ao navegador, que monta os campos de pagamento com o Peráta.js (`https://perata.sh/v1/perata.js`) sem chave de API; o `status_key` acompanha um Pix ou boleto depois que o `client_secret` é gasto. O `client_secret` vem na criação e só nela: na repetição de uma criação idempotente (a mesma `Idempotency-Key`) ele vem vazio. A sessão vale 30 minutos, ou o `expires_in` pedido. **Mudança incompatível de tipo, nas linguagens tipadas: quem declarava o retorno como `Checkout` passa a usar `CheckoutCreated`.**
- `CheckoutsCreateParams` ganha `return_url`, `customer_id`, `external_customer_id`, `customer_email`, `customer_name`, `metadata`, `allow_discount_codes`, `require_billing_address` e `expires_in`.
- Modelos novos do contrato: `CheckoutClient` (a sessão como o navegador a lê), com `CheckoutClientItem`, `CheckoutClientCustomer`, `CheckoutClientDiscount`, `CheckoutClientPayment`, `CheckoutClientPix` e `CheckoutClientBoleto`, além de `CheckoutInstallment`, `CheckoutNextAction`, `CheckoutSavedData`, `CheckoutSavedDataSent`, `CheckoutSavedCard`, `CheckoutSavedProfile`, `CardAuthentication` e `CardTokenization`. As oito rotas `/api/v1/checkouts/client/*` são chamadas pelo navegador com o `client_secret`, pelo Peráta.js, e não com a chave da API: não são métodos dos SDKs de servidor.
- Um campo que pode ser nulo e aponta para um modelo (`customer`, `discount` e `payment` de `CheckoutClient`; `pix` e `boleto` de `CheckoutClientPayment`) é agora tipado como o modelo ou nulo, e não mais um valor livre (`any`). O gerador lê o `anyOf` de "modelo ou nulo" do OpenAPI 3.1.
- **Swift: `urL` passa a ser `url`.** O nome de uma propriedade que é só `url` saía com o último `L` maiúsculo (`checkout.urL`) por um defeito do gerador. **Mudança incompatível para quem lia `urL`.**
- O README de cada SDK ganhou o fluxo do checkout transparente e embutido: o servidor cria a sessão e entrega o `client_secret` ao navegador. Cada SDK ganhou o teste desse fluxo (a criação, o segredo vazio na repetição idempotente) e o de um modelo que pode ser nulo.

- **O servidor do lojista define o valor do checkout.** `CheckoutsCreateParams` ganha `amount_cents` (Go: `AmountCents`), o valor do pedido todo em centavos, que vale num preço de valor livre (`custom`): o comprador vê o valor e não pode mudá-lo, na página, no modal, nos componentes e no checkout transparente, e é ele que o cartão e o Pix cobram. Abaixo do mínimo do preço, acima do máximo, num preço que não é de valor livre ou com `quantity` diferente de 1 a API responde 422; repetir a `Idempotency-Key` com outro valor, 409.
- **Linhas do pedido.** `items`, uma lista de `{name, quantity, unit_amount_cents}` (`CheckoutsCreateItem` no pedido; `CheckoutItem`, `CheckoutCreatedItem` e `OrderItem` nas respostas), cuja soma de `quantity` vezes `unit_amount_cents` é igual a `amount_cents` (422 se não for; uma linha negativa é um desconto, e a soma continua maior que zero). Aparecem no checkout, no pedido, no recibo e nos eventos.
- **Referência do pedido e metadata.** `client_reference_id` (até 255 caracteres) e `metadata` voltam em `Checkout`, `CheckoutCreated`, `Order`, `Payment`, na sessão do cliente (`CheckoutClient`) e nos eventos `checkout.*`, `order.*`, `checkout_payment.*` e `refund.*`, para achar de qual pedido veio cada pagamento. `Order` e `Payment` ganham `items`, `metadata` e `client_reference_id`; `Checkout` e `CheckoutCreated` ganham `amount_cents`, `items`, `metadata` e `client_reference_id`; `CheckoutClient` ganha `amount_locked` e `client_reference_id`; o recibo e a fatura do pedido ganham `items`.
- **Validade.** `expires_in` vai a 259200 segundos (72 horas; antes 86400). O Pix gerado vale 24 horas.
- Os eventos `checkout_payment.*` e `refund.*` passam a trazer, além dos identificadores, `checkout_id`, `amount_cents`, `currency`, `client_reference_id` e `metadata` (e `method` ou `payment_id`); o objeto do evento `refund.*` do Polar ganha `checkout_id`, `client_reference_id` e `metadata`.

### Pacotes de navegador (escritos à mão, ainda não publicados)

- `js/` (`@perata-sh/js`): o carregador do Peráta.js e os tipos de `Perata()`. Novo na 0.5.0: fixar a versão do script pelo hash e pelo SRI (`pin`), os códigos de erro do script (`origin_not_allowed`, `load_timeout`, `checkout_not_found`, `network_error`…) tipados em `PerataErrorCode` e `PerataError`, e o `onError` do `openCheckout`. Esses códigos e o `onError` seguem o `perata.js` das correções em andamento no perata.sh, e valem depois do deploy delas.
- `react/` (`@perata-sh/react`): o provedor, o componente de pagamento, o campo de cartão e o botão de checkout, sobre o `@perata-sh/js`.
- Os nomes dos dois pacotes ainda esperam a confirmação do Paulo; ambos continuam `"private": true`.

### Ferramentas

- `./regen.sh` escreve de novo os 11 SDKs a partir do contrato commitado no `develop` do perata.sh (ou em outro ref, ou o arquivo da árvore de trabalho com `--worktree`).
