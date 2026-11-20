# Linguagens: instalar e equivalências

Os SDKs oficiais ficam em `https://github.com/perata-sh/sdk`. São gerados do mesmo contrato, têm a mesma versão e fazem a mesma coisa em cada linguagem: só o nome muda para o jeito de cada uma. Quase não têm dependências (só Dart e Rust usam pacotes de terceiros, os que a própria linguagem recomenda).

## 1. Pacote, registro e instalação

| Linguagem | Pacote (registro) | Instalar | Requisito |
|---|---|---|---|
| Go | `github.com/perata-sh/sdk/go` (Go modules) | `go get github.com/perata-sh/sdk/go@latest` | Go 1.23+ |
| TypeScript / JavaScript | `@perata-sh/sdk` (npm) | **ainda sem a versão atual**, veja a seção 3 | Node 20.3+, Deno, Bun |
| Python | `perata-sdk` (PyPI) | `pip install perata-sdk` | Python 3.11+ |
| PHP | `perata-sh/sdk` (Packagist) | `composer require perata-sh/sdk` | PHP 8.1+, extensões `curl` e `json` |
| Ruby | `perata-sdk` (RubyGems) | `gem install perata-sdk` | Ruby 3.1+ |
| Java / Kotlin | `sh.perata:sdk` (Maven Central) | Maven: `<dependency><groupId>sh.perata</groupId><artifactId>sdk</artifactId><version>0.5.6</version></dependency>`; Gradle: `implementation("sh.perata:sdk:0.5.6")` | Java 11+ |
| C# / .NET | `PerataSh.Sdk` (NuGet) | **ainda não publicado**, veja a seção 3 | .NET 8+ |
| Elixir | `perata_sdk` (Hex) | em `mix.exs`: `{:perata_sdk, "~> 0.5.6"}` | Elixir 1.18+ |
| Dart / Flutter | `perata_sdk` (pub.dev) | `dart pub add perata_sdk` ou `flutter pub add perata_sdk` | Dart 3.8+ |
| Rust | `perata-sdk` (crates.io) | `cargo add perata-sdk` (no código: `use perata::...`) | Rust 1.88+ |
| Swift | repositório `https://github.com/perata-sh/sdk` (Swift Package Manager) | em `Package.swift`: `.package(url: "https://github.com/perata-sh/sdk", from: "0.5.6")` e, no alvo, `.product(name: "Perata", package: "sdk")` | Swift 6; macOS 12+, iOS 15+ |

As versões dos exemplos (`0.5.6`) são a última publicada em 19/11/2026. Confira no registro antes de fixar uma versão e troque pela mais nova. Os SDKs de servidor nunca vão para o navegador nem para um app: a chave de API não pode sair do servidor (Dart e Swift também só no servidor).

Para o navegador há o script `https://perata.sh/v1/perata.js` (sem chave) e dois pacotes escritos à mão, `@perata-sh/js` e `@perata-sh/react`, que **ainda não foram publicados** (os nomes são propostas). Enquanto isso, use a tag `<script>` do `perata.js`.

## 2. Versão do SDK: o que cada uma traz

Última publicada em 19/11/2026: **0.5.6** (Go, PyPI, RubyGems, Hex, pub.dev, Packagist, crates.io, Maven Central). A 0.5.5 não foi publicada sozinha: o que ela trazia saiu junto na 0.5.6. A **0.5.7** já está no ramo `develop` de `perata-sh/sdk` e ainda não foi publicada nos registros: até sair, o que ela traz (última linha da tabela) vale pela API REST. Se a versão instalada não tem um recurso, atualize; se a atualização ainda não saiu, chame a rota pela API REST.

| Recurso | A partir de |
|---|---|
| `usage.ingest` (ingestão de consumo) | 0.4.0 |
| `checkouts.create` com `amount_cents`, `items`, `client_reference_id`, `metadata`, `expires_in`; `checkouts.expire`; filtros `client_reference_id`, `status`, `customer_id`, `external_customer_id`, `created_after`, `created_before`, `sorting`; dados do cliente (CPF/CNPJ, telefone, endereço); sessão do portal | 0.5.2 |
| `message` no erro 422 mostrado no texto do erro; `environment` no envelope do webhook; `order.refunded` com `refund_id`; `WebhookOrder` nos eventos `order.*` | 0.5.3 |
| `interval_count` nos preços; assinatura `suspended`, `subscriptions.resume`, `payment_failure`; `kind` e demais campos de disputa; ciclo (`subscription_id`, `cycle_sequence`, `period_start`, `period_end`) nos eventos de venda | 0.5.4 |
| filtro `metadata` nas listas de checkouts, pedidos, pagamentos e assinaturas; filtro `email` em clientes | 0.5.5 |
| `subscription_start_at` e `discount_id` no checkout; `order_id`, `metadata` e `amount_cents` opcional no reembolso; `refunds.get`; `refund_metadata`; filtro `subscription_id`; `subscription_id` e ciclo em Order e Payment; `showcase.get` e `showcase_id` nos objetos e no envelope do webhook; `failure_reason` e `failure_code` nos eventos `refund.*` | 0.5.6 |
| `pricing_model`, `tiers`, `unit_amount_cents`, `unit_label(_plural)`, `minimum_units` e `maximum_units` no preço (criação e resposta), com `amount_cents` opcional na criação (preço graduated, por unidade, por assento, por volume); `interval` `day` e `week`; `quantity` e `client_reference_id` em `Subscription` e `subscription.*`; `charged_by` no recibo | 0.5.7 (na `develop`, ainda não publicada) |

Para uma versão mais velha, a API REST aceita tudo desde já (os nomes dos campos são os do contrato).

## 3. Sem npm ou NuGet: o contorno

O npm tem só a versão antiga `0.2.0` do `@perata-sh/sdk`, sem checkout com valor, encerrar, filtros nem os eventos tipados. O NuGet não tem `PerataSh.Sdk`. Não use a versão antiga. O caminho oficial até a publicação é a **API REST**, que é pequena: JSON sobre HTTPS.

```ts
// TypeScript, sem SDK: criar um checkout pela API REST
const resposta = await fetch("https://perata.sh/api/v1/checkouts", {
  method: "POST",
  headers: {
    Authorization: `Bearer ${process.env.PERATA_API_KEY}`,
    "Content-Type": "application/json",
    "Idempotency-Key": "pedido-123-50508-2026-12-01",
  },
  body: JSON.stringify({
    product_id, price_id, amount_cents: 50508,
    items: [{ name: "Pedido 123", quantity: 1, unit_amount_cents: 50508 }],
    client_reference_id: "pedido-123",
  }),
});
const corpo = await resposta.json();
if (!resposta.ok) throw new Error(`${resposta.status} ${corpo.error}: ${corpo.message}`);
const checkout = corpo.data; // checkout.url, checkout.id, checkout.session_id, checkout.client_secret
```

```csharp
// C#, sem SDK
using var http = new HttpClient { BaseAddress = new Uri("https://perata.sh") };
http.DefaultRequestHeaders.Authorization = new("Bearer", Environment.GetEnvironmentVariable("PERATA_API_KEY"));
var pedido = new HttpRequestMessage(HttpMethod.Post, "/api/v1/checkouts")
{
    Content = JsonContent.Create(new { product_id, price_id, amount_cents = 50508, client_reference_id = "pedido-123" }),
};
pedido.Headers.Add("Idempotency-Key", "pedido-123-50508-2026-12-01");
var resposta = await http.SendAsync(pedido); // 201 com {"data": {...}}; erro: {"error","message","fields"}
```

Como não há SDK, **a verificação do webhook também é à mão**. É o padrão Standard Webhooks, e sem verificar a assinatura qualquer um poderia fingir um pagamento. Algoritmo: o segredo `whsec_...` é `whsec_` mais uma chave em base64; calcule HMAC-SHA256 de `"{webhook-id}.{webhook-timestamp}.{corpo cru}"`; o cabeçalho `webhook-signature` traz uma ou mais assinaturas separadas por espaço, cada uma `v1,<base64>`; basta uma conferir; recuse se o `webhook-timestamp` estiver a mais de 5 minutos de agora.

```ts
import { createHmac, timingSafeEqual } from "node:crypto";

export function verificarWebhook(segredo: string, h: Headers, corpo: string): void {
  const id = h.get("webhook-id") ?? "";
  const ts = h.get("webhook-timestamp") ?? "";
  if (!id || !/^\d+$/.test(ts) || Math.abs(Date.now() / 1000 - Number(ts)) > 300) {
    throw new Error("webhook sem cabeçalho ou fora do prazo");
  }
  const chave = Buffer.from(segredo.replace(/^whsec_/, ""), "base64");
  const esperado = createHmac("sha256", chave).update(`${id}.${ts}.${corpo}`).digest();
  const confere = (h.get("webhook-signature") ?? "").split(" ").some((s) => {
    const [versao, b64] = s.split(",");
    if (versao !== "v1" || !b64) return false;
    const dado = Buffer.from(b64, "base64");
    return dado.length === esperado.length && timingSafeEqual(dado, esperado);
  });
  if (!confere) throw new Error("assinatura inválida");
}
```

```csharp
static bool Verificar(string segredo, string id, string ts, string assinaturas, string corpo)
{
    if (!long.TryParse(ts, out var s) || Math.Abs(DateTimeOffset.UtcNow.ToUnixTimeSeconds() - s) > 300) return false;
    var chave = Convert.FromBase64String(segredo.StartsWith("whsec_") ? segredo[6..] : segredo);
    using var hmac = new HMACSHA256(chave);
    var esperado = hmac.ComputeHash(Encoding.UTF8.GetBytes($"{id}.{ts}.{corpo}"));
    foreach (var parte in assinaturas.Split(' ', StringSplitOptions.RemoveEmptyEntries))
    {
        var p = parte.Split(',', 2);
        try
        {
            if (p.Length == 2 && p[0] == "v1" && CryptographicOperations.FixedTimeEquals(Convert.FromBase64String(p[1]), esperado)) return true;
        }
        catch (FormatException) { }
    }
    return false;
}
```

Uma alternativa não oficial, que só vale com o aval do dono do projeto: copiar a pasta `typescript/` (ou `csharp/`) do repositório `perata-sh/sdk`, licença MIT, para dentro do projeto. Registre no código de onde veio e de qual versão, e troque pelo pacote quando ele sair.

## 4. Tabela de equivalência

### Cliente, escrita com idempotência e erro

| Linguagem | Criar o cliente | Chave de idempotência numa escrita | Erro da API |
|---|---|---|---|
| Go | `client := perata.New(key)` | último argumento `perata.WithIdempotencyKey(k)` | `*perata.Error` (`StatusCode`, `Code`, `Message`, `Fields`, `Record`, `RetryAfter`); use `errors.As` |
| TypeScript | `new Perata({ apiKey })` | `{ idempotencyKey }` no último argumento | `PerataError` (`status`, `code`, `message`, `fields`, `retryAfter`, `record`) |
| Python | `Perata(key)` | `idempotency_key="..."` | `PerataError` (`status`, `code`, `message`, `fields`, `retry_after`, `record`) |
| PHP | `new Perata\Perata($key)` | `idempotencyKey: '...'` | `Perata\PerataException` (`status`, `errorCode`, `fields`, `record`, `retryAfter`) |
| Ruby | `Perata::Client.new(key)` | `idempotency_key: "..."` | `Perata::Error` (`status`, `code`, `message`, `fields`, `record`, `retry_after`) |
| Java | `new Perata(key)` | `RequestOptions.builder().idempotencyKey(k).build()` | `PerataException` (`getStatus`, `getCode`, `getApiMessage`, `getFields`, `getRecord`, `getRetryAfter`) |
| C# | `new PerataClient(key)` | `new RequestOptions { IdempotencyKey = k }` | `PerataException` (`Status`, `Code`, `ApiMessage`, `Fields`, `Record`, `RetryAfter`) |
| Elixir | `Perata.new(key)` | `idempotency_key: k` | `{:error, %Perata.Error{}}` (`status`, `code`, `message`, `fields`, `record`, `retry_after`) |
| Dart | `Perata(key)` | `idempotencyKey: k` | `PerataException` (`status`, `code`, `message`, `fields`, `record`, `retryAfter`) |
| Rust | `Client::new(key)` | `.idempotency_key(k)` antes da chamada | `Error::Api(ApiError)` (`status`, `code`, `message`, `fields`, `record`, `retry_after`) |
| Swift | `PerataClient(apiKey: key)` | `idempotencyKey: k` | `PerataError` (`status`, `code`, `message`, `fields`, `record`, `retryAfter`) |

Nenhum SDK repete uma chamada sozinho depois de um erro ou de um 429. Quem repete é o seu código, com a mesma `Idempotency-Key`.

### Operações

| Linguagem | Criar checkout | Encerrar checkout | Reembolsar | Listar pedidos filtrados | Percorrer todas as páginas |
|---|---|---|---|---|---|
| Go | `client.Checkouts.Create(ctx, perata.CheckoutsCreateParams{...})` | `client.Checkouts.Expire(ctx, id)` | `client.Refunds.Create(ctx, perata.RefundsCreateParams{...})` | `client.Orders.List(ctx, &perata.OrdersListParams{ClientReferenceID: "x"})` | `ListIter` (`for v, err := range ...`) |
| TypeScript | `perata.checkouts.create({...})` | `perata.checkouts.expire(id)` | `perata.refunds.create({...})` | `perata.orders.list({ client_reference_id: "x" })` | `listIter` (`for await`) |
| Python | `perata.checkouts.create({...})` | `perata.checkouts.expire(id)` | `perata.refunds.create({...})` | `perata.orders.list(client_reference_id="x")` | `list_iter` |
| PHP | `$perata->checkouts->create([...])` | `$perata->checkouts->expire($id)` | `$perata->refunds->create([...])` | `$perata->orders->list(['client_reference_id' => 'x'])` | `listIter` (gerador) |
| Ruby | `perata.checkouts.create({...})` | `perata.checkouts.expire(id)` | `perata.refunds.create({...})` | `perata.orders.list(client_reference_id: "x")` | `list_iter.each` |
| Java | `perata.checkouts().create(CheckoutsService.CreateParams.builder()...build())` | `perata.checkouts().expire(id)` | `perata.refunds().create(RefundsService.CreateParams.builder()...build())` | `perata.orders().list(OrdersService.ListParams.builder().clientReferenceId("x").build())` | `listIter` (`Iterable`) |
| C# | `await perata.Checkouts.CreateAsync(new CheckoutsCreateParams {...})` | `await perata.Checkouts.ExpireAsync(id)` | `await perata.Refunds.CreateAsync(new RefundsCreateParams {...})` | `await perata.Orders.ListAsync(new OrdersListParams { ClientReferenceId = "x" })` | `ListIterAsync` (`await foreach`) |
| Elixir | `Perata.Checkouts.create(client, %{...})` | `Perata.Checkouts.expire(client, id)` | `Perata.Refunds.create(client, %{...})` | `Perata.Orders.list(client, client_reference_id: "x")` | `list_stream` |
| Dart | `perata.checkouts.create(CheckoutsCreateParams(...))` | `perata.checkouts.expire(id)` | `perata.refunds.create(RefundsCreateParams(...))` | `perata.orders.list(clientReferenceId: 'x')` | `listIter` (`await for`) |
| Rust | `client.checkouts().create(&CheckoutsCreateParams::new(price_id, product_id)...)` | `client.checkouts().expire(id)` | `client.refunds().create(&RefundsCreateParams::new()...)` | `client.orders().list(&OrdersListParams::new().client_reference_id("x"))` | `list_iter` (`Iterator`) |
| Swift | `perata.checkouts.create(CheckoutsCreateParams(priceID:productID:))` | `perata.checkouts.expire(id)` | `perata.refunds.create(RefundsCreateParams(...))` | `perata.orders.list(clientReferenceID: "x")` | `listIter` (`for try await`) |

Atenção a duas pegadinhas de ordem: em Rust, `CheckoutsCreateParams::new(price_id, product_id)` pede o **preço primeiro**; em Swift o inicializador é `priceID:` e depois `productID:`. Em Go, TypeScript, Python e as demais, os campos opcionais (`amount_cents`, `items`, ...) ficam fora quando não enviados: em Go são ponteiros (`*int64`, `*string`), por isso o ajudante `func ptr[T any](v T) *T { return &v }`.

### Webhook

| Linguagem | Verificar e ler o evento | Falha de assinatura |
|---|---|---|
| Go | `perata.VerifyWebhook(secret, r.Header, body)` | erro `perata.ErrWebhookSignature` |
| TypeScript | `await verifyWebhook(secret, request.headers, await request.text())` | `WebhookVerificationError` |
| Python | `verify_webhook(secret, request.headers, request.get_data())` | `WebhookVerificationError` |
| PHP | `Perata\Webhook::verify($secret, getallheaders(), file_get_contents('php://input'))` | exceção |
| Ruby | `Perata.verify_webhook(secret, request.headers, request.raw_post)` | exceção |
| Java | `Webhook.verify(secret, headers, body)` | exceção |
| C# | `Webhook.Verify(secret, Request.Headers, body)` | exceção |
| Elixir | `Perata.verify_webhook(secret, conn.req_headers, raw_body)` devolve `{:ok, event}` | `{:error, _}` |
| Dart | `verifyWebhook(secret, request.headers, body)` | exceção |
| Rust | `perata::verify_webhook(&secret, &headers, &body)?` | `Err` |
| Swift | `try verifyWebhook(secret:headers:body:)` | `throws` |

Em todas, passe o **corpo cru**, exatamente como chegou, antes de ler o JSON. O evento volta tipado pelo grupo do `type` (pedido, assinatura, venda, disputa...); um tipo que a versão do SDK não conhece chega como "desconhecido", com o JSON como veio (`UnknownWebhookEvent`). O resto do assunto está em `webhooks.md`.

### Nomes dos campos

TypeScript, Python, Ruby e Elixir usam os nomes do contrato (`client_reference_id`) tanto no que se envia quanto no que se lê. As outras traduzem para o estilo da linguagem: Go `ClientReferenceID`, C# `ClientReferenceId`, Dart `clientReferenceId`, Swift `clientReferenceID`, Java `getClientReferenceId()` e PHP `$order->clientReferenceId`. O JSON que vai e volta da API é sempre o do contrato. Em dúvida, abra o `README.md` da linguagem em `perata-sh/sdk` ou o contrato.
