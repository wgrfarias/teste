-- =============================================================================
-- Migration 3: segurança (Row Level Security), views e permissões
-- =============================================================================

alter table public.profiles            enable row level security;
alter table public.profile_contacts    enable row level security;
alter table public.provider_profiles   enable row level security;
alter table public.categories          enable row level security;
alter table public.provider_categories enable row level security;
alter table public.jobs                enable row level security;
alter table public.job_addresses       enable row level security;
alter table public.proposals           enable row level security;
alter table public.reviews             enable row level security;
alter table public.notifications       enable row level security;
alter table public.device_tokens       enable row level security;
alter table public.reports             enable row level security;

-- -----------------------------------------------------------------------------
-- profiles: qualquer usuário logado vê dados públicos; só edita o próprio.
-- -----------------------------------------------------------------------------
create policy "profiles_select" on public.profiles
  for select to authenticated using (true);

create policy "profiles_update_own" on public.profiles
  for update to authenticated
  using (id = auth.uid() or public.is_admin())
  with check (id = auth.uid() or public.is_admin());

-- -----------------------------------------------------------------------------
-- profile_contacts: dono, admin ou quem tem serviço contratado com a pessoa.
-- -----------------------------------------------------------------------------
create policy "contacts_select" on public.profile_contacts
  for select to authenticated
  using (profile_id = auth.uid() or public.is_admin() or public.has_hired_relationship(profile_id));

create policy "contacts_update_own" on public.profile_contacts
  for update to authenticated
  using (profile_id = auth.uid()) with check (profile_id = auth.uid());

-- -----------------------------------------------------------------------------
-- provider_profiles
-- -----------------------------------------------------------------------------
create policy "provider_select" on public.provider_profiles
  for select to authenticated using (true);

create policy "provider_update_own" on public.provider_profiles
  for update to authenticated
  using (profile_id = auth.uid() or public.is_admin())
  with check (profile_id = auth.uid() or public.is_admin());

-- -----------------------------------------------------------------------------
-- categories: leitura pública (inclusive antes do login); escrita só admin.
-- -----------------------------------------------------------------------------
create policy "categories_select" on public.categories
  for select to anon, authenticated using (is_active or public.is_admin());

create policy "categories_admin_all" on public.categories
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- -----------------------------------------------------------------------------
-- provider_categories
-- -----------------------------------------------------------------------------
create policy "provider_categories_select" on public.provider_categories
  for select to authenticated using (true);

create policy "provider_categories_insert_own" on public.provider_categories
  for insert to authenticated with check (provider_id = auth.uid() and public.is_provider());

create policy "provider_categories_delete_own" on public.provider_categories
  for delete to authenticated using (provider_id = auth.uid());

-- -----------------------------------------------------------------------------
-- jobs
--   * serviços abertos: visíveis a todos os usuários logados;
--   * demais status: só o cliente, prestadores que enviaram proposta e admin.
-- -----------------------------------------------------------------------------
create policy "jobs_select" on public.jobs
  for select to authenticated
  using (
    status = 'aberto'
    or client_id = auth.uid()
    or public.is_admin()
    or exists (select 1 from public.proposals pr where pr.job_id = jobs.id and pr.provider_id = auth.uid())
  );

create policy "jobs_insert_own" on public.jobs
  for insert to authenticated
  with check (client_id = auth.uid() and public.is_active_user());

create policy "jobs_update_own" on public.jobs
  for update to authenticated
  using (client_id = auth.uid() or public.is_admin())
  with check (client_id = auth.uid() or public.is_admin());

create policy "jobs_delete_admin" on public.jobs
  for delete to authenticated using (public.is_admin());

-- -----------------------------------------------------------------------------
-- job_addresses: endereço exato só para o cliente, o prestador escolhido e admin.
-- -----------------------------------------------------------------------------
create policy "job_addresses_select" on public.job_addresses
  for select to authenticated
  using (public.owns_job(job_id) or public.is_selected_provider(job_id) or public.is_admin());

create policy "job_addresses_insert_own" on public.job_addresses
  for insert to authenticated with check (public.owns_job(job_id));

create policy "job_addresses_update_own" on public.job_addresses
  for update to authenticated
  using (public.owns_job(job_id)) with check (public.owns_job(job_id));

-- -----------------------------------------------------------------------------
-- proposals: o prestador vê as suas; o cliente vê as do seu serviço.
-- -----------------------------------------------------------------------------
create policy "proposals_select" on public.proposals
  for select to authenticated
  using (provider_id = auth.uid() or public.owns_job(job_id) or public.is_admin());

create policy "proposals_insert_provider" on public.proposals
  for insert to authenticated
  with check (provider_id = auth.uid() and public.is_provider());

create policy "proposals_update_own" on public.proposals
  for update to authenticated
  using (provider_id = auth.uid() or public.is_admin())
  with check (provider_id = auth.uid() or public.is_admin());

-- -----------------------------------------------------------------------------
-- reviews: públicas (exceto ocultas); cliente avalia o próprio serviço.
-- -----------------------------------------------------------------------------
create policy "reviews_select" on public.reviews
  for select to authenticated
  using (not is_hidden or client_id = auth.uid() or provider_id = auth.uid() or public.is_admin());

create policy "reviews_insert_client" on public.reviews
  for insert to authenticated
  with check (public.owns_job(job_id) and public.is_active_user());

create policy "reviews_update_client" on public.reviews
  for update to authenticated
  using (client_id = auth.uid() or public.is_admin())
  with check (client_id = auth.uid() or public.is_admin());

-- -----------------------------------------------------------------------------
-- notifications: só as próprias. Criadas apenas pelo banco (triggers/RPC).
-- -----------------------------------------------------------------------------
create policy "notifications_select_own" on public.notifications
  for select to authenticated using (user_id = auth.uid());

create policy "notifications_delete_own" on public.notifications
  for delete to authenticated using (user_id = auth.uid());

-- -----------------------------------------------------------------------------
-- device_tokens
-- -----------------------------------------------------------------------------
create policy "device_tokens_own" on public.device_tokens
  for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- -----------------------------------------------------------------------------
-- reports (denúncias)
-- -----------------------------------------------------------------------------
create policy "reports_insert" on public.reports
  for insert to authenticated with check (reporter_id = auth.uid());

create policy "reports_select" on public.reports
  for select to authenticated using (reporter_id = auth.uid() or public.is_admin());

create policy "reports_admin_update" on public.reports
  for update to authenticated using (public.is_admin()) with check (public.is_admin());

-- =============================================================================
-- Views (respeitam o RLS de quem consulta: security_invoker = true)
-- Úteis no FlutterFlow como "Supabase Query" direto na tabela/view.
-- =============================================================================

-- Candidatos de um serviço (tela "Propostas recebidas" do cliente).
create view public.job_candidates with (security_invoker = true) as
select pr.id            as proposal_id,
       pr.job_id,
       pr.price,
       pr.message,
       pr.estimated_days,
       pr.available_date,
       pr.status,
       pr.created_at,
       p.id             as provider_id,
       p.full_name      as provider_name,
       p.avatar_url     as provider_avatar,
       p.city           as provider_city,
       pp.headline,
       pp.rating_avg,
       pp.rating_count,
       pp.jobs_completed,
       pp.is_verified
from public.proposals pr
join public.profiles p           on p.id = pr.provider_id
join public.provider_profiles pp on pp.profile_id = pr.provider_id;

-- Candidaturas do prestador logado (tela "Minhas propostas").
create view public.my_proposals with (security_invoker = true) as
select pr.id          as proposal_id,
       pr.price,
       pr.message,
       pr.status      as proposal_status,
       pr.created_at,
       j.id           as job_id,
       j.title        as job_title,
       j.city         as job_city,
       j.neighborhood as job_neighborhood,
       j.status       as job_status,
       c.name         as category_name,
       cl.full_name   as client_name,
       cl.avatar_url  as client_avatar
from public.proposals pr
join public.jobs j        on j.id = pr.job_id
join public.categories c  on c.id = j.category_id
join public.profiles cl   on cl.id = j.client_id
where pr.provider_id = auth.uid();

-- Histórico de serviços do usuário (como cliente ou como prestador escolhido).
create view public.my_job_history with (security_invoker = true) as
select j.id            as job_id,
       j.title,
       j.status,
       j.city,
       c.name          as category_name,
       j.created_at,
       j.started_at,
       j.completed_at,
       j.cancelled_at,
       case when j.client_id = auth.uid() then 'cliente' else 'prestador' end as my_role,
       j.client_id,
       cl.full_name    as client_name,
       pr.provider_id,
       pv.full_name    as provider_name,
       pr.price        as agreed_price,
       rv.rating       as review_rating,
       (j.status = 'concluido' and j.client_id = auth.uid() and rv.id is null) as can_review
from public.jobs j
join public.categories c    on c.id = j.category_id
join public.profiles cl     on cl.id = j.client_id
left join public.proposals pr on pr.id = j.selected_proposal_id
left join public.profiles pv  on pv.id = pr.provider_id
left join public.reviews rv   on rv.job_id = j.id
where j.client_id = auth.uid() or pr.provider_id = auth.uid();

-- Avaliações com nome de quem avaliou (perfil público do prestador).
create view public.provider_reviews with (security_invoker = true) as
select r.id, r.provider_id, r.rating, r.comment, r.created_at,
       j.title     as job_title,
       p.full_name as client_name,
       p.avatar_url as client_avatar
from public.reviews r
join public.jobs j     on j.id = r.job_id
join public.profiles p on p.id = r.client_id
where not r.is_hidden;

-- Lista de usuários para o painel admin (vazia para não-admin).
create view public.admin_users with (security_invoker = true) as
select p.id, p.full_name, p.role, p.city, p.is_blocked, p.created_at,
       pc.email, pc.phone,
       pp.is_verified, pp.rating_avg, pp.rating_count, pp.jobs_completed,
       (select count(*) from public.jobs j where j.client_id = p.id) as jobs_posted,
       (select count(*) from public.proposals pr where pr.provider_id = p.id) as proposals_sent
from public.profiles p
left join public.profile_contacts pc  on pc.profile_id = p.id
left join public.provider_profiles pp on pp.profile_id = p.id
where public.is_admin();

-- =============================================================================
-- Permissões
-- =============================================================================
grant usage on schema public to anon, authenticated;
grant select on public.categories to anon;
grant usage, select on all sequences in schema public to authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;
grant select on public.job_candidates, public.my_proposals, public.my_job_history,
               public.provider_reviews, public.admin_users to authenticated;

-- Funções internas não devem ser chamadas pelo app.
revoke execute on function public.notify(uuid, public.notification_type, text, text, uuid, uuid) from public, anon, authenticated;
revoke execute on function public.refresh_provider_rating(uuid) from public, anon, authenticated;
revoke execute on function public.handle_new_user() from public, anon, authenticated;

-- Realtime para o sino de notificações e para novas propostas.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.notifications, public.proposals;
  end if;
end $$;
