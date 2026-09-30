# Cronograma sugerido do MVP

| Semana | Entrega | Status |
|---|---|---|
| 1 | Modelagem do banco, regras de segurança, fluxos e testes (este repositório) | ✅ pronto |
| 1–2 | Protótipo de telas / identidade visual (Figma ou direto no FlutterFlow) e validação com 3–5 pessoas da cidade | a fazer |
| 2–3 | FlutterFlow: autenticação, perfis, publicação de serviço, feed com busca e filtros | a fazer |
| 3–4 | Propostas, escolha do prestador, contato via WhatsApp, conclusão, avaliações, histórico | a fazer |
| 4 | Notificações in-app (Realtime), painel admin | a fazer |
| 5 | Testes com usuários reais, ajustes, publicação na Play Store (e App Store, se for o caso) | a fazer |

## Antes do lançamento na cidade

- [ ] Cadastrar 15–30 prestadores antes de abrir para clientes (evita o "app vazio").
- [ ] Revisar a lista de categorias do `seed.sql` com o que a cidade mais demanda.
- [ ] Termos de uso e política de privacidade (LGPD) — o app lida com telefone e endereço.
- [ ] Verificar manualmente os primeiros prestadores (selo "verificado").
- [ ] Definir métricas de sucesso: serviços publicados/semana, % com proposta em 24h, % contratados, nota média.

## Evoluções após o piloto

- Chat interno entre cliente e prestador (tabela `messages` + Realtime).
- Pagamento no app com retenção (Mercado Pago / Asaas / Stripe Connect) e comissão da plataforma.
- Planos pagos / destaque para prestadores.
- Prestador avaliando o cliente (avaliação bidirecional).
- Busca por distância usando `latitude`/`longitude` (PostGIS).
- Agenda / horários do prestador.
- Convite direto do cliente para um prestador específico.
- Expansão para outras cidades (campo `city` já está em todos os lugares certos).
