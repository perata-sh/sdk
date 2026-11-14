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

O `client_secret` é um campo novo da resposta de `POST /api/v1/checkouts` e ainda não consta do `openapi.json` desta versão do SDK de servidor; o `url` já existe.

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
| `instance` | Uma instância (ou promessa de `loadPerata()`) que você já tem; nada é carregado. Útil em testes. |

Hooks: `usePerata()` devolve a instância, ou `null` enquanto carrega e no servidor; `usePerataStatus()` devolve `{ status: "loading" | "ready" | "error", error }`; `useConfirmPayment()` devolve `confirmPayment` e `getInstallments` já ligados à instância, para um formulário seu (Pix e boleto não têm campo de cartão).

## Os quatro modos

**1. Redirecionamento** e **2. Modal**: `CheckoutButton`. Fica desabilitado até o script carregar.

```tsx
import { CheckoutButton } from "@perata-sh/react";

<CheckoutButton url={url}>Comprar</CheckoutButton>                    {/* redireciona */}
<CheckoutButton url={url} mode="modal" theme="dark"
  onSuccess={({ successURL }) => console.log("pago", successURL)}
  onClose={() => console.log("fechou")}>Comprar</CheckoutButton>      {/* modal */}
```

Aceita as propriedades de um `<button>` (`className`, `onClick`…); `mode` é `"redirect"` por padrão.

**3. Componentes prontos**: `PaymentComponent` desenha cartão, Pix e boleto e confirma sozinho.

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

Um `clientSecret` novo remonta o componente; mudar `appearance` só atualiza o visual, sem perder o que o comprador digitou. As funções `onReady`, `onChange`, `onSuccess` e `onError` podem mudar a cada renderização sem remontar nada.

**4. Transparente**: `CardField` desenha só os campos do cartão, num quadro seguro da Peráta (os números não passam pela sua página). O resto do formulário é seu, e você confirma com um `ref`.

```tsx
import { CardField, type CardFieldHandle } from "@perata-sh/react";
import { useRef, useState } from "react";

function Pagamento({ clientSecret }: { clientSecret: string }) {
  const card = useRef<CardFieldHandle>(null);
  const [completo, setCompleto] = useState(false);

  async function pagar() {
    const parcelas = await card.current!.getInstallments(); // [{ installments: 1, … }, …]
    const result = await card.current!.confirmPayment({
      installments: parcelas.at(-1)?.installments ?? 1,
      customer: { name: "Maria Souza", email: "maria@exemplo.com" },
    });
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

O `ref` entrega `confirmPayment(params?)`, `getInstallments()` e `component` (o componente de cartão, para quem chama `perata.confirmPayment({ card })` direto). Para Pix e boleto, use `useConfirmPayment()`:

```tsx
const { confirmPayment } = useConfirmPayment();
const result = await confirmPayment({ clientSecret, method: "pix" });
// result.pix: { qrCode, qrCodeImage, copyPaste, expiresAt }
```

## Next.js e SSR

Todos os módulos trazem `"use client"`, então podem ser importados de Server Components; o provedor e os componentes é que rodam no navegador. No servidor eles renderizam um `<div>` vazio (e um botão desabilitado), e o script só é pedido depois da hidratação.

Se o seu site usa Content-Security-Policy, libere a origem do `perata.js` em `script-src` e em `frame-src` e passe `nonce` ao provedor.

Licença MIT.
