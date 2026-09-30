-- Categorias iniciais (ajuste para a realidade da cidade do piloto).
insert into public.categories (name, slug, icon, sort_order) values
  ('Eletricista',          'eletricista',       'electrical_services', 1),
  ('Encanador',            'encanador',         'plumbing',            2),
  ('Pedreiro / Reformas',  'pedreiro',          'construction',        3),
  ('Pintor',               'pintor',            'format_paint',        4),
  ('Diarista / Limpeza',   'limpeza',           'cleaning_services',   5),
  ('Jardinagem',           'jardinagem',        'yard',                6),
  ('Montador de móveis',   'montador-moveis',   'chair',               7),
  ('Ar-condicionado',      'ar-condicionado',   'ac_unit',             8),
  ('Marido de aluguel',    'marido-de-aluguel', 'handyman',            9),
  ('Fretes e mudanças',    'fretes',            'local_shipping',     10),
  ('Técnico em informática','informatica',      'computer',           11),
  ('Outros',               'outros',            'more_horiz',         99)
on conflict (slug) do nothing;

-- Para tornar um usuário administrador (rode no SQL Editor do Supabase):
-- update public.profiles set role = 'admin' where id = (select id from auth.users where email = 'seu-email@exemplo.com');
