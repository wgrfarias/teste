-- Teste de ponta a ponta do fluxo do MVP (rodar com: supabase/tests/run.sh)
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

-- Usuários de teste --------------------------------------------------------
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-00000000000a', 'admin@teste.com',  '{"full_name":"Admin","role":"admin"}'),
  ('00000000-0000-0000-0000-00000000000c', 'maria@teste.com',  '{"full_name":"Maria Cliente","role":"cliente","city":"Pequenópolis","phone":"11999990000"}'),
  ('00000000-0000-0000-0000-000000000001', 'joao@teste.com',   '{"full_name":"João Eletricista","role":"prestador","city":"Pequenópolis"}'),
  ('00000000-0000-0000-0000-000000000002', 'pedro@teste.com',  '{"full_name":"Pedro Eletricista","role":"prestador","city":"Pequenópolis"}');

-- "admin" no cadastro deve virar cliente; promovemos manualmente como no seed.
do $$ begin
  assert (select role from public.profiles where id = '00000000-0000-0000-0000-00000000000a') = 'cliente',
    'cadastro não pode criar admin';
end $$;
update public.profiles set role = 'admin' where id = '00000000-0000-0000-0000-00000000000a';

-- Helper para "logar" como alguém
create or replace function pg_temp.login(p uuid) returns void language sql as $$
  select set_config('request.jwt.claim.sub', p::text, false);
$$;

-- Prestadores configuram perfil ---------------------------------------------
set role authenticated;
select pg_temp.login('00000000-0000-0000-0000-000000000001');
update public.provider_profiles
   set headline = 'Eletricista há 10 anos', service_cities = '{Pequenópolis}',
       rating_avg = 5, is_verified = true   -- devem ser ignorados
 where profile_id = auth.uid();
select public.set_my_categories(array[(select id from public.categories where slug = 'eletricista')]);
do $$ begin
  assert (select is_verified from public.provider_profiles where profile_id = auth.uid()) = false, 'prestador não pode se verificar';
  assert (select rating_avg from public.provider_profiles where profile_id = auth.uid()) = 0, 'prestador não pode alterar nota';
end $$;

select pg_temp.login('00000000-0000-0000-0000-000000000002');
update public.provider_profiles set service_cities = '{pequenópolis}' where profile_id = auth.uid();
select public.set_my_categories(array[(select id from public.categories where slug = 'eletricista')]);

-- Cliente tenta virar admin: ignorado -----------------------------------------
select pg_temp.login('00000000-0000-0000-0000-00000000000c');
update public.profiles set role = 'admin', full_name = 'Maria Silva' where id = auth.uid();
do $$ begin
  assert (select role from public.profiles where id = auth.uid()) = 'cliente', 'cliente virou admin!';
  assert (select full_name from public.profiles where id = auth.uid()) = 'Maria Silva', 'nome não atualizado';
end $$;

-- Cliente publica um serviço ---------------------------------------------------
insert into public.jobs (id, client_id, category_id, title, description, city, neighborhood, budget_min, budget_max, status)
values ('10000000-0000-0000-0000-000000000001', auth.uid(),
        (select id from public.categories where slug = 'eletricista'),
        'Trocar chuveiro elétrico', 'Chuveiro queimou, preciso trocar e revisar a fiação.',
        'Pequenópolis', 'Centro', 80, 200, 'concluido');  -- status forçado para "aberto"
insert into public.job_addresses (job_id, street, number) values ('10000000-0000-0000-0000-000000000001', 'Rua das Flores', '123');

do $$ begin
  assert (select status from public.jobs where id = '10000000-0000-0000-0000-000000000001') = 'aberto', 'status inicial deveria ser aberto';
end $$;
reset role;
do $$ begin
  assert (select count(*) from public.notifications where type = 'novo_servico_na_regiao') = 2,
    'os 2 prestadores da cidade/categoria deveriam ser notificados';
end $$;
set role authenticated;

-- Prestadores veem o serviço na busca, mas não o endereço --------------------
select pg_temp.login('00000000-0000-0000-0000-000000000001');
do $$ begin
  assert (select count(*) from public.search_jobs(p_city => 'pequen')) = 1, 'busca por cidade falhou';
  assert (select count(*) from public.search_jobs(p_query => 'chuveiro', p_category_id => (select id from public.categories where slug='eletricista'))) = 1, 'busca por texto falhou';
  assert (select count(*) from public.search_jobs(p_category_id => (select id from public.categories where slug='pintor'))) = 0, 'filtro de categoria falhou';
  assert (select count(*) from public.job_addresses) = 0, 'prestador não deveria ver o endereço antes de ser escolhido';
  assert (select count(*) from public.profile_contacts where profile_id = '00000000-0000-0000-0000-00000000000c') = 0, 'telefone do cliente vazou';
end $$;

-- Prestadores enviam propostas -----------------------------------------------------
insert into public.proposals (id, job_id, provider_id, price, message, estimated_days)
values ('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', auth.uid(), 150, 'Faço hoje à tarde, levo o material.', 1);

select pg_temp.login('00000000-0000-0000-0000-000000000002');
insert into public.proposals (id, job_id, provider_id, price, message)
values ('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', auth.uid(), 120, 'Posso ir amanhã cedo.');
do $$ begin
  assert (select count(*) from public.proposals) = 1, 'prestador só deveria ver a própria proposta';
  assert (select already_applied from public.search_jobs()) = true, 'already_applied deveria ser true';
end $$;

-- Cliente não pode mandar proposta pra si mesmo; nem cliente sem perfil de prestador
select pg_temp.login('00000000-0000-0000-0000-00000000000c');
do $$ begin
  begin
    insert into public.proposals (job_id, provider_id, message)
    values ('10000000-0000-0000-0000-000000000001', auth.uid(), 'teste inválido');
    raise exception 'deveria ter falhado';
  exception when insufficient_privilege or raise_exception then
    if sqlerrm = 'deveria ter falhado' then raise; end if;
  end;
end $$;

-- Cliente vê candidatos e escolhe ------------------------------------------------
do $$ begin
  assert (select count(*) from public.job_candidates where job_id = '10000000-0000-0000-0000-000000000001') = 2, 'cliente deveria ver 2 candidatos';
  assert (select proposals_count from public.jobs where id = '10000000-0000-0000-0000-000000000001') = 2, 'contador de propostas';
  assert (select count(*) from public.notifications where type = 'nova_proposta') = 2, 'cliente deveria ter 2 notificações';
end $$;

-- Cliente não pode "pular" o fluxo via UPDATE direto
update public.jobs set status = 'concluido' where id = '10000000-0000-0000-0000-000000000001';
do $$ begin
  assert (select status from public.jobs where id = '10000000-0000-0000-0000-000000000001') = 'aberto', 'status mudou por update direto';
end $$;

select public.accept_proposal('20000000-0000-0000-0000-000000000001');
do $$ begin
  assert (select status from public.jobs where id = '10000000-0000-0000-0000-000000000001') = 'em_andamento';
  assert (select status from public.proposals where id = '20000000-0000-0000-0000-000000000002') = 'recusada', 'outra proposta deveria ser recusada';
  assert (select count(*) from public.profile_contacts where profile_id = '00000000-0000-0000-0000-000000000001') = 1, 'cliente deveria ver contato do prestador escolhido';
  assert (select count(*) from public.profile_contacts where profile_id = '00000000-0000-0000-0000-000000000002') = 0, 'cliente não deveria ver contato do recusado';
end $$;

-- Prestador escolhido vê endereço e telefone; o recusado não ---------------------
select pg_temp.login('00000000-0000-0000-0000-000000000001');
do $$ begin
  assert (select street from public.job_addresses) = 'Rua das Flores', 'prestador escolhido deveria ver endereço';
  assert (select phone from public.profile_contacts where profile_id = '00000000-0000-0000-0000-00000000000c') = '11999990000', 'prestador escolhido deveria ver telefone';
  assert (select count(*) from public.notifications where type = 'proposta_aceita') = 1;
end $$;
select pg_temp.login('00000000-0000-0000-0000-000000000002');
do $$ begin
  assert (select count(*) from public.job_addresses) = 0, 'prestador recusado viu endereço';
  assert (select proposal_status from public.my_proposals) = 'recusada';
  assert (select count(*) from public.notifications where type = 'proposta_recusada') = 1;
end $$;

-- Avaliação antes de concluir deve falhar --------------------------------------
select pg_temp.login('00000000-0000-0000-0000-00000000000c');
do $$ begin
  begin
    insert into public.reviews (job_id, rating) values ('10000000-0000-0000-0000-000000000001', 5);
    raise exception 'deveria ter falhado';
  exception when raise_exception then
    if sqlerrm = 'deveria ter falhado' then raise; end if;
  end;
end $$;

-- Concluir e avaliar -----------------------------------------------------------
select public.complete_job('10000000-0000-0000-0000-000000000001');
do $$ begin
  assert (select can_review from public.my_job_history) = true, 'deveria poder avaliar';
end $$;
insert into public.reviews (job_id, rating, comment) values ('10000000-0000-0000-0000-000000000001', 4, 'Rápido e caprichoso.');

select pg_temp.login('00000000-0000-0000-0000-000000000001');
do $$ begin
  assert (select rating_avg from public.provider_profiles where profile_id = auth.uid()) = 4.00, 'média deveria ser 4';
  assert (select rating_count from public.provider_profiles where profile_id = auth.uid()) = 1;
  assert (select jobs_completed from public.provider_profiles where profile_id = auth.uid()) = 1;
  assert (select my_role from public.my_job_history) = 'prestador';
  assert (select count(*) from public.notifications where type = 'nova_avaliacao') = 1;
end $$;
select public.mark_all_notifications_read();
do $$ begin
  assert public.unread_notifications_count() = 0;
end $$;

-- Painel admin ---------------------------------------------------------------------
do $$ begin
  begin
    perform public.admin_dashboard();
    raise exception 'deveria ter falhado';
  exception when raise_exception then
    if sqlerrm = 'deveria ter falhado' then raise; end if;
  end;
  assert (select count(*) from public.admin_users) = 0, 'não-admin viu lista de usuários';
end $$;

select pg_temp.login('00000000-0000-0000-0000-00000000000a');
select public.admin_set_provider_verified('00000000-0000-0000-0000-000000000001', true);
select public.admin_set_user_blocked('00000000-0000-0000-0000-000000000002', true);
do $$
declare d json := public.admin_dashboard();
begin
  assert (d->>'servicos_concluidos')::int = 1, 'dashboard: concluídos';
  assert (d->>'total_prestadores')::int = 2, 'dashboard: prestadores';
  assert (select count(*) from public.admin_users) = 4, 'admin deveria ver todos';
  assert (select is_verified from public.provider_profiles where profile_id = '00000000-0000-0000-0000-000000000001');
end $$;

-- Usuário bloqueado não publica ------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-000000000002');
do $$ begin
  begin
    insert into public.jobs (client_id, category_id, title, description, city)
    values (auth.uid(), 1, 'Serviço teste', 'Descrição de teste longa', 'Pequenópolis');
    raise exception 'deveria ter falhado';
  exception when insufficient_privilege then null;
  end;
end $$;

-- Cancelamento --------------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-00000000000c');
insert into public.jobs (id, client_id, category_id, title, description, city)
values ('10000000-0000-0000-0000-000000000002', auth.uid(), 1, 'Instalar tomadas', 'Instalar 3 tomadas na cozinha', 'Pequenópolis');
select pg_temp.login('00000000-0000-0000-0000-000000000001');
insert into public.proposals (job_id, provider_id, price, message) values ('10000000-0000-0000-0000-000000000002', auth.uid(), 90, 'Consigo fazer amanhã.');
select pg_temp.login('00000000-0000-0000-0000-00000000000c');
select public.cancel_job('10000000-0000-0000-0000-000000000002', 'Resolvi de outro jeito');
select pg_temp.login('00000000-0000-0000-0000-000000000001');
do $$ begin
  assert (select count(*) from public.notifications where type = 'servico_cancelado') = 1;
  assert (select proposal_status from public.my_proposals where job_id = '10000000-0000-0000-0000-000000000002') = 'recusada';
end $$;

reset role;
\o
\echo '✅ Todos os testes do fluxo do MVP passaram.'
