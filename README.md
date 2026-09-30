# Marketplace de Serviços Locais — MVP

App que conecta **clientes** que precisam de um serviço a **prestadores** da região.
O cliente publica o que precisa, recebe propostas, escolhe um prestador e avalia depois.
Pensado para ser testado numa cidade pequena antes de crescer.

**Stack:** FlutterFlow (app Android/iOS/Web) + Supabase (Postgres, Auth, Storage, Realtime).

## O que já está pronto neste repositório

Este repositório tem o **backend completo do MVP**, com testes, pronto para conectar ao FlutterFlow:

| Item do MVP                          | Onde está resolvido |
|--------------------------------------|---------------------|
| Cadastro e login                     | Supabase Auth + trigger `handle_new_user` cria o perfil com o papel escolhido |
| Perfil de cliente / de prestador     | `profiles`, `profile_contacts`, `provider_profiles`, `provider_categories` |
| Publicação de serviços               | `jobs` (+ `job_addresses` com o endereço exato, privado) |
| Lista, busca e filtros               | RPC `search_jobs` (texto, categoria, cidade, orçamento, paginação) e `search_providers` |
| Candidatura + proposta/preço         | `proposals` (preço, mensagem, prazo, data disponível) |
| Cliente vê candidatos                | view `job_candidates` (com nota, nº de serviços, selo de verificado) |
| Cliente escolhe o prestador          | RPC `accept_proposal` (recusa as demais e notifica todo mundo) |
| Conclusão / cancelamento             | RPCs `complete_job`, `cancel_job`, `withdraw_proposal`, `reject_proposal` |
| Avaliações                           | `reviews` + média automática no perfil do prestador |
| Histórico de serviços                | views `my_job_history` e `my_proposals` |
| Notificações básicas                 | `notifications` geradas automaticamente + Realtime (+ tabela `device_tokens` para push) |
| Painel administrativo                | RPC `admin_dashboard`, view `admin_users`, bloquear usuário, verificar prestador, ocultar avaliação, denúncias (`reports`) |
| Banco de dados estruturado           | 4 migrations SQL com RLS (segurança por linha) em todas as tabelas |

Regras de privacidade importantes, já garantidas pelo banco (não dependem do app):

- Telefone/WhatsApp e endereço exato **só aparecem depois que o cliente escolhe o prestador** — e só para esse prestador.
- Prestador só vê as próprias propostas; cliente vê as propostas dos seus serviços.
- Ninguém consegue se promover a admin, se "auto-verificar" ou alterar a própria nota.
- Mudanças de status só acontecem pelas funções (RPC), então o fluxo não pode ser "pulado".
- Usuário bloqueado pelo admin não publica serviços nem envia propostas.

## Estrutura

```
supabase/
  migrations/
    20260930000001_schema.sql     # tipos, tabelas, índices
    20260930000002_functions.sql  # regras de negócio, triggers, RPCs, busca, admin
    20260930000003_rls_views.sql  # segurança (RLS), views e permissões
    20260930000004_storage.sql    # buckets de fotos (avatars, job-photos)
  seed.sql                        # categorias iniciais
  tests/
    run.sh                        # sobe um Postgres temporário e testa o fluxo inteiro
    fluxo_mvp_test.sql
docs/
  banco-de-dados.md               # modelo de dados e diagrama
  flutterflow.md                  # telas, queries e ações no FlutterFlow
  roadmap.md                      # cronograma do MVP e próximos passos
```

## Como colocar no ar

1. Crie um projeto em [supabase.com](https://supabase.com) (região São Paulo).
2. Aplique as migrations, de um destes jeitos:
   - **CLI:** `supabase link --project-ref <ref>` e depois `supabase db push`; em seguida rode `seed.sql` no SQL Editor.
   - **Sem CLI:** abra o *SQL Editor* e execute os 4 arquivos de `supabase/migrations/` **na ordem**, depois o `seed.sql`.
3. Em *Authentication → Providers*, deixe Email habilitado (Google/Apple opcionais).
4. Crie sua conta pelo app e se torne admin rodando no SQL Editor:
   ```sql
   update public.profiles set role = 'admin'
   where id = (select id from auth.users where email = 'seu-email@exemplo.com');
   ```
5. No FlutterFlow: *Settings → Integrations → Supabase*, cole a URL e a `anon key`, clique em **Get Schema**.
   Depois siga o [guia de telas](docs/flutterflow.md).

## Testes

```bash
supabase/tests/run.sh
```

Sobe um Postgres local temporário, aplica tudo e simula o fluxo real: cadastro → perfil do prestador →
publicação → notificação por região → busca → propostas → escolha → liberação de contato/endereço →
conclusão → avaliação → painel admin → bloqueio → cancelamento. Também testa as tentativas de burlar as regras.

## Por que FlutterFlow + Supabase (e alternativas)

A escolha é boa para este MVP: um app nativo para Android/iOS sai rápido, o Supabase é Postgres de verdade
(relacional, ideal para marketplace) e o plano gratuito aguenta com folga uma cidade pequena.
Pontos de atenção e sugestões:

- **Deixe a lógica no banco** (como está aqui). Assim, se um dia sair do FlutterFlow para Flutter puro
  (o FlutterFlow exporta o código), nada do backend muda.
- **Push notifications:** o FlutterFlow tem push nativo só com Firebase. Opções: usar o Firebase apenas para
  o FCM e uma Edge Function do Supabase que envia o push a cada nova linha em `notifications` (a tabela
  `device_tokens` já existe para isso) — ou, no primeiro teste, usar só as notificações in-app + e-mail.
- **Pagamento dentro do app** ficou de fora de propósito: no piloto, cliente e prestador combinam o pagamento
  direto. Isso valida a demanda sem lidar com intermediação financeira; dá para plugar Mercado Pago/Asaas depois.
- **Painel admin:** pode ser uma área do próprio app FlutterFlow visível só para `role = 'admin'`
  (descrito no guia) — sem custo extra. Se preferir web, um painel pronto como Appsmith/Retool também conecta no Supabase.
