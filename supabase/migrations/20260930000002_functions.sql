-- =============================================================================
-- Migration 2: funções auxiliares, triggers e regras de negócio (RPCs)
--
-- Regra geral: mudanças de STATUS (aceitar proposta, concluir, cancelar...)
-- acontecem só via RPC (funções abaixo), nunca por UPDATE direto do app.
-- No FlutterFlow elas são chamadas com a ação "Supabase > Call RPC"/API Call.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Helpers
-- -----------------------------------------------------------------------------

-- true quando a chamada vem direto do app (PostgREST) e não de uma função
-- "security definer" do próprio banco.
create or replace function public.is_app_request()
returns boolean
language sql stable
as $$
  select current_user in ('authenticated', 'anon');
$$;

create or replace function public.is_admin()
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'admin' and not is_blocked
  );
$$;

create or replace function public.is_active_user()
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and not is_blocked
  );
$$;

create or replace function public.is_provider()
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.profiles p
    join public.provider_profiles pp on pp.profile_id = p.id
    where p.id = auth.uid() and p.role in ('prestador', 'admin') and not p.is_blocked
  );
$$;

-- O usuário logado e "target" estão ligados por um serviço já contratado?
-- (usado para liberar telefone/WhatsApp e endereço)
create or replace function public.has_hired_relationship(target uuid)
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.jobs j
    join public.proposals pr on pr.id = j.selected_proposal_id
    where j.status in ('em_andamento', 'concluido')
      and (
        (j.client_id = auth.uid() and pr.provider_id = target) or
        (pr.provider_id = auth.uid() and j.client_id = target)
      )
  );
$$;

create or replace function public.is_selected_provider(p_job_id uuid)
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.jobs j
    join public.proposals pr on pr.id = j.selected_proposal_id
    where j.id = p_job_id and pr.provider_id = auth.uid()
  );
$$;

create or replace function public.owns_job(p_job_id uuid)
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (select 1 from public.jobs where id = p_job_id and client_id = auth.uid());
$$;

create or replace function public.notify(
  p_user_id uuid,
  p_type public.notification_type,
  p_title text,
  p_body text default null,
  p_job_id uuid default null,
  p_proposal_id uuid default null
) returns void
language sql security definer
set search_path = public
as $$
  insert into public.notifications (user_id, type, title, body, job_id, proposal_id)
  values (p_user_id, p_type, p_title, p_body, p_job_id, p_proposal_id);
$$;

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger profiles_updated_at          before update on public.profiles          for each row execute function public.set_updated_at();
create trigger profile_contacts_updated_at  before update on public.profile_contacts  for each row execute function public.set_updated_at();
create trigger provider_profiles_updated_at before update on public.provider_profiles for each row execute function public.set_updated_at();
create trigger jobs_updated_at              before update on public.jobs              for each row execute function public.set_updated_at();
create trigger proposals_updated_at         before update on public.proposals         for each row execute function public.set_updated_at();

-- -----------------------------------------------------------------------------
-- Cadastro: cria o perfil automaticamente quando alguém se registra.
-- No FlutterFlow, envie no signUp: data = { "full_name": "...", "role": "cliente" | "prestador" }
-- -----------------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer
set search_path = public
as $$
declare
  v_role public.user_role;
begin
  -- "admin" nunca pode ser escolhido no cadastro.
  v_role := case new.raw_user_meta_data ->> 'role'
              when 'prestador' then 'prestador'::public.user_role
              else 'cliente'::public.user_role
            end;

  insert into public.profiles (id, role, full_name, city)
  values (
    new.id,
    v_role,
    coalesce(new.raw_user_meta_data ->> 'full_name', ''),
    new.raw_user_meta_data ->> 'city'
  );

  insert into public.profile_contacts (profile_id, email, phone)
  values (new.id, new.email, new.raw_user_meta_data ->> 'phone');

  if v_role = 'prestador' then
    insert into public.provider_profiles (profile_id) values (new.id);
  end if;

  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Permite um cliente virar prestador (ou voltar a ser cliente) sem nova conta.
create or replace function public.set_my_role(p_role public.user_role)
returns void
language plpgsql security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'Não autenticado';
  end if;
  if p_role = 'admin' then
    raise exception 'Operação não permitida';
  end if;

  update public.profiles set role = p_role where id = auth.uid() and role <> 'admin';

  if p_role = 'prestador' then
    insert into public.provider_profiles (profile_id) values (auth.uid())
    on conflict (profile_id) do nothing;
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- Proteção de campos que o app não pode alterar diretamente
-- -----------------------------------------------------------------------------
create or replace function public.protect_profile_fields()
returns trigger
language plpgsql
as $$
begin
  if public.is_app_request() and not public.is_admin() then
    new.role       := old.role;
    new.is_blocked := old.is_blocked;
    new.created_at := old.created_at;
  end if;
  return new;
end;
$$;

create trigger profiles_protect before update on public.profiles
  for each row execute function public.protect_profile_fields();

create or replace function public.protect_provider_fields()
returns trigger
language plpgsql
as $$
begin
  if public.is_app_request() and not public.is_admin() then
    new.is_verified    := old.is_verified;
    new.rating_avg     := old.rating_avg;
    new.rating_count   := old.rating_count;
    new.jobs_completed := old.jobs_completed;
  end if;
  return new;
end;
$$;

create trigger provider_profiles_protect before update on public.provider_profiles
  for each row execute function public.protect_provider_fields();

create or replace function public.protect_job_fields()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'INSERT' then
    if public.is_app_request() then
      new.status               := 'aberto';
      new.selected_proposal_id := null;
      new.proposals_count      := 0;
      new.started_at           := null;
      new.completed_at         := null;
      new.cancelled_at         := null;
    end if;
    return new;
  end if;

  if public.is_app_request() and not public.is_admin() then
    if old.status <> 'aberto' then
      raise exception 'Só é possível editar serviços com status "aberto"';
    end if;
    new.client_id            := old.client_id;
    new.status               := old.status;
    new.selected_proposal_id := old.selected_proposal_id;
    new.proposals_count      := old.proposals_count;
    new.created_at           := old.created_at;
    new.started_at           := old.started_at;
    new.completed_at         := old.completed_at;
    new.cancelled_at         := old.cancelled_at;
  end if;
  return new;
end;
$$;

create trigger jobs_protect before insert or update on public.jobs
  for each row execute function public.protect_job_fields();

create or replace function public.protect_proposal_fields()
returns trigger
language plpgsql
as $$
declare
  v_job public.jobs;
begin
  select * into v_job from public.jobs where id = new.job_id;

  if tg_op = 'INSERT' then
    if public.is_app_request() then
      if v_job.status <> 'aberto' then
        raise exception 'Este serviço não está mais recebendo propostas';
      end if;
      if v_job.client_id = new.provider_id then
        raise exception 'Você não pode enviar proposta para o seu próprio serviço';
      end if;
      new.status := 'pendente';
    end if;
    return new;
  end if;

  if public.is_app_request() and not public.is_admin() then
    if old.status <> 'pendente' or v_job.status <> 'aberto' then
      raise exception 'Esta proposta não pode mais ser editada';
    end if;
    new.job_id      := old.job_id;
    new.provider_id := old.provider_id;
    new.status      := old.status;
    new.created_at  := old.created_at;
  end if;
  return new;
end;
$$;

create trigger proposals_protect before insert or update on public.proposals
  for each row execute function public.protect_proposal_fields();

-- -----------------------------------------------------------------------------
-- Notificações automáticas
-- -----------------------------------------------------------------------------

-- Nova proposta -> avisa o cliente e atualiza o contador.
create or replace function public.on_proposal_created()
returns trigger
language plpgsql security definer
set search_path = public
as $$
declare
  v_job      public.jobs;
  v_provider text;
begin
  update public.jobs set proposals_count = proposals_count + 1
  where id = new.job_id
  returning * into v_job;

  select full_name into v_provider from public.profiles where id = new.provider_id;

  perform public.notify(
    v_job.client_id, 'nova_proposta',
    'Nova proposta recebida',
    coalesce(nullif(v_provider, ''), 'Um prestador') || ' se candidatou para "' || v_job.title || '"',
    v_job.id, new.id
  );
  return new;
end;
$$;

create trigger proposals_after_insert after insert on public.proposals
  for each row execute function public.on_proposal_created();

-- Novo serviço publicado -> avisa prestadores da mesma categoria e cidade.
create or replace function public.on_job_created()
returns trigger
language plpgsql security definer
set search_path = public
as $$
begin
  insert into public.notifications (user_id, type, title, body, job_id)
  select pp.profile_id,
         'novo_servico_na_regiao',
         'Novo serviço na sua região',
         new.title || ' - ' || new.city,
         new.id
  from public.provider_profiles pp
  join public.provider_categories pc on pc.provider_id = pp.profile_id and pc.category_id = new.category_id
  join public.profiles p on p.id = pp.profile_id
  where pp.is_available
    and not p.is_blocked
    and pp.profile_id <> new.client_id
    and exists (
      select 1 from unnest(pp.service_cities) c
      where lower(trim(c)) = lower(trim(new.city))
    );
  return new;
end;
$$;

create trigger jobs_after_insert after insert on public.jobs
  for each row execute function public.on_job_created();

-- -----------------------------------------------------------------------------
-- RPCs do fluxo principal
-- -----------------------------------------------------------------------------

-- Cliente escolhe um prestador.
create or replace function public.accept_proposal(p_proposal_id uuid)
returns public.jobs
language plpgsql security definer
set search_path = public
as $$
declare
  v_prop public.proposals;
  v_job  public.jobs;
  r      record;
begin
  select * into v_prop from public.proposals where id = p_proposal_id for update;
  if not found then
    raise exception 'Proposta não encontrada';
  end if;

  select * into v_job from public.jobs where id = v_prop.job_id for update;
  if v_job.client_id <> auth.uid() then
    raise exception 'Apenas o dono do serviço pode escolher o prestador';
  end if;
  if v_job.status <> 'aberto' then
    raise exception 'Este serviço já tem um prestador escolhido ou foi encerrado';
  end if;
  if v_prop.status <> 'pendente' then
    raise exception 'Esta proposta não está mais disponível';
  end if;

  update public.proposals set status = 'aceita' where id = v_prop.id;

  for r in
    update public.proposals set status = 'recusada'
    where job_id = v_job.id and id <> v_prop.id and status = 'pendente'
    returning id, provider_id
  loop
    perform public.notify(r.provider_id, 'proposta_recusada',
      'Proposta não selecionada',
      'O cliente escolheu outro prestador para "' || v_job.title || '"',
      v_job.id, r.id);
  end loop;

  update public.jobs
     set status = 'em_andamento', selected_proposal_id = v_prop.id, started_at = now()
   where id = v_job.id
  returning * into v_job;

  perform public.notify(v_prop.provider_id, 'proposta_aceita',
    'Você foi escolhido! 🎉',
    'Sua proposta para "' || v_job.title || '" foi aceita. Veja o contato do cliente no app.',
    v_job.id, v_prop.id);

  return v_job;
end;
$$;

-- Cliente recusa uma proposta específica (opcional).
create or replace function public.reject_proposal(p_proposal_id uuid)
returns void
language plpgsql security definer
set search_path = public
as $$
declare
  v_prop public.proposals;
  v_job  public.jobs;
begin
  select * into v_prop from public.proposals where id = p_proposal_id for update;
  select * into v_job from public.jobs where id = v_prop.job_id;
  if v_job.client_id is distinct from auth.uid() then
    raise exception 'Apenas o dono do serviço pode recusar propostas';
  end if;
  if v_prop.status <> 'pendente' then
    raise exception 'Esta proposta não está pendente';
  end if;

  update public.proposals set status = 'recusada' where id = v_prop.id;
  perform public.notify(v_prop.provider_id, 'proposta_recusada',
    'Proposta não selecionada',
    'O cliente recusou sua proposta para "' || v_job.title || '"', v_job.id, v_prop.id);
end;
$$;

-- Prestador desiste de uma proposta pendente.
create or replace function public.withdraw_proposal(p_proposal_id uuid)
returns void
language plpgsql security definer
set search_path = public
as $$
declare
  v_prop public.proposals;
begin
  select * into v_prop from public.proposals where id = p_proposal_id for update;
  if v_prop.provider_id is distinct from auth.uid() then
    raise exception 'Proposta não encontrada';
  end if;
  if v_prop.status <> 'pendente' then
    raise exception 'Só é possível retirar propostas pendentes';
  end if;

  update public.proposals set status = 'retirada' where id = v_prop.id;
  update public.jobs set proposals_count = greatest(proposals_count - 1, 0) where id = v_prop.job_id;
end;
$$;

-- Cliente marca o serviço como concluído (libera a avaliação).
create or replace function public.complete_job(p_job_id uuid)
returns public.jobs
language plpgsql security definer
set search_path = public
as $$
declare
  v_job      public.jobs;
  v_provider uuid;
begin
  select * into v_job from public.jobs where id = p_job_id for update;
  if v_job.client_id is distinct from auth.uid() then
    raise exception 'Apenas o dono do serviço pode concluí-lo';
  end if;
  if v_job.status <> 'em_andamento' then
    raise exception 'Só serviços em andamento podem ser concluídos';
  end if;

  select provider_id into v_provider from public.proposals where id = v_job.selected_proposal_id;

  update public.jobs set status = 'concluido', completed_at = now()
  where id = v_job.id returning * into v_job;

  update public.provider_profiles set jobs_completed = jobs_completed + 1
  where profile_id = v_provider;

  perform public.notify(v_provider, 'servico_concluido',
    'Serviço concluído',
    'O cliente marcou "' || v_job.title || '" como concluído.', v_job.id, v_job.selected_proposal_id);

  return v_job;
end;
$$;

-- Cliente (ou admin) cancela um serviço aberto ou em andamento.
create or replace function public.cancel_job(p_job_id uuid, p_reason text default null)
returns public.jobs
language plpgsql security definer
set search_path = public
as $$
declare
  v_job public.jobs;
  r     record;
begin
  select * into v_job from public.jobs where id = p_job_id for update;
  if not found or (v_job.client_id <> auth.uid() and not public.is_admin()) then
    raise exception 'Serviço não encontrado';
  end if;
  if v_job.status not in ('aberto', 'em_andamento') then
    raise exception 'Este serviço já foi encerrado';
  end if;

  for r in
    update public.proposals set status = 'recusada'
    where job_id = v_job.id and status in ('pendente', 'aceita')
    returning id, provider_id
  loop
    perform public.notify(r.provider_id, 'servico_cancelado',
      'Serviço cancelado',
      '"' || v_job.title || '" foi cancelado' || coalesce(': ' || p_reason, '.'),
      v_job.id, r.id);
  end loop;

  update public.jobs set status = 'cancelado', cancelled_at = now()
  where id = v_job.id returning * into v_job;

  return v_job;
end;
$$;

-- -----------------------------------------------------------------------------
-- Avaliações
-- -----------------------------------------------------------------------------
create or replace function public.prepare_review()
returns trigger
language plpgsql security definer
set search_path = public
as $$
declare
  v_job public.jobs;
begin
  select * into v_job from public.jobs where id = new.job_id;
  if v_job.status <> 'concluido' then
    raise exception 'Só é possível avaliar serviços concluídos';
  end if;
  -- Preenche automaticamente os envolvidos a partir do serviço.
  new.client_id := v_job.client_id;
  select provider_id into new.provider_id from public.proposals where id = v_job.selected_proposal_id;
  if tg_op = 'INSERT' then
    new.is_hidden := false;
  elsif public.is_app_request() and not public.is_admin() then
    new.is_hidden  := old.is_hidden;
    new.created_at := old.created_at;
  end if;
  return new;
end;
$$;

create trigger reviews_prepare before insert or update on public.reviews
  for each row execute function public.prepare_review();

create or replace function public.refresh_provider_rating(p_provider_id uuid)
returns void
language sql security definer
set search_path = public
as $$
  update public.provider_profiles pp
     set rating_avg   = coalesce(s.avg, 0),
         rating_count = coalesce(s.cnt, 0)
    from (
      select round(avg(rating)::numeric, 2) as avg, count(*)::int as cnt
      from public.reviews
      where provider_id = p_provider_id and not is_hidden
    ) s
   where pp.profile_id = p_provider_id;
$$;

create or replace function public.on_review_changed()
returns trigger
language plpgsql security definer
set search_path = public
as $$
begin
  if tg_op = 'DELETE' then
    perform public.refresh_provider_rating(old.provider_id);
    return old;
  end if;

  perform public.refresh_provider_rating(new.provider_id);

  if tg_op = 'INSERT' then
    perform public.notify(new.provider_id, 'nova_avaliacao',
      'Você recebeu uma avaliação',
      'Nota ' || new.rating || ' de 5', new.job_id);
  end if;
  return new;
end;
$$;

create trigger reviews_after_change after insert or update or delete on public.reviews
  for each row execute function public.on_review_changed();

-- -----------------------------------------------------------------------------
-- Notificações: marcar como lidas
-- -----------------------------------------------------------------------------
create or replace function public.mark_notification_read(p_notification_id uuid)
returns void
language sql security definer
set search_path = public
as $$
  update public.notifications set read_at = now()
  where id = p_notification_id and user_id = auth.uid() and read_at is null;
$$;

create or replace function public.mark_all_notifications_read()
returns void
language sql security definer
set search_path = public
as $$
  update public.notifications set read_at = now()
  where user_id = auth.uid() and read_at is null;
$$;

create or replace function public.unread_notifications_count()
returns integer
language sql stable security definer
set search_path = public
as $$
  select count(*)::int from public.notifications where user_id = auth.uid() and read_at is null;
$$;

-- -----------------------------------------------------------------------------
-- Busca de serviços (lista + filtros por categoria, cidade, texto e orçamento)
-- -----------------------------------------------------------------------------
create or replace function public.search_jobs(
  p_query       text    default null,
  p_category_id bigint  default null,
  p_city        text    default null,
  p_min_budget  numeric default null,
  p_limit       integer default 20,
  p_offset      integer default 0
)
returns table (
  id               uuid,
  title            text,
  description      text,
  category_id      bigint,
  category_name    text,
  category_icon    text,
  city             text,
  neighborhood     text,
  budget_min       numeric,
  budget_max       numeric,
  desired_date     date,
  urgency          text,
  photos           text[],
  proposals_count  integer,
  created_at       timestamptz,
  client_id        uuid,
  client_name      text,
  client_avatar    text,
  already_applied  boolean
)
language sql stable
set search_path = public
as $$
  select j.id, j.title, j.description, j.category_id, c.name, c.icon,
         j.city, j.neighborhood, j.budget_min, j.budget_max, j.desired_date, j.urgency,
         j.photos, j.proposals_count, j.created_at,
         j.client_id, p.full_name, p.avatar_url,
         exists (select 1 from public.proposals pr
                 where pr.job_id = j.id and pr.provider_id = auth.uid()) as already_applied
  from public.jobs j
  join public.categories c on c.id = j.category_id
  join public.profiles p   on p.id = j.client_id
  where j.status = 'aberto'
    and (p_category_id is null or j.category_id = p_category_id)
    and (p_city is null or p_city = '' or j.city ilike '%' || p_city || '%')
    and (p_min_budget is null or coalesce(j.budget_max, j.budget_min) >= p_min_budget)
    and (p_query is null or p_query = ''
         or j.title ilike '%' || p_query || '%'
         or j.description ilike '%' || p_query || '%')
  order by j.created_at desc
  limit least(greatest(p_limit, 1), 100)
  offset greatest(p_offset, 0);
$$;

-- Busca de prestadores (para o cliente navegar/convidar).
create or replace function public.search_providers(
  p_category_id bigint  default null,
  p_city        text    default null,
  p_limit       integer default 20,
  p_offset      integer default 0
)
returns table (
  id              uuid,
  full_name       text,
  avatar_url      text,
  headline        text,
  city            text,
  service_cities  text[],
  rating_avg      numeric,
  rating_count    integer,
  jobs_completed  integer,
  is_verified     boolean,
  categories      text[]
)
language sql stable
set search_path = public
as $$
  select p.id, p.full_name, p.avatar_url, pp.headline, p.city, pp.service_cities,
         pp.rating_avg, pp.rating_count, pp.jobs_completed, pp.is_verified,
         coalesce(array(
           select c.name from public.provider_categories pc
           join public.categories c on c.id = pc.category_id
           where pc.provider_id = p.id order by c.sort_order
         ), '{}')
  from public.provider_profiles pp
  join public.profiles p on p.id = pp.profile_id
  where not p.is_blocked
    and pp.is_available
    and (p_category_id is null or exists (
          select 1 from public.provider_categories pc
          where pc.provider_id = p.id and pc.category_id = p_category_id))
    and (p_city is null or p_city = ''
         or p.city ilike '%' || p_city || '%'
         or exists (select 1 from unnest(pp.service_cities) sc where sc ilike '%' || p_city || '%'))
  order by pp.is_verified desc, pp.rating_avg desc, pp.jobs_completed desc
  limit least(greatest(p_limit, 1), 100)
  offset greatest(p_offset, 0);
$$;

-- Define as categorias atendidas pelo prestador logado (substitui a lista).
create or replace function public.set_my_categories(p_category_ids bigint[])
returns void
language plpgsql security definer
set search_path = public
as $$
begin
  if not public.is_provider() then
    raise exception 'Apenas prestadores podem definir categorias';
  end if;
  delete from public.provider_categories where provider_id = auth.uid();
  insert into public.provider_categories (provider_id, category_id)
  select auth.uid(), unnest(p_category_ids)
  on conflict do nothing;
end;
$$;

-- -----------------------------------------------------------------------------
-- Painel administrativo
-- -----------------------------------------------------------------------------
create or replace function public.admin_set_user_blocked(p_user_id uuid, p_blocked boolean)
returns void
language plpgsql security definer
set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Acesso negado'; end if;
  update public.profiles set is_blocked = p_blocked where id = p_user_id;
end;
$$;

create or replace function public.admin_set_provider_verified(p_user_id uuid, p_verified boolean)
returns void
language plpgsql security definer
set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Acesso negado'; end if;
  update public.provider_profiles set is_verified = p_verified where profile_id = p_user_id;
end;
$$;

create or replace function public.admin_set_review_hidden(p_review_id uuid, p_hidden boolean)
returns void
language plpgsql security definer
set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Acesso negado'; end if;
  update public.reviews set is_hidden = p_hidden where id = p_review_id;
end;
$$;

create or replace function public.admin_dashboard()
returns json
language plpgsql stable security definer
set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Acesso negado'; end if;
  return json_build_object(
    'total_clientes',        (select count(*) from profiles where role = 'cliente'),
    'total_prestadores',     (select count(*) from profiles where role = 'prestador'),
    'usuarios_bloqueados',   (select count(*) from profiles where is_blocked),
    'novos_usuarios_7d',     (select count(*) from profiles where created_at > now() - interval '7 days'),
    'servicos_abertos',      (select count(*) from jobs where status = 'aberto'),
    'servicos_andamento',    (select count(*) from jobs where status = 'em_andamento'),
    'servicos_concluidos',   (select count(*) from jobs where status = 'concluido'),
    'servicos_cancelados',   (select count(*) from jobs where status = 'cancelado'),
    'servicos_novos_7d',     (select count(*) from jobs where created_at > now() - interval '7 days'),
    'propostas_total',       (select count(*) from proposals),
    'media_propostas_por_servico', (select round(avg(proposals_count)::numeric, 2) from jobs),
    'avaliacao_media',       (select round(avg(rating)::numeric, 2) from reviews where not is_hidden),
    'denuncias_abertas',     (select count(*) from reports where status in ('aberta', 'em_analise')),
    'servicos_por_categoria', (
      select coalesce(json_agg(x order by x.total desc), '[]'::json) from (
        select c.name as categoria, count(j.id) as total
        from categories c left join jobs j on j.category_id = c.id
        group by c.name
      ) x
    )
  );
end;
$$;
