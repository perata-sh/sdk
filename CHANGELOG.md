# Changelog

Todos os SDKs da Peráta saem com a mesma versão (`VERSION`). O histórico de cada versão anterior, com os nomes de cada linguagem, está em [`dart/CHANGELOG.md`](dart/CHANGELOG.md) e nas [releases](https://github.com/perata-sh/sdk/releases).

## Não lançado

### Pacotes de navegador (escritos à mão, ainda não publicados)

- `js/`: `perata.components.wallet` (o botão do Google Pay e do Apple Pay no layout do lojista), os tipos `WalletComponent`, `WalletComponentOptions`, `WalletComponentEvents` e `WalletKind`, `ChangeEvent.available`, `update({ customer })` e os códigos de erro `wallet_element_required`, `customer_incomplete` e `wallet_unavailable`. `components.payment` passa a trazer a carteira do aparelho e os cartões salvos. Seguem o `perata.js` do perata.sh e valem depois do deploy dele.
- `react/`: `WalletComponent`.

## 0.5.0 (16/11/2026)

Gerado a partir do contrato da API 0.1.0, com o checkout por `client_secret`.

### Os 11 SDKs de servidor

- **Checkout transparente e embutido.** `checkouts.create` (`POST /api/v1/checkouts`) abre também a sessão de compra e devolve o novo modelo `CheckoutCreated`: tudo o que `Checkout` trazia mais `session_id`, `client_secret`, `client_secret_expires_at` e `status_key`. O servidor entrega o `client_secret` ao navegador, que monta os campos de pagamento com o Peráta.js (`https://perata.sh/v1/perata.js`) sem chave de API; o `status_key` acompanha um Pix ou boleto depois que o `client_secret` é gasto. O `client_secret` vem na criação e só nela: na repetição de uma criação idempotente (a mesma `Idempotency-Key`) ele vem vazio. A sessão vale 30 minutos, ou o `expires_in` pedido. **Mudança incompatível de tipo, nas linguagens tipadas: quem declarava o retorno como `Checkout` passa a usar `CheckoutCreated`.**
- `CheckoutsCreateParams` ganha `return_url`, `customer_id`, `external_customer_id`, `customer_email`, `customer_name`, `metadata`, `allow_discount_codes`, `require_billing_address` e `expires_in`.
- Modelos novos do contrato: `CheckoutClient` (a sessão como o navegador a lê), com `CheckoutClientItem`, `CheckoutClientCustomer`, `CheckoutClientDiscount`, `CheckoutClientPayment`, `CheckoutClientPix` e `CheckoutClientBoleto`, além de `CheckoutInstallment`, `CheckoutNextAction`, `CheckoutSavedData`, `CheckoutSavedDataSent`, `CheckoutSavedCard`, `CheckoutSavedProfile`, `CardAuthentication` e `CardTokenization`. As oito rotas `/api/v1/checkouts/client/*` são chamadas pelo navegador com o `client_secret`, pelo Peráta.js, e não com a chave da API: não são métodos dos SDKs de servidor.
- Um campo que pode ser nulo e aponta para um modelo (`customer`, `discount` e `payment` de `CheckoutClient`; `pix` e `boleto` de `CheckoutClientPayment`) é agora tipado como o modelo ou nulo, e não mais um valor livre (`any`). O gerador lê o `anyOf` de "modelo ou nulo" do OpenAPI 3.1.
- **Swift: `urL` passa a ser `url`.** O nome de uma propriedade que é só `url` saía com o último `L` maiúsculo (`checkout.urL`) por um defeito do gerador. **Mudança incompatível para quem lia `urL`.**
- O README de cada SDK ganhou o fluxo do checkout transparente e embutido: o servidor cria a sessão e entrega o `client_secret` ao navegador. Cada SDK ganhou o teste desse fluxo (a criação, o segredo vazio na repetição idempotente) e o de um modelo que pode ser nulo.

### Pacotes de navegador (escritos à mão, ainda não publicados)

- `js/` (`@perata-sh/js`): o carregador do Peráta.js e os tipos de `Perata()`. Novo na 0.5.0: fixar a versão do script pelo hash e pelo SRI (`pin`), os códigos de erro do script (`origin_not_allowed`, `load_timeout`, `checkout_not_found`, `network_error`…) tipados em `PerataErrorCode` e `PerataError`, e o `onError` do `openCheckout`. Esses códigos e o `onError` seguem o `perata.js` das correções em andamento no perata.sh, e valem depois do deploy delas.
- `react/` (`@perata-sh/react`): o provedor, o componente de pagamento, o campo de cartão e o botão de checkout, sobre o `@perata-sh/js`.
- Os nomes dos dois pacotes ainda esperam a confirmação do Paulo; ambos continuam `"private": true`.

### Ferramentas

- `./regen.sh` escreve de novo os 11 SDKs a partir do contrato commitado no `develop` do perata.sh (ou em outro ref, ou o arquivo da árvore de trabalho com `--worktree`).
