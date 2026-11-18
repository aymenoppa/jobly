-- Postcards: a card left half-made in a stopped campaign gets an answer.
--
-- While a campaign is being mailed, a recipient whose worker died mid-card (a restart during an
-- update, say) is claimed again and its card asked for again with the same idempotency key. Once
-- the campaign is stopped nothing claims its recipients anymore, so one left 'sending' stayed that
-- way: "Waiting" on the page for ever, and a card Lob did make never counted.
--
--   stuck_postcard_recipients   recipients still 'sending' in a cancelled campaign whose claim ran
--                               out more than ten minutes ago (long enough for the worker that held
--                               it to have recorded the card, and for Lob to list it).
--   settle_postcard_recipient   what became of one: made (Lob has the card, found by the campaign
--                               and recipient kept with it), skipped (Lob has no such card) or
--                               failed (Lob couldn't be asked, or failed it). Only such a recipient.
--
-- The postcards task asks Lob and settles them (apps/api/src/services/postcards.ts).
-- supabase/tests/postcard_fixes_test.sql covers it.

create function public.stuck_postcard_recipients(p_limit integer default 100)
returns table (id bigint, campaign_id uuid, company_id uuid, mode text, claimed_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select r.id, r.campaign_id, r.company_id, c.mode, r.claimed_at
    from public.postcard_recipients r
    join public.postcard_campaigns c on c.id = r.campaign_id
   where r.status = 'sending' and c.status = 'cancelled'
     and (r.locked_until is null or r.locked_until < now() - interval '10 minutes')
   order by r.campaign_id, r.id
   limit least(greatest(coalesce(p_limit, 100), 1), 500)
$$;

create function public.settle_postcard_recipient(p_id bigint, p_status text, p_error text default null, p_lob_id text default null, p_proof_url text default null)
returns boolean language plpgsql security definer set search_path = '' as $$
declare v_campaign uuid;
begin
  if p_status is null or p_status not in ('made', 'failed', 'skipped') then
    raise exception 'A postcard is made, failed or skipped' using errcode = '22023';
  end if;
  update public.postcard_recipients r
     set status = p_status, error = left(p_error, 1000),
         lob_id = coalesce(p_lob_id, r.lob_id),
         -- Made when it was claimed: that's when its card was asked for.
         made_at = case when p_status = 'made' then coalesce(r.claimed_at, now()) end,
         proof_url = case when p_proof_url ~ '^https://' then left(p_proof_url, 2000) else r.proof_url end,
         proof_at = case when p_proof_url ~ '^https://' then now() else r.proof_at end,
         claim_token = null, locked_until = null
   where r.id = p_id and r.status = 'sending'
     and (r.locked_until is null or r.locked_until < now())
     and exists (select 1 from public.postcard_campaigns c where c.id = r.campaign_id and c.status = 'cancelled')
  returning r.campaign_id into v_campaign;
  if v_campaign is null then
    return false;
  end if;
  perform public.count_postcard_campaign(v_campaign);
  return true;
end $$;

revoke execute on function public.stuck_postcard_recipients(integer), public.settle_postcard_recipient(bigint, text, text, text, text) from public, anon, authenticated;
grant execute on function public.stuck_postcard_recipients(integer), public.settle_postcard_recipient(bigint, text, text, text, text) to service_role;

notify pgrst, 'reload schema';
