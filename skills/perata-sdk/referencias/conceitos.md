# Conceitos: ambientes, chaves, escopos, showcase e ids

## Palavras que aparecem (para explicar ao dono do projeto)

| Palavra | Em uma frase |
|---|---|
| Checkout | a cobrança de um pedido: o endereço e a tela em que o cliente paga |
| Webhook | um aviso que a Peráta manda ao seu servidor quando algo acontece (um pagamento, um estorno) |
| Idempotência (`Idempotency-Key`) | uma etiqueta que faz repetir o mesmo pedido não gerar uma segunda cobrança |
| 3DS | a confirmação extra que o banco pede no cartão de débito |
| Split | a divisão do pagamento que a Cielo faz entre a Peráta e quem vende |
| Chargeback | o cliente contesta um pagamento de cartão com o banco dele |
| MED | a devolução que o banco de quem pagou pede num Pix contestado |
| Escopo | uma permissão da chave de API (ler pedidos, criar checkouts...) |
| Showcase | cada plataforma da empresa dentro da mesma organização |
| `client_secret` | a credencial de uma sessão de pagamento, segura para o navegador; não é a chave de API |
| Sandbox | o ambiente de testes da Cielo, por trás do ambiente Teste da Peráta |

## Ambientes: Teste e Produção

- **Teste**: o checkout, as assinaturas e a cobrança por uso funcionam sem cobrar ninguém. Sem vendedor de teste cadastrado, a venda vai para um recebedor simulado da Cielo (sandbox): o cartão de teste abaixo passa sem cadastrar conta bancária.
- **Produção**: dinheiro real. Só abre depois que a equipe da Peráta verifica e aprova o vendedor (a "verificação" e a conta de recebimento).
- O ambiente vem da chave, nunca de um campo da requisição. Não existe parâmetro `environment` para enviar.
- Cada ambiente tem o seu catálogo, os seus clientes, os seus endpoints de webhook e as suas chaves. O `product_id` e o `price_id` do Teste não existem em Produção: guarde um par por ambiente.
- Todo webhook diz em que ambiente aconteceu, no campo `environment` (`test` ou `live`).

Cartões de teste (sandbox da Cielo, valem só no ambiente Teste; validade no futuro, CVV 123):

| Cartão | Resultado |
|---|---|
| `5315281703921200` | aprovado |
| `4556839012717832` | recusado |

## Chaves

| Chave | Para que serve | Onde nasce |
|---|---|---|
| `prk_test_...` | chave de API da organização no Teste | painel, Configurações › Tokens de acesso |
| `prk_live_...` | a mesma, em Produção | idem, no ambiente Produção |
| `pus_test_...` / `pus_live_...` | credencial de uma fonte de ingestão de consumo (só `usage.ingest`) | painel, Configurações › Fontes de ingestão |
| `whsec_...` | segredo que assina os webhooks de um endpoint | aparece na criação do endpoint, só nela |

- A chave vai em `Authorization: Bearer prk_...`. Sem ela, ou com ela errada, é 401 `invalid_credential`.
- A chave `prk_` é recusada na ingestão de consumo (401), e a `pus_` só vale lá.
- Guarde as três em variáveis de ambiente (`PERATA_API_KEY`, `PERATA_USAGE_KEY`, `PERATA_WEBHOOK_SECRET`). Nunca no repositório, em log ou no navegador.
- Chaves de um dono ou administrador da organização enxergam o CPF do cliente inteiro; as demais o recebem mascarado.

## Escopos

Cada chave carrega os escopos que o dono marcou. Uma rota responde só à chave que tem o escopo dela; sem ele, 403 `forbidden` com `message` dizendo qual falta e onde marcar (Configurações › Tokens de acesso). Para ganhar um escopo, crie uma chave nova marcando-o.

| Escopo | Libera |
|---|---|
| `products:read` | ler produtos e preços |
| `products:write` | criar e alterar produtos, arquivar, criar preços |
| `customers:read` | ler clientes (também pelo `external_id` e o estado) e os cartões guardados |
| `customers:write` | criar, alterar e excluir clientes; desvincular cartão |
| `customer_sessions:write` | abrir o portal do cliente |
| `checkouts:read` | ler checkouts |
| `checkouts:write` | criar, alterar e encerrar (`expire`) checkouts |
| `orders:read` | pedidos, fatura e recibo |
| `payments:read` | pagamentos |
| `subscriptions:read` | ler assinaturas |
| `subscriptions:write` | trocar o plano, cancelar e reativar assinaturas |
| `discounts:read` / `discounts:write` | descontos |
| `benefits:read` / `benefits:write` | benefícios e suas concessões |
| `checkout_links:read` / `checkout_links:write` | links de checkout |
| `webhooks:read` / `webhooks:write` | endpoints e entregas de webhook |
| `meters:read` | medidores |
| `events:read` | eventos de consumo recebidos |
| `disputes:read` | disputas |
| `refunds:read` / `refunds:write` | ler e criar reembolsos |
| `showcase:read` | ler o showcase da chave |

Combinações que costumam faltar:
- Vender e administrar uma **assinatura** pela API: `checkouts:write` (criar o checkout), mais `products:read`, `subscriptions:read` e `subscriptions:write`, que são as três que a Peráta cita quando um 403 aparece numa assinatura.
- Cobrar um pedido de valor livre: `checkouts:write` e `products:read`.
- Receber e conferir vendas: `orders:read`, `payments:read`, `refunds:read`.

## Showcase

Uma organização (a empresa, com seu CPF ou CNPJ e seu cadastro na Cielo) pode ter vários showcases: cada plataforma ou produto da empresa é um. A chave nasce num showcase e só alcança o que é dele. Todo objeto de venda e todo webhook traz `showcase_id`. `GET /api/v1/showcase` (escopo `showcase:read`) devolve o showcase da chave: `id`, `name`, `is_principal`, `has_logo`, `environment`, `created_at`. Um showcase novo se abre no painel, nunca pela API.

## Ids que se confundem

Uma venda tem mais de um id. Esta é a fonte mais comum de erro:

| O que | De onde vem | Para que serve |
|---|---|---|
| `id` do checkout | resposta de `POST /checkouts` (`data.id`) | o link do checkout: `GET`/`PATCH /checkouts/{id}` e `POST /checkouts/{id}/expire` |
| `session_id` | a mesma resposta | a sessão de compra aberta para o comprador; também aceito em `expire` |
| `checkout_id` nos webhooks, `id` do pedido | é o `session_id` | o pedido (`GET /orders/{id}`) e o `order_id` do reembolso |
| `client_reference_id` | enviado por você | o id do pedido no seu sistema; volta em tudo |
| `status_key` | resposta de `POST /checkouts` | acompanhar a sessão no navegador depois que o `client_secret` é gasto |
| `client_secret` | resposta de `POST /checkouts`, só nela | monta os componentes no navegador; nunca a chave de API |

Regra prática: guarde `id`, `session_id` e `status_key` no seu pedido e ligue vendas e avisos pelo `client_reference_id`.

## Formatos

- Valor: inteiro em centavos (`amount_cents`). Nunca decimal.
- Data e hora: RFC 3339 (`2026-12-01T10:00:00-03:00`).
- Texto livre (`client_reference_id`, `label`, nome de linha, `metadata`): sem tabulação, quebra de linha, ESC nem marcas invisíveis de direção do texto (como U+202E); com elas é 422. Limpe antes de enviar.
- `metadata`: até 50 pares; chave de 1 a 40 caracteres; valor texto de 1 a 500 caracteres, número ou booleano.
- Resposta de sucesso: `{"data": ...}`. Uma lista é `{"data": {"items": [...], "pagination": {"total_count", "max_page"}}}`.
- Escritas só aceitam `Content-Type: application/json` (senão 415) e rejeitam campo desconhecido.
