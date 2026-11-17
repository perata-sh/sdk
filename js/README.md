# Peráta.js para o navegador (`@perata-sh/js`)

O carregador e os tipos do Peráta.js, o script que coloca o checkout da Peráta no seu site. Faz pelo checkout da Peráta o que `@stripe/stripe-js` faz pelo da Stripe e `@mercadopago/sdk-js` pelo do Mercado Pago: injeta o script uma vez, devolve a instância já tipada e não depende de nada. Para React, use também [`@perata-sh/react`](../react).

> Estado: o nome do pacote é uma proposta e ainda não foi publicado. Apague este aviso quando o nome for confirmado e o pacote sair.

```sh
npm install @perata-sh/js
```

Funciona em ESM e em CommonJS, no navegador e (sem fazer nada) no servidor, então pode ser chamado de código que também roda em Next.js.

## Como funciona

O seu **servidor** cria a sessão de pagamento com o [SDK de servidor](../typescript) e entrega ao navegador o `url` (checkout hospedado) ou o `client_secret` (componentes e cartão transparente). A chave de API (`prk_…`) nunca sai do servidor. O **navegador** usa o Peráta.js, em um dos quatro modos abaixo.

| Modo | Quando usar | O que você escreve |
|---|---|---|
| Redirecionamento | O mais simples: a página inteira vai para o checkout da Peráta | `perata.redirectToCheckout({ url })` |
| Modal | O checkout abre sobre a sua página, sem o comprador sair dela | `perata.openCheckout({ url, onSuccess })` |
| Componentes prontos | O formulário da Peráta dentro da sua página (cartão, débito, Pix, boleto, cartões salvos e a carteira do aparelho), que confirma sozinho | `perata.components.payment({ clientSecret })` |
| Transparente | Você desenha o formulário; só os campos do cartão ficam num quadro seguro da Peráta | `perata.components.card(...)` e `perata.confirmPayment(...)` |
| Transparente, só a carteira | O botão do Google Pay ou do Apple Pay no seu layout, num quadro da Peráta | `perata.components.wallet({ clientSecret })` |

### No servidor (Node)

```ts
import { Perata } from "@perata-sh/sdk";
import { createServer } from "node:http";

const perata = new Perata({ apiKey: process.env.PERATA_API_KEY! }); // prk_test_… ou prk_live_…

createServer(async (req, res) => {
  if (req.method === "POST" && req.url === "/api/checkout") {
    const checkout = await perata.checkouts.create(
      { product_id: "prod_…", price_id: "price_…", success_url: "https://loja.exemplo/obrigado" },
      { idempotencyKey: `pedido-${Date.now()}` },
    );
    res.setHeader("Content-Type", "application/json");
    // `url` serve os dois primeiros modos; `client_secret`, os dois últimos.
    res.end(JSON.stringify({ url: checkout.url, clientSecret: checkout.client_secret }));
    return;
  }
  res.statusCode = 404;
  res.end();
}).listen(3000);
```

O `client_secret` identifica só aquela sessão e pode ir ao navegador (a chave de API, nunca). Ele vem na resposta de `POST /api/v1/checkouts` (o tipo `CheckoutCreated`, no SDK de servidor desta versão, com `session_id`, `client_secret_expires_at` e `status_key`) e só nela: na repetição de uma criação com a mesma `Idempotency-Key` ele vem vazio, então entregue-o ao navegador na primeira resposta. Por isso o exemplo acima gera uma chave nova a cada pedido; para repetir uma criação com segurança depois de uma falha de rede, guarde o `client_secret` que a primeira resposta trouxe. A sessão vale 30 minutos, ou os segundos de `expires_in`.

### No navegador

```ts
import { isFinalStatus, loadPerata } from "@perata-sh/js";

const perata = await loadPerata(); // null no servidor
if (!perata) throw new Error("só no navegador");

const { url, clientSecret } = await fetch("/api/checkout", { method: "POST" }).then((r) => r.json());
```

**1. Redirecionamento**

```ts
perata.redirectToCheckout({ url });
```

**2. Modal**

```ts
const modal = await perata.openCheckout({ // resolve quando o checkout aparece
  url,
  theme: "dark", // "light" | "dark"
  onSuccess: ({ successURL, redirect }) => console.log("pago", successURL),
  onClose: () => console.log("o comprador fechou"),
  onError: (error) => console.error(error.code), // o checkout não abriu, e a promessa rejeita com o mesmo erro
});
// modal.close() tira o checkout da página
```

Depois do pagamento a Peráta leva o comprador ao `success_url` do checkout. Para fazer isso você mesmo, devolva `false` em `onSuccess`. Um `url` que não seja um link de checkout da Peráta rejeita a promessa com `invalid_checkout_url` (e `redirectToCheckout` lança o mesmo erro).

**3. Componentes prontos**

```ts
const payment = perata.components.payment({
  clientSecret,
  appearance: { theme: "light", variables: { colorPrimary: "#0a7d5a", borderRadius: "8" } },
  locale: "pt-BR", // por enquanto só pt-BR
  onSuccess: (result) => {
    // result.status, result.orderId, result.paymentId, result.statusKey
    // Pix e boleto: result.pix.copyPaste, result.boleto.digitableLine…
  },
  onError: (error) => console.error(error.code, error.message),
});
payment.mount("#pagamento"); // um seletor ou um elemento
// payment.update({ appearance: { theme: "dark" } });
// payment.focus();
// payment.destroy(); // tira da página e esquece os ouvintes (unmount() só tira)
```

O formulário mostra as mesmas formas de pagamento da página hospedada: a carteira do aparelho primeiro (Google Pay no Chrome e no Android, Apple Pay no Safari), depois cartão de crédito, débito (onde estiver ligado), Pix, boleto (se a conta o aceita) e os cartões que o comprador já salvou, liberados por um código no e-mail dele. A carteira só aparece se estiver ligada para o seu site, cadastrada na Google e na Apple pela equipe da Peráta (em produção) e o navegador do comprador puder pagar com ela.

`appearance` aceita `theme` (`"light"`, `"dark"` ou `"auto"`) e quatro variáveis: `colorPrimary` (`#rrggbb`), `borderRadius` (de 0 a 24, em texto: `"8"`), `fontFamily` (`"display"` ou `"system"`) e `fontSize` (`"sm"`, `"md"` ou `"lg"`). Também vale escrever `primaryColor`, `borderRadius`, `fontFamily` e `size` soltos, sem `variables`. Valor desconhecido é ignorado.

**3b. Só o botão da carteira, no seu layout**

```ts
const carteira = perata.components.wallet({
  clientSecret,
  customer: { email: "maria@exemplo.com", document: "529.982.247-25" }, // quem paga; carteira.update({ customer }) muda depois
  onReady: (state) => console.log(state.available), // ["google_pay"], ["apple_pay"] ou []: sem carteira, nada aparece
  onSuccess: (result) => {}, // result.status: "succeeded" ou "confirmed"
  onCancel: () => {},        // o comprador fechou a janela da carteira
  onError: (error) => console.error(error.code, error.message), // customer_incomplete, wallet_unavailable, payment_declined…
});
carteira.mount("#carteira");
```

O botão é do Google ou da Apple e paga sozinho: o cartão nunca passa pela sua página e `confirmPayment` não confirma carteira (rejeita com `wallet_element_required`). O quadro abre dentro de um `iframe` da Peráta com `allow="payment"`, e o Google e a Apple conferem o domínio da sua página, não o da Peráta: em produção o seu site precisa estar cadastrado nas duas carteiras pela equipe da Peráta.

**4. Transparente**: o número do cartão é digitado em um `iframe` da Peráta e nunca passa pela sua página; o resto do formulário é seu.

```ts
const card = perata.components.card({
  clientSecret,
  onChange: ({ complete, valid, empty, brand, last4, error, method }) => {
    botao.disabled = !complete; // brand em minúsculas ("visa"); nunca o número inteiro
  },
});
card.mount("#cartao");

const parcelas = await perata.getInstallments({ clientSecret });
// [{ installments: 1, installmentAmountCents: 10000, totalCents: 10000, interestCents: 0, label: "1x de R$ 100,00 (à vista)" }, …]

botao.addEventListener("click", async () => {
  const result = await perata.confirmPayment({
    clientSecret,
    card,
    method: "card", // "card" | "pix" | "boleto"; "card" por padrão
    installments: 3,
    customer: { name: "Maria Souza", email: "maria@exemplo.com", document: "529.982.247-25" },
  });
  if (result.redirectUrl) return window.location.assign(result.redirectUrl); // desafio 3-D Secure
  if (result.error) return mostrar(result.error.message); // recusa não é exceção
  if (result.status === "succeeded") return agradecer(result.orderId);
});
```

`customer` aceita `name`, `email`, `document` (CPF ou CNPJ, com ou sem pontuação) e `address` (`street`, `number`, `complement`, `district`, `city`, `state`, `postalCode`); não há telefone, a sessão não guarda um.

**Pix e boleto, e acompanhar o pagamento.** Não há campo de cartão: confirme direto. Depois de gerado, o `clientSecret` está gasto; para saber quando o comprador pagou, guarde o `statusKey` do resultado e pergunte com `getStatus`.

```ts
const result = await perata.confirmPayment({ clientSecret, method: "pix", customer: { name: "Maria Souza", email: "maria@exemplo.com", document: "529.982.247-25" } });
if (result.error) return mostrar(result.error.message);

img.src = result.pix!.qrCodeImage;        // data URL SVG, direto num <img>
copiar.value = result.pix!.copyPaste;     // o "copia e cola"
prazo.textContent = result.pix!.expiresAt; // ISO 8601

// confirmed = esperando o comprador; succeeded, failed e expired encerram.
const espera = setInterval(async () => {
  const atual = await perata.getStatus({ statusKey: result.statusKey! });
  if (isFinalStatus(atual.status)) {
    clearInterval(espera);
    atual.status === "succeeded" ? agradecer(atual.orderId) : mostrar(atual.error?.message ?? "Pagamento não concluído");
  }
}, 3000);
```

`isFinalStatus` vem de `@perata-sh/js`. Um boleto é igual, com `perata.confirmPayment({ clientSecret, method: "boleto", customer })` e `result.boleto` (`digitableLine`, `barcode`, `pdfUrl`, `dueDate`); para acompanhá-lo, o mesmo `getStatus`. `getStatus` rejeita com `invalid_status_key` ou `http_<status>` (um 404, por exemplo).

## `loadPerata(opções?)`

Devolve `Promise<PerataInstance | null>`. É chamada quantas vezes for preciso: o script é injetado uma vez e a instância é compartilhada. No servidor devolve `null`. Se `window.Perata` já existir (você pôs a tag `<script>` à mão), usa essa e não injeta nada.

| Opção | Para que serve |
|---|---|
| `scriptUrl` | Outro endereço do script (sandbox, servidor local). Precisa ser `https`; `http` só para `localhost`, `127.0.0.0/8` e `::1`. O checkout abre na Peráta que serviu o script. Padrão: `https://perata.sh/v1/perata.js` (`PERATA_SCRIPT_URL`). |
| `nonce` | O nonce da sua Content-Security-Policy para a tag do script. |
| `timeoutMs` | Quanto esperar antes de desistir; 15 000 por padrão. |
| `pin` | Fixa uma versão do script: `{ hash, integrity }` de uma versão do `perata.js`. Veja abaixo. |

Falhas rejeitam com `PerataLoadError`, cujo `code` é `invalid_url`, `invalid_pin`, `network`, `timeout` ou `missing_global`. Uma falha é esquecida: chamar de novo tenta outra vez.

### Fixar a versão do script

O endereço padrão (`/v1/perata.js`) recebe as correções em minutos. Para carregar sempre os mesmos bytes, use o endereço que leva o hash do conteúdo (`/v1/perata.<hash>.js`, que nunca muda) com o valor de integridade (Subresource Integrity, `sha384-…`) da mesma versão; o navegador recusa um script que não seja exatamente o que você leu. O `hash` e o `integrity` de cada versão ficam em **Configurações › Como integrar**, no painel da Peráta.

```ts
const perata = await loadPerata({
  pin: { hash: "0123456789abcdef", integrity: "sha384-…" },
});
```

O pacote monta o endereço (`https://perata.sh/v1/perata.0123456789abcdef.js`, na origem de `scriptUrl` se você passar uma), põe `integrity` e `crossorigin="anonymous"` na tag e recusa, com `invalid_pin`, um hash que não tenha 16 dígitos hexadecimais ou um valor que não comece por `sha256-`, `sha384-` ou `sha512-`. Uma nova versão do script é um hash e um valor novos: atualize os dois para adotá-la. Com a tag à mão, é o mesmo: `<script src="https://perata.sh/v1/perata.<hash>.js" integrity="sha384-…" crossorigin="anonymous"></script>`.

Se o seu site usa Content-Security-Policy, libere a origem do `perata.js` em `script-src` e em `frame-src`.

## Tipos

Todo o contrato está tipado e exportado, do jeito que o `perata.js` o fala: `PerataInstance`, `PaymentResult` (`status`, `orderId`, `paymentId`, `statusKey`, `pix`, `boleto`, `redirectUrl`, `error`), `PaymentStatus` (`open`, `confirmed`, `succeeded`, `failed`, `expired`), `PixResult`, `BoletoResult`, `InstallmentOption`, `ConfirmPaymentParams`, `CustomerInput`, `PaymentComponent`, `CardComponent`, `ChangeEvent`, `Appearance`, `OpenedCheckout`, `CheckoutSuccessEvent` e os demais. `window.Perata` também ganha tipo.

Os erros têm um `code` para o código decidir: `PerataErrorCode` lista `origin_not_allowed` (o site não está em **Configurações › Checkout incorporado › Sites permitidos**), `load_timeout`, `checkout_not_found` (o `clientSecret` ou o endereço não abre nada: errado, vencido ou já usado), `network_error`, `invalid_client_secret`, `invalid_checkout_url`, `invalid_status_key`, `payment_declined`, `checkout_expired`, `http_<status>` e os demais. Uma chamada que rejeita rejeita com um `PerataError` (um `Error` com `code`); o `onError` recebe um `PerataErrorInfo` (`code`, `message` e, quando a API disse, `fields`).

Os componentes têm `mount(alvo)`, `unmount()`, `destroy()`, `update({ appearance })`, `focus()`, `getState()`, `on(evento, função)` e `off(evento, função)`; os que respondem algo respondem o próprio componente, então encadeiam. Eventos: `ready` (com o estado dos campos), `change` (`{ complete, brand, last4, error, empty, valid, method }`), `success` (só no componente de pagamento) e `error`.

Licença MIT.
