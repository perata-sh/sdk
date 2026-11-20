# Lista para ir a Produção

Só vá para Produção com tudo verde no ambiente Teste e com o aval do dono do projeto. O agente prepara; quem decide e quem faz o primeiro pagamento real é o dono.

## A. Passou no Teste?

No ambiente Teste (nada é cobrado), confira cada caminho, de ponta a ponta, com o servidor de verdade recebendo os avisos:

- [ ] Um pedido pago com o cartão aprovado (`5315281703921200`, validade futura, CVV 123): o webhook `order.paid` chega e o pedido fica pago, **uma vez só**.
- [ ] Um pedido pago por Pix: o código aparece, o pagamento é confirmado pelo webhook.
- [ ] Cartão recusado (`4556839012717832`): o pedido continua em aberto.
- [ ] Valor que muda antes do pagamento: o link antigo deixa de abrir (`expire`) e o novo cobra o novo valor. Um `expire` num pedido já pago (409) não abre outro checkout.
- [ ] A volta pela `success_url` sem pagar **não** libera o pedido.
- [ ] Webhook com assinatura inválida, com data velha e repetido (o mesmo `webhook-id`): recusado, recusado e processado uma vez.
- [ ] Webhook de ambiente errado: recusado.
- [ ] Reembolso total e parcial: o crédito ou o acesso volta uma vez por `refund_id`.
- [ ] Assinatura: criação, e o seu tratamento de `subscription.past_due`, `subscription.suspended`, `resume` e `cancel`.
- [ ] A conferência diária acha um pedido pago cujo webhook foi apagado de propósito.
- [ ] O que o cliente leigo lê (nome das linhas, mensagens de erro, e-mails) faz sentido.

## B. O que se prepara em Produção

Os dados do Teste não existem em Produção. Faça tudo de novo, no ambiente Produção do painel:

1. **Vendedor aprovado.** A Produção só vende de verdade depois que a equipe da Peráta verifica e aprova o vendedor e a conta de recebimento. Pergunte ao dono se está concluída; se não, esse é o primeiro passo e a integração espera.
2. **Catálogo.** Produtos, preços (o de **valor livre se cria no painel**, com mínimo e máximo), descontos e benefícios. Anote o `product_id` e o `price_id` de Produção: são outros. Mantenha **um par de ids por ambiente** na configuração.
3. **Chave `prk_live_`**, com os escopos que a integração usa (`conceitos.md`). Guarde só nos segredos do deploy.
4. **Webhook de Produção.** Crie um endpoint **no ambiente Produção**, com a URL https pública do servidor e os eventos que o código trata. Guarde o `whsec_` **desse** endpoint, não o do Teste. Esta é a falha mais comum (`erros-comuns.md`).
5. **O servidor recusa o ambiente errado**: o endpoint de Produção responde 400 a um aviso `environment: "test"` (o de Teste, a um `"live"`).
6. **Sites permitidos**, se usa modal, componentes ou formulário próprio: libere o site em Configurações › Checkout incorporado › Sites permitidos, e confira em Produção. Para Google Pay e Apple Pay, o site precisa estar cadastrado nas duas carteiras pela equipe da Peráta.
7. **Cobrança por uso**: a fonte de ingestão `pus_live_` só existe para a organização que a equipe da Peráta liberou.
8. **Assinaturas**: confirme com a Peráta se a renovação automática no cartão está ligada em Produção (em 18/11/2026 estava desligada) e os dias de nova tentativa em Configurações › Preferências › Assinaturas.
9. **Variáveis de ambiente de Produção no servidor antes de publicar o código** (`PERATA_API_KEY` com a chave live, `PERATA_WEBHOOK_SECRET` com o segredo do endpoint de Produção, os ids de produto e preço). Primeiro as variáveis, depois o deploy.
10. **A conferência diária** agendada (`pos-venda.md`), para pegar um aviso que não chegou.
11. **Ninguém imprime segredos**: procure por `prk_`, `pus_` e `whsec_` no código, nos logs e no commit antes de publicar.

## C. O primeiro pagamento real

**O agente nunca faz um pagamento real.** O primeiro é do dono, num pedido barato, com o cartão ou o Pix dele. Peça-lhe que o faça e confira, juntos:

- [ ] o webhook chegou (se não: `GET /api/v1/webhooks/deliveries` mostra a tentativa e o `response_status`);
- [ ] o pedido do seu sistema ficou pago e o que foi vendido foi entregue, uma vez;
- [ ] o recibo do pedido existe (`GET /orders/{id}/receipt`);
- [ ] se o dono quiser testar o caminho de volta, um reembolso desse mesmo pagamento (o estorno de um Pix pode levar horas para ser aceito; é normal, e conclui sozinho).

## D. Depois

- Acompanhe `GET /api/v1/webhooks/deliveries?status=exhausted`: um aviso esgotado ou um endpoint `disabled` é um pagamento que o seu sistema não viu.
- Tenha um caminho para o suporte: o contato da Peráta é ajuda@perata.sh. Para um defeito ou uma falta na Peráta (rota, campo, evento), leve o caso exato, com a requisição e a resposta, em vez de contornar no seu sistema.
