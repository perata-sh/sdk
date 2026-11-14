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
| Componentes prontos | O formulário da Peráta dentro da sua página (cartão, Pix e boleto), que confirma sozinho | `perata.components.payment({ clientSecret })` |
| Transparente | Você desenha o formulário; só os campos do cartão ficam num quadro seguro da Peráta | `perata.components.card(...)` e `perata.confirmPayment(...)` |

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

O `client_secret` identifica só aquela sessão e pode ir ao navegador. Ele é um campo novo da resposta de `POST /api/v1/checkouts` e ainda não consta do `openapi.json` desta versão do SDK, então o tipo `Checkout` do SDK de servidor só o terá depois da próxima sincronização do contrato.

### No navegador

```ts
import { loadPerata } from "@perata-sh/js";

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
perata.openCheckout({
  url,
  theme: "dark", // "light" | "dark"
  onSuccess: ({ successURL }) => console.log("pago", successURL),
  onClose: () => console.log("o comprador fechou"),
});
```

**3. Componentes prontos**

```ts
const payment = perata.components.payment({
  clientSecret,
  appearance: { theme: "light" },
  locale: "pt-BR",
  onSuccess: (result) => {
    // result.status, result.orderId, result.paymentId
    // Pix e boleto: result.pix.copyPaste, result.boleto.digitableLine…
  },
  onError: (error) => console.error(error.code, error.message),
});
payment.mount("#pagamento"); // um seletor ou um elemento
// payment.update({ appearance: { theme: "dark" } });
// payment.unmount();
```

**4. Transparente**: o número do cartão é digitado em um `iframe` da Peráta e nunca passa pela sua página; o resto do formulário é seu.

```ts
const card = perata.components.card({
  clientSecret,
  onChange: ({ complete, brand, last4, error }) => {
    botao.disabled = !complete;
  },
});
card.mount("#cartao");

const parcelas = await perata.getInstallments({ clientSecret }); // [{ installments: 1, … }, …]

botao.addEventListener("click", async () => {
  const result = await perata.confirmPayment({
    clientSecret,
    card,
    method: "card", // "card" | "pix" | "boleto"; "card" por padrão
    installments: 3,
    customer: { name: "Maria Souza", email: "maria@exemplo.com" },
  });
  if (result.error) return mostrar(result.error.message); // recusa não é exceção
  if (result.pix) mostrarQrCode(result.pix.qrCodeImage, result.pix.copyPaste, result.pix.expiresAt);
  if (result.boleto) mostrarBoleto(result.boleto.digitableLine, result.boleto.pdfUrl, result.boleto.dueDate);
});
```

Para Pix e boleto não há campo de cartão: `perata.confirmPayment({ clientSecret, method: "pix" })`.

## `loadPerata(opções?)`

Devolve `Promise<PerataInstance | null>`. É chamada quantas vezes for preciso: o script é injetado uma vez e a instância é compartilhada. No servidor devolve `null`. Se `window.Perata` já existir (você pôs a tag `<script>` à mão), usa essa e não injeta nada.

| Opção | Para que serve |
|---|---|
| `scriptUrl` | Outro endereço do script (sandbox, servidor local). Precisa ser `https`; `http` só para `localhost`, `127.0.0.0/8` e `::1`. O checkout abre na Peráta que serviu o script. Padrão: `https://perata.sh/v1/perata.js` (`PERATA_SCRIPT_URL`). |
| `nonce` | O nonce da sua Content-Security-Policy para a tag do script. |
| `timeoutMs` | Quanto esperar antes de desistir; 15 000 por padrão. |

Falhas rejeitam com `PerataLoadError`, cujo `code` é `invalid_url`, `network`, `timeout` ou `missing_global`. Uma falha é esquecida: chamar de novo tenta outra vez.

Se o seu site usa Content-Security-Policy, libere a origem do `perata.js` em `script-src` e em `frame-src`.

## Tipos

Todo o contrato está tipado e exportado: `PerataInstance`, `PaymentResult`, `PixResult`, `BoletoResult`, `InstallmentOption`, `ConfirmPaymentParams`, `PaymentComponent`, `CardComponent`, `ChangeEvent`, `Appearance`, `CheckoutSuccessEvent` e os demais. `window.Perata` também ganha tipo.

Os componentes têm `mount(alvo)`, `unmount()`, `update({ appearance })` e `on(evento, função)`. Eventos: `ready`, `change` (`{ complete, brand, last4, error }`), `success` e `error`.

Licença MIT.
