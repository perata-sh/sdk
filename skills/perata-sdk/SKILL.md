---
name: perata-sdk
description: Ensina a integrar a Peráta (perata.sh), a plataforma brasileira de cobrança (cartão de crédito, débito com 3DS e Pix), usando os SDKs oficiais (Go, TypeScript, Python, PHP, Ruby, Java, C#, Elixir, Dart, Rust e Swift) ou a API REST. Use quando o pedido for cobrar um cliente, criar checkout ou link de pagamento, vender produto ou assinatura, cobrar por consumo, devolver dinheiro (reembolso), tratar chargeback ou MED, receber webhook da Peráta, usar chave prk_test_ ou prk_live_, ou levar uma integração da Peráta para Produção. Cobre catálogo, clientes, checkout (página, modal, componentes e transparente), pedidos, assinaturas, uso, webhooks e erros.
---

# Integrar a Peráta

Esta skill leva um agente do zero até uma integração completa e em Produção com a Peráta. Este arquivo é o índice e os passos essenciais; cada assunto tem o seu detalhe em `referencias/`.

Fale com o dono do projeto em português simples, sem jargão. Quando um termo técnico for inevitável (webhook, idempotência, 3DS), explique em uma frase. Pergunte só o que falta: a linguagem do projeto, se a venda é avulsa ou por assinatura, e se o valor é de um preço fixo ou calculado pelo sistema dele.

## Quando usar

Use quando o trabalho envolve dinheiro entrando pela Peráta: criar a cobrança de um pedido, vender uma assinatura, receber o aviso de pagamento, devolver um valor, achar um pagamento, cobrar por consumo, ou publicar tudo isso em Produção.

Não use para outro meio de pagamento (Stripe, Mercado Pago, Pagar.me) nem para mexer no painel da Peráta em si. Para algo que não está nesta skill, a fonte da verdade é o contrato da API: `https://perata.sh/documentacao/openapi.json` (e `https://perata.sh/llms-full.txt`). Nunca invente nome de campo, rota ou evento: se não estiver no contrato, diga ao dono que não existe e proponha o que fazer sem ele.

## O que é a Peráta

- Cobra e recebe em split, no Brasil: cartão de crédito (à vista ou parcelado), cartão de débito com autenticação 3DS e Pix. Existem ainda o boleto (se a conta o aceita) e a carteira do aparelho, Google Pay e Apple Pay (se ligada para o site).
- Dois ambientes: **Teste** (nada é cobrado de ninguém) e **Produção** (dinheiro real, só depois que a equipe da Peráta verifica e aprova o vendedor). Os dados de um não aparecem no outro: produtos, preços, clientes, webhooks e chaves são de cada ambiente.
- A **chave de API** (no painel se chama "token de acesso") define tudo: `prk_test_...` opera o Teste, `prk_live_...` opera a Produção. A organização, o ambiente e o showcase vêm da chave, nunca da requisição. Vai em `Authorization: Bearer`, só no servidor.
- O **showcase** é uma plataforma da empresa (uma organização pode ter vários). A chave nasce dentro de um showcase e só alcança o que é dele; o webhook também é de um showcase só. Hoje a maioria das organizações tem um só.
- Cada chave leva **escopos** (por exemplo `checkouts:write`, `orders:read`). Rota sem o escopo da chave dá 403 dizendo qual falta. Lista em `referencias/conceitos.md`.
- Valores são sempre em **centavos inteiros** (R$ 505,08 = `50508`), moeda BRL.

## Regras que valem sempre

1. A chave de API fica só no servidor, em variável de ambiente. Ao navegador vai só o `url` do checkout ou o `client_secret` da sessão.
2. O servidor decide o valor (`amount_cents` e `items`). Nunca confie em valor vindo do navegador.
3. Um pagamento só vale pelo webhook `order.paid`, nunca pela volta do comprador à `success_url`.
4. Envie sempre `client_reference_id` (o id do pedido no seu sistema): é a chave para achar o pedido de volta.
5. Em toda escrita que mexe com dinheiro, passe a sua própria `Idempotency-Key`. Os SDKs mandam uma chave aleatória em todo POST, e uma chave aleatória não protege uma repetição.
6. Webhook: confira a assinatura com o corpo cru, grave o `webhook-id` (cada aviso é processado uma vez), recuse o ambiente errado e responda 2xx depressa.
7. Se o valor do pedido muda antes do pagamento, encerre o checkout velho (`expire`) e abra outro. Nunca reenvie o link antigo.
8. Teste tudo no ambiente Teste antes da Produção. O agente nunca faz um pagamento real: o primeiro é do dono, num valor baixo.
9. Nunca imprima, registre nem comite chave `prk_`, `pus_` ou segredo `whsec_`.
10. Uma recusa 4xx diz o motivo em `message` e `fields`: leia e corrija o pedido, não tente de novo às cegas.

## Roteiro essencial

1. **Instalar o SDK da linguagem** e criar o cliente com a chave de Teste. O NuGet (C#) ainda não tem o pacote publicado: veja `referencias/linguagens.md` para o contorno (API REST). Versão do SDK e recurso novo também estão lá.
2. **Montar o catálogo** (produto e preço) no Teste. Preço de valor livre (para cobrar um valor que o seu sistema calcula) só se cria no painel. Detalhes em `referencias/catalogo.md`.
3. **Guardar o cliente** (opcional, mas recomendado): `external_id` com o id dele no seu sistema, CPF/CNPJ e endereço. Em `referencias/clientes.md`.
4. **Criar o checkout** no servidor e mandar o comprador para o `url` (ou montar a tela com o Peráta.js). Em `referencias/checkout.md`.
5. **Receber o webhook** `order.paid` e liberar o que foi vendido. Em `referencias/webhooks.md`.
6. **Tratar o depois**: reembolso, disputa, conferência diária. Em `referencias/pos-venda.md`.
7. **Se for assinatura**: preço recorrente, renovação, falha de cartão, suspensão. Em `referencias/assinaturas.md`. Se for cobrança por consumo: `referencias/uso.md`.
8. **Ir para Produção** com a lista de `referencias/producao.md`.

Exemplo mínimo em Go (criar a cobrança de um pedido e guardar o que a resposta traz):

```go
client := perata.New(os.Getenv("PERATA_API_KEY")) // prk_test_... no Teste

checkout, err := client.Checkouts.Create(ctx, perata.CheckoutsCreateParams{
	ProductID:         productID,
	PriceID:           priceID, // preço de valor livre
	AmountCents:       ptr(int64(50508)),
	Items:             []perata.CheckoutsCreateItem{{Name: "Pedido 123", UnitAmountCents: 50508}},
	ClientReferenceID: ptr("pedido-123"),
	SuccessURL:        ptr("https://loja.exemplo/obrigado"),
}, perata.WithIdempotencyKey("pedido-123-50508-2026-12-01"))
if err != nil {
	return err
}
// Guarde checkout.ID, checkout.SessionID e checkout.StatusKey no pedido.
// Mande o comprador para checkout.URL.

func ptr[T any](v T) *T { return &v }
```

Em TypeScript e Python é a mesma chamada: `perata.checkouts.create({ product_id, price_id, amount_cents, items, client_reference_id }, { idempotencyKey })` e `perata.checkouts.create({...}, idempotency_key="...")`. As demais linguagens estão na tabela de `referencias/linguagens.md`.

## Mapa das referências

| Quando você precisa de | Abra |
|---|---|
| Ambientes, chaves, escopos, showcase, ids, formatos | `referencias/conceitos.md` |
| Instalar, nome do pacote por registro, tabela das 11 linguagens, versão do SDK, sem NuGet | `referencias/linguagens.md` |
| Produtos, preços (fixo, valor livre, recorrente), descontos, benefícios | `referencias/catalogo.md` |
| Clientes, CPF/CNPJ, `external_id`, portal do cliente | `referencias/clientes.md` |
| Checkout em todos os modos, `amount_cents` e `items`, Pix, encerrar, sites permitidos | `referencias/checkout.md` |
| Pedidos, pagamentos, reembolsos, disputas, conferência | `referencias/pos-venda.md` |
| Assinatura: criar, renovar, falhar, suspender, trocar preço | `referencias/assinaturas.md` |
| Medidores e `usage.ingest` | `referencias/uso.md` |
| Webhooks: envelope, verificação por linguagem, eventos, idempotência | `referencias/webhooks.md` |
| Formato de erro, `Idempotency-Key`, filtros, paginação, 429 | `referencias/erros-e-cuidados.md` |
| Lista para ir a Produção | `referencias/producao.md` |
| Erros que já aconteceram de verdade (alpr.sh) | `referencias/erros-comuns.md` |

## Ao terminar uma integração

Entregue ao dono, em português: o que foi feito, o que testou no ambiente Teste (cartão aprovado, cartão recusado, Pix, valor que muda, webhook repetido, estorno), o que falta para a Produção e quem faz cada passo. Antes de dizer que terminou, confira a lista de `referencias/producao.md`.
