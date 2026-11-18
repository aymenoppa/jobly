-- Postcards: what Lob did with a card after it accepted it.
--
-- Lob answers "made" before it has drawn the card. It draws it afterwards, fetching the front's
-- picture from this server, and a card it can't draw becomes `failed` at Lob with a reason
-- (help.lob.com → Failed order visibility). Until now nothing looked, so such a card went on
-- showing as mailed, and deleting the campaign took the picture away while Lob might still want it.
--
--   postcard_recipients.proof_url / proof_at   Lob's own picture of the card (a PDF), kept when the
--                             card is made. Lob's links stop working after 30 days.
--   postcard_recipients.lob_failed_at   when the hourly check found that Lob failed the card after
--                             accepting it; its status becomes failed, with Lob's reason.
--   postcard_campaigns.lob_checked_at   when Lob was last asked about the campaign's cards.
--   claim_postcard_checks     the campaigns to ask Lob about now: any with a card made in the last
--                             7 days, not asked in the last hour. Claimed, so two servers don't ask
--                             twice. The postcards task calls it (apps/api/src/services/postcards.ts).
--   postcard_campaign_guard   a campaign can't be deleted, by the office, until 7 days after its
--                             last card was made: that's how long its front picture is kept
--                             reachable for Lob (longer than the longest Lob holds a card before
--                             printing it). The picture is served for as long as the campaign is.
--
-- supabase/tests/postcard_fixes_test.sql covers it.

alter table public.postcard_recipients
  add column proof_url text check (proof_url is null or (proof_url ~ '^https://' and length(proof_url) <= 2000)),
  add column proof_at timestamptz,
  add column lob_failed_at timestamptz;
comment on column public.postcard_recipients.proof_url is 'Lob''s PDF of the card as it drew it; the link works for 30 days from proof_at';
comment on column public.postcard_recipients.lob_failed_at is 'When Lob was found to have failed the card after accepting it';

alter table public.postcard_campaigns add column lob_checked_at timestamptz;
comment on column public.postcard_campaigns.lob_checked_at is 'When Lob was last asked whether any of the campaign''s cards failed';

-- From 20261113001400_postcards.sql, with two changes: what the check records is the server's too,
-- and a campaign whose cards were made in the last 7 days can't be deleted yet.
create or replace function private.postcard_campaign_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_last timestamptz;
begin
  if (select auth.role()) is distinct from 'authenticated' then
    return coalesce(new, old);
  end if;
  if tg_op = 'DELETE' then
    if old.status = 'sending' then
      raise exception 'A postcard campaign can''t be deleted while it''s being mailed' using errcode = '22023';
    end if;
    -- Lob fetches the front's picture from this server while it draws each card, and deleting the
    -- campaign takes the picture down. Kept for 7 days after the last card.
    select max(r.made_at) into v_last from public.postcard_recipients r where r.campaign_id = old.id and r.lob_id is not null;
    if v_last > now() - interval '7 days' then
      raise exception 'This campaign''s cards were made less than 7 days ago, and Lob may still need its picture. It can be deleted from %.', to_char(v_last + interval '7 days', 'FMMonth FMDD')
        using errcode = '22023';
    end if;
    return old;
  end if;
  if tg_op = 'UPDATE' and old.status <> 'draft' then
    raise exception 'Only draft postcard campaigns can be changed' using errcode = '22023';
  end if;
  new.status := 'draft';
  new.mode := null;
  new.image_token := null;
  new.image_path := null;
  new.started_at := null;
  new.finished_at := null;
  new.stopped_reason := null;
  new.recipients_count := 0;
  new.made_count := 0;
  new.failed_count := 0;
  new.lob_checked_at := null;
  -- A photo of another company's isn't this card's front.
  if new.front_attachment_id is not null
     and not exists (select 1 from public.attachments a where a.id = new.front_attachment_id and a.company_id = new.company_id) then
    raise exception 'That photo isn''t one of yours' using errcode = '22023';
  end if;
  return new;
end $$;

-- The campaigns whose cards Lob should be asked about now: sent with a key, with a card made in the
-- last 7 days, and not asked in the last hour. Marked as asked as they're handed out.
create function public.claim_postcard_checks(p_limit integer default 5)
returns table (id uuid, company_id uuid, mode text, started_at timestamptz)
language sql security definer set search_path = '' as $$
  update public.postcard_campaigns c
     set lob_checked_at = now()
   where c.id in (
     select x.id from public.postcard_campaigns x
      where x.status <> 'draft'
        and (x.lob_checked_at is null or x.lob_checked_at < now() - interval '1 hour')
        and exists (select 1 from public.postcard_recipients r
                     where r.campaign_id = x.id and r.status = 'made' and r.made_at > now() - interval '7 days')
      order by x.lob_checked_at nulls first, x.started_at
      limit least(greatest(coalesce(p_limit, 5), 1), 50)
      for update skip locked)
  returning c.id, c.company_id, c.mode, c.started_at
$$;
revoke execute on function public.claim_postcard_checks(integer) from public, anon, authenticated;
grant execute on function public.claim_postcard_checks(integer) to service_role;

notify pgrst, 'reload schema';
