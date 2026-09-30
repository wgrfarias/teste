-- =============================================================================
-- Marketplace de Serviços - MVP
-- Migration 1: tipos, tabelas e índices
-- =============================================================================

create extension if not exists pg_trgm;

-- -----------------------------------------------------------------------------
-- Tipos
-- -----------------------------------------------------------------------------
create type public.user_role as enum ('cliente', 'prestador', 'admin');

create type public.job_status as enum (
  'aberto',        -- publicado, recebendo propostas
  'em_andamento',  -- cliente escolheu um prestador
  'concluido',     -- serviço finalizado (pode ser avaliado)
  'cancelado'      -- cancelado pelo cliente ou admin
);

create type public.proposal_status as enum (
  'pendente',  -- aguardando decisão do cliente
  'aceita',    -- prestador escolhido
  'recusada',  -- outro prestador foi escolhido / serviço cancelado
  'retirada'   -- prestador desistiu
);

create type public.notification_type as enum (
  'nova_proposta',
  'proposta_aceita',
  'proposta_recusada',
  'servico_concluido',
  'servico_cancelado',
  'nova_avaliacao',
  'novo_servico_na_regiao',
  'sistema'
);

create type public.report_status as enum ('aberta', 'em_analise', 'resolvida', 'descartada');

-- -----------------------------------------------------------------------------
-- Perfis
-- -----------------------------------------------------------------------------

-- Dados públicos de qualquer usuário (visíveis para usuários logados).
create table public.profiles (
  id           uuid primary key references auth.users (id) on delete cascade,
  role         public.user_role not null default 'cliente',
  full_name    text not null default '',
  avatar_url   text,
  city         text,
  state        text,
  bio          text,
  is_blocked   boolean not null default false,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

-- Dados de contato (privados). Só o dono, o admin e a "contraparte" de um
-- serviço em andamento/concluído conseguem ler.
create table public.profile_contacts (
  profile_id  uuid primary key references public.profiles (id) on delete cascade,
  phone       text,
  whatsapp    text,
  email       text,
  updated_at  timestamptz not null default now()
);

-- Informações extras de quem presta serviço.
create table public.provider_profiles (
  profile_id        uuid primary key references public.profiles (id) on delete cascade,
  headline          text,                       -- ex.: "Eletricista residencial há 10 anos"
  service_cities    text[] not null default '{}', -- cidades/bairros atendidos
  service_radius_km integer check (service_radius_km is null or service_radius_km between 1 and 500),
  years_experience  integer check (years_experience is null or years_experience >= 0),
  is_available      boolean not null default true,
  is_verified       boolean not null default false, -- marcado pelo admin
  rating_avg        numeric(3,2) not null default 0,
  rating_count      integer not null default 0,
  jobs_completed    integer not null default 0,
  updated_at        timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- Categorias
-- -----------------------------------------------------------------------------
create table public.categories (
  id          bigint generated always as identity primary key,
  name        text not null unique,
  slug        text not null unique,
  icon        text,          -- nome do ícone usado no FlutterFlow (Material Icons)
  sort_order  integer not null default 0,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);

create table public.provider_categories (
  provider_id uuid   not null references public.provider_profiles (profile_id) on delete cascade,
  category_id bigint not null references public.categories (id) on delete cascade,
  primary key (provider_id, category_id)
);

-- -----------------------------------------------------------------------------
-- Serviços publicados (pedidos dos clientes)
-- -----------------------------------------------------------------------------
create table public.jobs (
  id                    uuid primary key default gen_random_uuid(),
  client_id             uuid not null references public.profiles (id) on delete cascade,
  category_id           bigint not null references public.categories (id),
  title                 text not null check (char_length(title) between 5 and 120),
  description           text not null check (char_length(description) between 10 and 4000),
  city                  text not null,
  state                 text,
  neighborhood          text,
  latitude              double precision,
  longitude             double precision,
  budget_min            numeric(10,2) check (budget_min is null or budget_min >= 0),
  budget_max            numeric(10,2) check (budget_max is null or budget_max >= 0),
  desired_date          date,
  urgency               text check (urgency in ('baixa', 'media', 'alta')) default 'media',
  photos                text[] not null default '{}',   -- URLs do Storage (bucket job-photos)
  status                public.job_status not null default 'aberto',
  selected_proposal_id  uuid,                         -- FK adicionada após criar proposals
  proposals_count       integer not null default 0,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  started_at            timestamptz,
  completed_at          timestamptz,
  cancelled_at          timestamptz,
  constraint jobs_budget_range check (budget_min is null or budget_max is null or budget_min <= budget_max)
);

-- Endereço exato fica separado: só aparece para o prestador escolhido.
create table public.job_addresses (
  job_id      uuid primary key references public.jobs (id) on delete cascade,
  street      text,
  number      text,
  complement  text,
  zip_code    text,
  reference   text
);

-- -----------------------------------------------------------------------------
-- Propostas / candidaturas
-- -----------------------------------------------------------------------------
create table public.proposals (
  id              uuid primary key default gen_random_uuid(),
  job_id          uuid not null references public.jobs (id) on delete cascade,
  provider_id     uuid not null references public.provider_profiles (profile_id) on delete cascade,
  price           numeric(10,2) check (price is null or price >= 0), -- null = "a combinar"
  message         text not null check (char_length(message) between 5 and 2000),
  estimated_days  integer check (estimated_days is null or estimated_days > 0),
  available_date  date,
  status          public.proposal_status not null default 'pendente',
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (job_id, provider_id)
);

alter table public.jobs
  add constraint jobs_selected_proposal_fk
  foreign key (selected_proposal_id) references public.proposals (id) on delete set null;

-- -----------------------------------------------------------------------------
-- Avaliações (cliente -> prestador, uma por serviço)
-- -----------------------------------------------------------------------------
create table public.reviews (
  id           uuid primary key default gen_random_uuid(),
  job_id       uuid not null unique references public.jobs (id) on delete cascade,
  client_id    uuid not null references public.profiles (id) on delete cascade,
  provider_id  uuid not null references public.provider_profiles (profile_id) on delete cascade,
  rating       smallint not null check (rating between 1 and 5),
  comment      text check (comment is null or char_length(comment) <= 1000),
  is_hidden    boolean not null default false, -- moderação pelo admin
  created_at   timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- Notificações in-app
-- -----------------------------------------------------------------------------
create table public.notifications (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles (id) on delete cascade,
  type        public.notification_type not null,
  title       text not null,
  body        text,
  job_id      uuid references public.jobs (id) on delete cascade,
  proposal_id uuid references public.proposals (id) on delete cascade,
  read_at     timestamptz,
  created_at  timestamptz not null default now()
);

-- Tokens de push (FCM), usados por uma Edge Function opcional.
create table public.device_tokens (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles (id) on delete cascade,
  token       text not null unique,
  platform    text check (platform in ('android', 'ios', 'web')),
  created_at  timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- Denúncias (moderação pelo painel administrativo)
-- -----------------------------------------------------------------------------
create table public.reports (
  id               uuid primary key default gen_random_uuid(),
  reporter_id      uuid not null references public.profiles (id) on delete cascade,
  reported_user_id uuid references public.profiles (id) on delete cascade,
  job_id           uuid references public.jobs (id) on delete cascade,
  reason           text not null check (char_length(reason) between 5 and 1000),
  status           public.report_status not null default 'aberta',
  admin_notes      text,
  created_at       timestamptz not null default now(),
  resolved_at      timestamptz,
  constraint reports_target check (reported_user_id is not null or job_id is not null)
);

-- -----------------------------------------------------------------------------
-- Índices
-- -----------------------------------------------------------------------------
create index jobs_status_created_idx     on public.jobs (status, created_at desc);
create index jobs_category_idx           on public.jobs (category_id);
create index jobs_client_idx             on public.jobs (client_id, created_at desc);
create index jobs_city_trgm_idx          on public.jobs using gin (city gin_trgm_ops);
create index jobs_title_trgm_idx         on public.jobs using gin (title gin_trgm_ops);
create index proposals_job_idx           on public.proposals (job_id);
create index proposals_provider_idx      on public.proposals (provider_id, created_at desc);
create index reviews_provider_idx        on public.reviews (provider_id, created_at desc);
create index notifications_user_idx      on public.notifications (user_id, created_at desc);
create index notifications_unread_idx    on public.notifications (user_id) where read_at is null;
create index provider_cities_idx         on public.provider_profiles using gin (service_cities);
create index provider_categories_cat_idx on public.provider_categories (category_id);
