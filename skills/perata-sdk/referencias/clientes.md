# Clientes e portal do cliente

O cliente é quem paga. Cadastrá-lo antes da venda não é obrigatório (o checkout cria um pelo e-mail), mas vale a pena: o checkout abre já preenchido, sem pedir código, e você acha tudo o que ele comprou pelo id dele no seu sistema.

## Campos

| Campo | Regra |
|---|---|
| `name`, `email` | obrigatórios na criação |
| `external_id` | o id do cliente no seu sistema. Até 120 caracteres, sem barra (`/`) nem caracteres de controle. **Só pode ser definido uma vez** |
| `tax_id` | CPF ou CNPJ, com ou sem pontuação, com os dígitos verificadores corretos. Volta só com dígitos |
| `tax_id_kind` | `cpf` ou `cnpj`; sem ele, os dígitos dizem |
| `phone` | telefone ou celular com DDD, com ou sem pontuação |
| `billing_name` | nome ou razão social de quem paga, quando difere de `name` |
| `billing_address` | `line1` (rua e número), `line2` (complemento, opcional), `district` (bairro), `city`, `state` (UF, duas letras), `postal_code` (CEP). Rua, bairro, cidade, UF e CEP vêm juntos |

Na leitura, o CPF volta inteiro para a chave de um dono ou administrador da organização e mascarado (`***.***.789-00`) para as outras; o CNPJ volta sempre inteiro. Alterar `tax_id` por `PATCH` só a chave de um dono ou administrador consegue; as demais recebem 403. Texto vazio apaga o CPF.

## Rotas

| Ação | Rota | Escopo |
|---|---|---|
| Criar | `POST /api/v1/customers` | `customers:write` |
| Listar; achar por e-mail | `GET /api/v1/customers`, `GET /api/v1/customers?email=ana@exemplo.com` (sem diferença de maiúsculas; SDK 0.5.5+) | `customers:read` |
| Ler | `GET /api/v1/customers/{id}` ou `GET /api/v1/external-customers/{external_id}` | `customers:read` |
| Alterar | `PATCH /api/v1/customers/{id}` ou `PATCH /api/v1/external-customers/{external_id}` | `customers:write` |
| Excluir | `DELETE /api/v1/customers/{id}` | `customers:write` |
| Estado (assinaturas ativas e benefícios vigentes) | `GET /api/v1/customers/{id}/state` | `customers:read` |
| Cartões guardados | `GET /api/v1/customers/{id}/payment_methods` | `customers:read` |
| Parar de cobrar um cartão | `POST /api/v1/payment_methods/{id}/detach` | `customers:write` |

Excluir um cliente encerra as assinaturas dele na hora, revoga os benefícios e libera o `external_id`; os pedidos e os pagamentos continuam nos registros. Desvincular um cartão é recusado (409) enquanto uma assinatura ativa o cobra. O número do cartão nunca aparece: só bandeira, quatro últimos dígitos e validade.

## A ligação por e-mail (importante)

Quando um checkout é criado ou pago com um e-mail novo, a Peráta cria o cliente a partir dele, sem `external_id`. Depois o seu sistema sincroniza o mesmo cliente com `POST /api/v1/customers` enviando `external_id` e esse e-mail. O que acontece:

- E-mail novo: cria o cliente e responde **201**.
- E-mail que já é de um cliente da mesma organização **sem** `external_id` (por exemplo, o que o checkout criou): a Peráta liga o `external_id` a ele, atualiza com os dados enviados (nome, CPF/CNPJ, telefone, endereço) e responde **200** com o cliente existente (o id é o dele). Trate 200 e 201 como sucesso.
- E-mail de um cliente que já tem **outro** `external_id`: continua recusado, 422 no campo `email`. O seu sistema precisa decidir qual dos dois é o cliente certo (busque com `GET /customers?email=`).

Por isso o roteiro seguro é: sincronize o cliente **antes** do primeiro checkout e passe `external_customer_id` no checkout. Assim a página abre com o e-mail travado e com nome, CPF/CNPJ (marcando "Comprar como empresa" no CNPJ) e endereço preenchidos, sem pedir código. O comprador pode corrigir os dados, menos o e-mail, e a correção vale só para aquela compra: não muda o cliente que você guardou. O telefone não aparece, porque o checkout não tem esse campo.

## Exemplos

Go:

```go
customer, err := client.Customers.Create(ctx, perata.CustomersCreateParams{
	Name:       "Ana Souza",
	Email:      "ana@exemplo.com",
	ExternalID: ptr("cliente-123"),
	TaxID:      ptr("529.982.247-25"),
	TaxIDKind:  ptr("cpf"),
	Phone:      ptr("(81) 98765-4321"),
	BillingAddress: &perata.CustomersCreateBillingAddress{
		Line1: ptr("Rua das Flores, 100"), District: ptr("Centro"),
		City: ptr("Recife"), State: ptr("PE"), PostalCode: ptr("50000-000"),
	},
}, perata.WithIdempotencyKey("sync-cliente-123"))

// Achar pelo e-mail ou pelo id do seu sistema
page, err := client.Customers.List(ctx, &perata.CustomersListParams{Email: "ana@exemplo.com"})
same, err := client.Customers.GetExternal(ctx, "cliente-123")
```

TypeScript:

```ts
const customer = await perata.customers.create(
  {
    name: "Ana Souza", email: "ana@exemplo.com", external_id: "cliente-123",
    tax_id: "529.982.247-25", tax_id_kind: "cpf", phone: "(81) 98765-4321",
    billing_address: { line1: "Rua das Flores, 100", district: "Centro", city: "Recife", state: "PE", postal_code: "50000-000" },
  },
  { idempotencyKey: "sync-cliente-123" },
);
const found = await perata.customers.list({ email: "ana@exemplo.com" });
```

Python:

```python
customer = perata.customers.create({
    "name": "Ana Souza", "email": "ana@exemplo.com", "external_id": "cliente-123",
    "tax_id": "529.982.247-25", "tax_id_kind": "cpf", "phone": "(81) 98765-4321",
    "billing_address": {"line1": "Rua das Flores, 100", "district": "Centro", "city": "Recife", "state": "PE", "postal_code": "50000-000"},
}, idempotency_key="sync-cliente-123")
found = perata.customers.list(email="ana@exemplo.com")
```

Uma atualização do endereço por `PATCH` substitui cada parte enviada e o endereço que resulta precisa estar inteiro; para apagá-lo, envie as partes vazias.

## Portal do cliente (customer-sessions)

O portal é a página da Peráta em que o cliente acompanha o que comprou e troca o cartão. Para mandar um cliente para ele sem pedir login:

`POST /api/v1/customer-sessions` com `customer_id` (obrigatório) e `return_url` (opcional, um endereço https do seu aplicativo; o portal oferece a volta). Escopo `customer_sessions:write`. Resposta 201 com `token`, `customer_portal_url` (o endereço que abre o portal já autenticado) e `expires_at`. Abra o `customer_portal_url`; a sessão expira, então gere uma nova a cada clique em "Gerenciar assinatura", não guarde o endereço.

```go
session, err := client.CustomerSessions.Create(ctx, perata.CustomerSessionsCreateParams{
	CustomerID: customer.ID,
	ReturnURL:  ptr("https://app.exemplo/conta"),
})
http.Redirect(w, r, session.CustomerPortalURL, http.StatusSeeOther)
```

```ts
const session = await perata.customerSessions.create({ customer_id: customer.id, return_url: "https://app.exemplo/conta" });
redirect(session.customer_portal_url);
```

```python
session = perata.customer_sessions.create({"customer_id": customer.id, "return_url": "https://app.exemplo/conta"})
return redirect(session.customer_portal_url)
```

Quando o cliente troca o cartão no portal de uma assinatura com cobrança pendente, a cobrança acontece na hora e, se passar, a assinatura volta a `active` (veja `assinaturas.md`).
