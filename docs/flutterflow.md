# Guia de telas no FlutterFlow

Pré-requisito: Supabase conectado em *Settings → Integrations → Supabase* e **Get Schema** executado
(as tabelas, views e funções aparecem automaticamente).

Convenções usadas abaixo:
- **Query** = *Backend Query → Supabase Query* (tabela ou view, com filtros).
- **RPC** = *API Call* do tipo POST para `https://<projeto>.supabase.co/rest/v1/rpc/<função>`, com headers
  `apikey: <anon key>` e `Authorization: Bearer [authToken]`. Crie um *API Group* "Supabase RPC" com esses
  headers e uma chamada por função.
- **App State**: `userRole` (String), `unreadCount` (Integer).

## Navegação

```
Splash ──► (sem login) Boas-vindas ─► Cadastro / Login
      └──► (logado) lê profiles.role
             ├─ cliente   ─► NavBar Cliente:   Início | Meus serviços | Notificações | Perfil
             ├─ prestador ─► NavBar Prestador: Serviços | Minhas propostas | Notificações | Perfil
             └─ admin     ─► Painel Admin (+ acesso às telas de cliente)
```

## 1. Autenticação

| Tela | Componentes | Ações |
|---|---|---|
| **Boas-vindas** | Logo, 2 botões: "Quero contratar" / "Quero trabalhar" | Guarda a escolha em Page State `role` e vai para Cadastro |
| **Cadastro** | Nome, e-mail, senha, telefone, cidade (dropdown com as cidades do piloto) | Os dados do perfil vão como metadados do cadastro: use uma *Custom Action* `signUpWithMetadata` chamando `Supabase.instance.client.auth.signUp(email, password, data: {'full_name', 'role', 'city', 'phone'})` — o trigger cria o perfil automaticamente |
| **Login** | E-mail, senha, "Esqueci a senha" | *Log In (Supabase)*; *Reset Password* |
| **Splash** | — | Query `profiles` (id = Authenticated User ID) → define `userRole` → navega para a NavBar correta. Se `is_blocked`, mostra aviso e faz logout |

## 2. Cliente

| Tela | Dados | Ações |
|---|---|---|
| **Início** | Grid de `categories` (ordenar por `sort_order`); botão grande "Publicar serviço"; opcional: RPC `search_providers` para "Prestadores bem avaliados" | Toque na categoria abre Publicar com a categoria preenchida |
| **Publicar serviço** (formulário em 2 passos) | Passo 1: categoria, título, descrição, fotos (*Upload Media to Supabase*, bucket `job-photos`, path `[userId]/[timestamp].jpg`). Passo 2: cidade, bairro, endereço (rua, número, referência), faixa de preço, data desejada, urgência | *Insert Row* em `jobs` (client_id = user id) com *Return* ligado → *Insert Row* em `job_addresses` com o `id` retornado → navega para Detalhe |
| **Meus serviços** | Query `jobs` where `client_id = user` order `created_at desc`; TabBar por status (Abertos / Em andamento / Concluídos) | Card mostra `proposals_count` ("3 propostas") |
| **Detalhe do serviço (cliente)** | Dados do `jobs` + fotos (carrossel). Se `aberto`: lista de **Query `job_candidates`** where `job_id = X` and `status = pendente`. Se `em_andamento`: card do prestador escolhido + contato (Query `profile_contacts` where `profile_id = provider_id`) com botões "Ligar"/"WhatsApp" (*Launch URL* `https://wa.me/55...`) | Botões: "Editar" (só aberto), "Cancelar" → RPC `cancel_job`; "Marcar como concluído" → RPC `complete_job` → abre Avaliar |
| **Proposta (bottom sheet)** | Nome, foto, ⭐ `rating_avg` (`rating_count`), `jobs_completed`, selo verificado, preço, prazo, mensagem; link "Ver perfil" | "Escolher este prestador" → diálogo de confirmação → RPC `accept_proposal`; "Recusar" → RPC `reject_proposal` |
| **Perfil público do prestador** | Query `profiles` + `provider_profiles` + Query `provider_reviews` where `provider_id = X` | — |
| **Avaliar** | 5 estrelas (*RatingBar*), comentário | *Insert Row* em `reviews` com `job_id`, `rating`, `comment` (o banco preenche cliente/prestador) |
| **Histórico** | Query `my_job_history` | Se `can_review`, mostra botão "Avaliar" |

## 3. Prestador

| Tela | Dados | Ações |
|---|---|---|
| **Onboarding do prestador** (1ª vez) | Apresentação (`headline`), bio, anos de experiência, cidades atendidas (chips), categorias (multi-select de `categories`), foto | *Update Row* em `provider_profiles` e `profiles`; RPC `set_my_categories` com a lista de ids |
| **Serviços disponíveis** (feed) | RPC `search_jobs` → ListView; barra de busca (`p_query`), chips de categoria (`p_category_id`), cidade (`p_city`, padrão = cidade do perfil), paginação com `p_offset` | Card mostra "Já enviei proposta" quando `already_applied` |
| **Detalhe do serviço (prestador)** | Query `jobs` (id) + fotos + cliente (nome/foto/cidade). Endereço só aparece se for o escolhido (Query `job_addresses` retorna vazio para os demais) | Botão "Enviar proposta" (escondido se `already_applied`) |
| **Enviar proposta** | Preço (ou switch "A combinar" → envia null), prazo em dias, data disponível, mensagem | *Insert Row* em `proposals` (`provider_id` = user id). Erros do banco (ex.: serviço já fechado) aparecem em *On Error → Show Snackbar* |
| **Minhas propostas** | Query `my_proposals`; TabBar: Pendentes / Aceitas / Encerradas (`proposal_status`) | Pendente: "Editar" (*Update Row* em `proposals`) e "Desistir" → RPC `withdraw_proposal`. Aceita: botão "Ver contato do cliente" |
| **Perfil do prestador** | Nota média, nº de serviços, avaliações recebidas (`provider_reviews`), switch "Disponível" (`is_available`) | Editar perfil |

## 4. Comum

| Tela | Dados | Ações |
|---|---|---|
| **Notificações** | Query `notifications` where `user_id = user` order `created_at desc`, **Realtime ligado** (checkbox na query) | Toque: RPC `mark_notification_read` e navega para o serviço (`job_id`). Botão "Marcar todas como lidas" → RPC `mark_all_notifications_read` |
| **Badge do sino** | RPC `unread_notifications_count` no carregamento das telas principais → `unreadCount` | — |
| **Meu perfil** | `profiles` + `profile_contacts`; upload de avatar (bucket `avatars`, path `[userId]/avatar.jpg`) | *Update Row*; "Quero também oferecer serviços" → RPC `set_my_role('prestador')`; Denunciar → *Insert Row* em `reports`; Sair |

## 5. Painel administrativo (dentro do app, visível só para `admin`)

| Tela | Dados | Ações |
|---|---|---|
| **Dashboard** | RPC `admin_dashboard` → cards (clientes, prestadores, serviços por status, novos em 7 dias, média de propostas por serviço, avaliação média, denúncias abertas) e gráfico de serviços por categoria | — |
| **Usuários** | Query `admin_users` com busca por nome e filtro por papel | "Bloquear/Desbloquear" → RPC `admin_set_user_blocked`; "Verificar prestador" → RPC `admin_set_provider_verified` |
| **Serviços** | Query `jobs` (admin vê todos) com filtro de status | "Cancelar" → RPC `cancel_job` |
| **Avaliações** | Query `reviews` | "Ocultar" → RPC `admin_set_review_hidden` |
| **Denúncias** | Query `reports` where status in (aberta, em_analise) | *Update Row* status/`admin_notes` |
| **Categorias** | Query `categories` | *Insert/Update Row* (nome, slug, ícone, ativo) |

## Push notifications (opcional, fase 2 do MVP)

1. Ative *Push Notifications* no FlutterFlow (ele usa Firebase Cloud Messaging).
2. Após o login, salve o token FCM em `device_tokens` (*Insert Row*; `on conflict` não é necessário — trate erro de duplicado ignorando).
3. Crie uma Edge Function no Supabase acionada por *Database Webhook* em `INSERT` na tabela `notifications`
   que busca os tokens do `user_id` e envia via API HTTP v1 do FCM com o `title`/`body` da notificação.

## Dicas de UX para o piloto

- Cadastro curto: peça só o essencial; complete o perfil do prestador depois.
- Mostre a nota e o nº de serviços feitos em destaque na proposta — é o que gera confiança.
- Botão de WhatsApp após a contratação: em cidade pequena é o canal que as pessoas já usam.
- Estados vazios com ação clara ("Nenhuma proposta ainda — você será avisado quando chegar").
- Cores/ícones por status do serviço (aberto = azul, em andamento = laranja, concluído = verde, cancelado = cinza).
