-- =============================================================================
-- Migration 4: Storage (fotos de perfil e fotos dos serviços)
-- Caminho dos arquivos: <bucket>/<user_id>/<nome-do-arquivo>
-- No FlutterFlow: "Upload Media to Supabase" com o bucket abaixo e
-- o path começando pelo id do usuário logado.
-- =============================================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('avatars',    'avatars',    true, 5242880, array['image/jpeg', 'image/png', 'image/webp']),
  ('job-photos', 'job-photos', true, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

create policy "storage_public_read" on storage.objects
  for select using (bucket_id in ('avatars', 'job-photos'));

create policy "storage_insert_own_folder" on storage.objects
  for insert to authenticated
  with check (
    bucket_id in ('avatars', 'job-photos')
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "storage_update_own_folder" on storage.objects
  for update to authenticated
  using (bucket_id in ('avatars', 'job-photos') and (storage.foldername(name))[1] = auth.uid()::text);

create policy "storage_delete_own_folder" on storage.objects
  for delete to authenticated
  using (bucket_id in ('avatars', 'job-photos') and (storage.foldername(name))[1] = auth.uid()::text);
