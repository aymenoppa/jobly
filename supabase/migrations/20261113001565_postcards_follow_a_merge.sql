-- Postcards: a merged client's postcard history follows them to the client that's kept.
--
-- merge_clients (20261106000100_client_merge.sql) moves every record of the merged client to the
-- kept one and then deletes the merged client. It was written before postcards, so their cards were
-- left behind: postcard_recipients.client_id went null when the client was deleted, the cards
-- dropped out of the kept client's history and of what the campaign brought in, and a card still
-- waiting was skipped as "Client was deleted".
--
-- Rather than redefine merge_clients (a long function other work also changes), the move is made
-- here, as the merged client is deleted: merge_clients keeps jobly.merge set to
-- '<merged id>><kept id>' until after that delete, which is how its own guards know a merge is
-- under way (private.merging_clients). A delete that isn't a merge moves nothing.
--
-- A campaign both clients were on keeps the kept client's own card as theirs (a client is on a
-- campaign once); the merged client's card there stays, with no client, as it does today.
-- supabase/tests/postcard_fixes_test.sql covers it.

create function private.postcards_follow_merge() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_merge text := coalesce(current_setting('jobly.merge', true), '');
  v_keep uuid;
begin
  if v_merge like old.id::text || '>%' then
    v_keep := nullif(split_part(v_merge, '>', 2), '')::uuid;
    update public.postcard_recipients r
       set client_id = v_keep
     where r.company_id = old.company_id and r.client_id = old.id
       and exists (select 1 from public.clients k where k.company_id = old.company_id and k.id = v_keep)
       and not exists (select 1 from public.postcard_recipients k where k.campaign_id = r.campaign_id and k.client_id = v_keep);
  end if;
  return old;
end $$;
revoke all on function private.postcards_follow_merge() from public;
create trigger postcards_follow_merge before delete on public.clients
  for each row execute function private.postcards_follow_merge();
