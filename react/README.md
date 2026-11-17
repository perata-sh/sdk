# Peráta para React (`@perata-sh/react`)

Componentes e hooks de React para o checkout da Peráta, como `@stripe/react-stripe-js` e o SDK React do Mercado Pago: um provedor que carrega o Peráta.js, o formulário pronto, o campo de cartão e o botão de checkout. React 18 ou 19, seguro para SSR (Next.js, Remix): nada toca `window` no servidor.

> Estado: o nome do pacote é uma proposta e ainda não foi publicado. Apague este aviso quando o nome for confirmado e o pacote sair.

```sh
npm install @perata-sh/react @perata-sh/js
```

`@perata-sh/js` é peer dependency: é ele que carrega o script e traz os tipos (`PaymentResult`, `ChangeEvent`…), e o seu app e este pacote compartilham uma só cópia.

## O servidor cria a sessão

A chave de API fica no servidor. Ele cria o checkout com o [SDK de servidor](../typescript) e entrega ao navegador o `url` ou o `client_secret`:

```ts
// app/api/checkout/route.ts (Next.js)
import { Perata } from "@perata-sh/sdk";

const perata = new Perata({ apiKey: process.env.PERATA_API_KEY! }); // prk_test_… ou prk_live_…

export async function POST() {
  const checkout = await perata.checkouts.create(
    { product_id: "prod_…", price_id: "price_…", success_url: "https://loja.exemplo/obrigado" },
    { idempotencyKey: crypto.randomUUID() },
  );
  return Response.json({ url: checkout.url, clientSecret: checkout.client_secret });
}
```

O `client_secret` vem na resposta de `POST /api/v1/checkouts` (o tipo `CheckoutCreated`, no SDK de servidor desta versão), e só nela: na repetição de uma criação com a mesma `Idempotency-Key` ele vem vazio. Entregue-o ao navegador na primeira resposta.

## O provedor

Ponha `PerataProvider` uma vez, acima de tudo que usa a Peráta. Ele pede o script num efeito, então não faz nada no servidor.

```tsx
"use client";
import { PerataProvider } from "@perata-sh/react";

export function Providers({ children }: { children: React.ReactNode }) {
  return <PerataProvider>{children}</PerataProvider>;
}
```

| Propriedade | Para que serve |
|---|---|
| `scriptUrl` | Outro endereço do script, para sandbox ou servidor local (`https`; `http` só para localhost). |
| `nonce` | O nonce da sua Content-Security-Policy. |
| `timeoutMs` | Quanto esperar o script; 15 000 por padrão. |
| `pin` | Fixa uma versão do script, com o hash e o valor de integridade (SRI) dela: `pin={{ hash: "0123456789abcdef", integrity: "sha384-…" }}`. Veja o README do `@perata-sh/js`. |
| `instance` | Uma instância (ou promessa de `loadPerata()`) que você já tem; nada é carregado. Útil em testes. |

Hooks: `usePerata()` devolve a instância, ou `null` enquanto carrega e no servidor; `usePerataStatus()` devolve `{ status: "loading" | "ready" | "error", error }` (o estado do *script*); `useConfirmPayment()` devolve `confirmPayment`, `getInstallments` e `getStatus` já ligados à instância, para um formulário seu; `usePaymentStatus()` acompanha um pagamento (veja "Pix e boleto").

## Os quatro modos

**1. Redirecionamento** e **2. Modal**: `CheckoutButton`. Fica desabilitado até o script carregar.

```tsx
import { CheckoutButton } from "@perata-sh/react";

<CheckoutButton url={url}>Comprar</CheckoutButton>                    {/* redireciona */}
<CheckoutButton url={url} mode="modal" theme="dark"
  onSuccess={({ successURL }) => console.log("pago", successURL)}
  onClose={() => console.log("fechou")}>Comprar</CheckoutButton>      {/* modal */}
```

Aceita as propriedades de um `<button>` (`className`, `onClick`…); `mode` é `"redirect"` por padrão. `onError` recebe o erro quando o `url` não é um link de checkout da Peráta (`invalid_checkout_url`) ou o modal não abre; sem `onError`, o erro sobe. No modal, `onSuccess` pode devolver `false` para você mesmo levar o comprador ao `success_url`.

**3. Componentes prontos**: `PaymentComponent` desenha as formas de pagamento da página da Peráta (carteira do aparelho, cartão, débito, Pix, boleto e cartões salvos) e confirma sozinho.

```tsx
import { PaymentComponent } from "@perata-sh/react";

<PaymentComponent
  clientSecret={clientSecret}
  appearance={{ theme: "light" }}
  locale="pt-BR"
  onSuccess={(result) => router.push(`/pedido/${result.orderId}`)}
  onError={(error) => setMensagem(error.message)}
/>
```

Um `clientSecret` novo remonta o componente; mudar `appearance` só atualiza o visual, sem perder o que o comprador digitou. As funções `onReady`, `onChange`, `onSuccess` e `onError` podem mudar a cada renderização sem remontar nada. `appearance` é `{ theme: "light" | "dark" | "auto", variables: { colorPrimary: "#rrggbb", borderRadius: "8", fontFamily: "display" | "system", fontSize: "sm" | "md" | "lg" } }`; `locale` por enquanto só aceita `"pt-BR"`. Um `ref` (`PaymentComponentHandle`) dá `focus()`, `getState()` e `component`.


**3b. Só a carteira, no seu layout**: `WalletComponent` desenha o botão do Google Pay ou do Apple Pay onde o navegador puder pagar com a carteira, e nada onde não puder.

```tsx
import { WalletComponent } from "@perata-sh/react";

<WalletComponent
  clientSecret={clientSecret}
  customer={{ email, document }}   // quem paga; mudar não remonta o botão
  onReady={(state) => console.log(state.available)} // ["google_pay"], ["apple_pay"] ou []
  onSuccess={(result) => {}}
  onCancel={() => {}}              // o comprador fechou a janela da carteira
  onError={(error) => console.error(error.code)} // customer_incomplete, wallet_unavailable, payment_declined…
/>
```

A carteira é paga pelo próprio botão; `useConfirmPayment` não confirma carteira.

**4. Transparente**: `CardField` desenha só os campos do cartão, num quadro seguro da Peráta (os números não passam pela sua página). O resto do formulário é seu, e você confirma com um `ref`.

```tsx
import { CardField, type CardFieldHandle } from "@perata-sh/react";
import { useRef, useState } from "react";

function Pagamento({ clientSecret }: { clientSecret: string }) {
  const card = useRef<CardFieldHandle>(null);
  const [completo, setCompleto] = useState(false);

  async function pagar() {
    const parcelas = await card.current!.getInstallments(); // [{ installments, installmentAmountCents, totalCents, interestCents, label }, …]
    const result = await card.current!.confirmPayment({
      installments: parcelas.at(-1)?.installments ?? 1,
      customer: { name: "Maria Souza", email: "maria@exemplo.com", document: "529.982.247-25" },
    });
    if (result.redirectUrl) return window.location.assign(result.redirectUrl); // desafio 3-D Secure
    if (result.error) return alert(result.error.message); // recusa não é exceção
  }

  return (
    <form onSubmit={(e) => { e.preventDefault(); void pagar(); }}>
      <CardField ref={card} clientSecret={clientSecret} onChange={(e) => setCompleto(e.complete)} />
      <button disabled={!completo}>Pagar</button>
    </form>
  );
}
```

O `ref` entrega `confirmPayment(params?)`, `getInstallments()`, `focus()`, `getState()` e `component` (o componente de cartão, para quem chama `perata.confirmPayment({ card })` direto). O `customer` aceita `name`, `email`, `document` (CPF ou CNPJ) e `address`; não há telefone.

## Pix e boleto

Não há campo de cartão: confirme com `useConfirmPayment()`. O resultado traz o `pix` (ou o `boleto`) e um `statusKey`; o `clientSecret` já está gasto, então é com o `statusKey` que se acompanha o pagamento. `usePaymentStatus` pergunta a cada `intervalMs` e para sozinho quando o estado é final (`succeeded`, `failed` ou `expired`) ou quando o componente sai da página.

```tsx
import { useConfirmPayment, usePaymentStatus } from "@perata-sh/react";
import type { PaymentResult } from "@perata-sh/js";
import { useState } from "react";

function PagarComPix({ clientSecret }: { clientSecret: string }) {
  const { confirmPayment } = useConfirmPayment();
  const [gerado, setGerado] = useState<PaymentResult | null>(null);
  const { result } = usePaymentStatus({ statusKey: gerado?.statusKey, intervalMs: 3000 });

  async function gerar() {
    const pix = await confirmPayment({ clientSecret, method: "pix", customer: { name: "Maria Souza", email: "maria@exemplo.com", document: "529.982.247-25" } });
    if (pix.error) return alert(pix.error.message);
    setGerado(pix);
  }

  if (result?.status === "succeeded") return <p>Pago! Pedido {result.orderId}.</p>;
  if (result?.status === "expired" || result?.status === "failed") return <p>{result.error?.message}</p>;
  if (gerado?.pix) {
    return (
      <div>
        <img src={gerado.pix.qrCodeImage} alt="QR code do Pix" />
        <input readOnly value={gerado.pix.copyPaste} />
        <p>Vale até {new Date(gerado.pix.expiresAt).toLocaleString("pt-BR")}. Aguardando o pagamento…</p>
      </div>
    );
  }
  return <button onClick={() => void gerar()}>Pagar com Pix</button>;
}
```

`usePaymentStatus({ statusKey, intervalMs?, enabled?, onResult? })` devolve `{ result, error, loading, done, refresh }`. Sem `intervalMs` ele pergunta uma vez (e de novo em `refresh()`); sem `statusKey` ou com `enabled: false` não pergunta nada. Um erro de rede não interrompe a espera; um `invalid_status_key` ou `http_4xx` (um 404, por exemplo) interrompe. Com boleto é igual, usando `gerado.boleto` (`digitableLine`, `barcode`, `pdfUrl`, `dueDate`).

## Next.js e SSR

Todos os módulos trazem `"use client"`, então podem ser importados de Server Components; o provedor e os componentes é que rodam no navegador. No servidor eles renderizam um `<div>` vazio (e um botão desabilitado), e o script só é pedido depois da hidratação.

Se o seu site usa Content-Security-Policy, libere a origem do `perata.js` em `script-src` e em `frame-src` e passe `nonce` ao provedor.

Licença MIT.
