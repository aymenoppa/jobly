-- Postcards by mail: a one-off campaign printed and mailed through the company's own Lob account
-- (Apps → Lob, apps/api/src/integrations/lob.ts; the sending is apps/api/src/services/postcards.ts).
--
--   postcard_campaigns    a card: its size, its front (a company photo, its drawn-on copy unless
--                         the office picks the original, or a picture uploaded to the campaign's
--                         own folder, <company>/postcards/<campaign>/), the message on its back and
--                         the segment it goes to, as email campaigns pick theirs. The office edits
--                         a draft in the browser; sending, and everything sending records, is the
--                         server's (postcard_campaign_guard). `mode` is the Lob key's, test or live,
--                         as it was when Send was pressed: a campaign never mails from another.
--   postcard_recipients   a row per client, made when it's sent, with the address it goes to then:
--                         one per client and campaign, never two. Each is claimed before its card is
--                         made, with a token, as campaign emails are (20261019001020_send_claims.sql),
--                         and carries its own idempotency key, so a card tried again after a crash
--                         is the card Lob already made. A claim left for more than 12 hours (longer
--                         than Lob keeps a key) isn't tried again: it fails, asking someone to look
--                         in Lob first.
--
-- Who gets one: the same segments as email campaigns (statuses, tags, cities, services, recurring
-- work, no visit lately), then only clients with a complete US mailing address (their billing
-- address, else their first property's that is complete), never an archived client and never one
-- who opted out of marketing. The rest are counted with why (public.postcard_audience_summary).
-- packages/core/src/postcards.ts reads addresses the same way.
--
-- What a postcard campaign brought in: paid invoices of clients it was mailed to, made after the card
-- and within 90 days of it, before tax and retainage (cards have no link to click, so there's no
-- booking to follow, as email campaigns have). Only cards a live key mailed count.
--
-- supabase/tests/postcards_test.sql covers it.

-- ---------------------------------------------------------------------------------------------
-- Campaigns
-- ---------------------------------------------------------------------------------------------

create table public.postcard_campaigns (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  name text not null check (length(trim(name)) between 1 and 120),
  size text not null default '4x6' check (size in ('4x6', '6x9', '6x11')),
  front_attachment_id uuid references public.attachments (id) on delete set null,
  -- The photo's drawn-on copy, when it has one; false for the photo as taken.
  front_marked boolean not null default true,
  front_path text check (front_path is null or (starts_with(front_path, company_id::text || '/postcards/') and front_path !~ '(^|/)\.\.?(/|$)')),
  message text not null default '' check (length(message) <= 2000),
  audience jsonb not null default '{}' check (jsonb_typeof(audience) = 'object'),
  status text not null default 'draft' check (status in ('draft', 'sending', 'sent', 'cancelled')),
  mode text check (mode in ('test', 'live')),
  -- The front as Lob fetches it while the cards are made: a copy without EXIF, at an address that
  -- names nothing (/api/public/postcards/<token>.jpg).
  image_token text unique check (image_token ~ '^[A-Za-z0-9_-]{32}$'),
  image_path text,
  started_at timestamptz,
  finished_at timestamptz,
  stopped_reason text check (length(stopped_reason) <= 500),
  recipients_count integer not null default 0,
  made_count integer not null default 0,
  failed_count integer not null default 0,
  created_by uuid references auth.users (id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (company_id, id),
  check ((status = 'draft') = (mode is null))
);
create index postcard_campaigns_company_idx on public.postcard_campaigns (company_id, created_at desc);
create index postcard_campaigns_sending_idx on public.postcard_campaigns (status) where status = 'sending';
comment on table public.postcard_campaigns is 'Postcard campaigns, printed and mailed through the company''s Lob account';

select private.add_touch_triggers(array['postcard_campaigns']);
select private.apply_policies('postcard_campaigns', '{owner,admin,office}', '{owner,admin,office}');
select private.restrict_area('postcard_campaigns', 'marketing', true);
revoke all on public.postcard_campaigns from anon;
revoke truncate on public.postcard_campaigns from authenticated;

-- In the browser, only a draft is written, and only what a draft says: what's on the card and who
-- it goes to. Sending, and what it records, goes through the server. A campaign being mailed can't
-- be deleted.
create function private.postcard_campaign_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if (select auth.role()) is distinct from 'authenticated' then
    return coalesce(new, old);
  end if;
  if tg_op = 'DELETE' then
    if old.status = 'sending' then
      raise exception 'A postcard campaign can''t be deleted while it''s being mailed' using errcode = '22023';
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
  -- A photo of another company's isn't this card's front.
  if new.front_attachment_id is not null
     and not exists (select 1 from public.attachments a where a.id = new.front_attachment_id and a.company_id = new.company_id) then
    raise exception 'That photo isn''t one of yours' using errcode = '22023';
  end if;
  return new;
end $$;
revoke all on function private.postcard_campaign_guard() from public;
create trigger postcard_campaign_guard before insert or update or delete on public.postcard_campaigns
  for each row execute function private.postcard_campaign_guard();

-- ---------------------------------------------------------------------------------------------
-- Recipients
-- ---------------------------------------------------------------------------------------------

create table public.postcard_recipients (
  id bigint generated always as identity primary key,
  company_id uuid not null,
  campaign_id uuid not null,
  client_id uuid,
  name text not null,
  -- {line1, line2, city, region, postal_code, country}, as it was when the campaign was sent.
  address jsonb not null check (jsonb_typeof(address) = 'object'),
  status text not null default 'pending' check (status in ('pending', 'sending', 'made', 'failed', 'skipped')),
  error text check (length(error) <= 1000),
  idempotency_key uuid not null default gen_random_uuid(),
  lob_id text,
  expected_delivery date,
  made_at timestamptz,
  attempts integer not null default 0,
  claim_token uuid,
  claimed_at timestamptz,
  locked_until timestamptz,
  created_at timestamptz not null default now(),
  unique (campaign_id, client_id),
  unique (idempotency_key),
  foreign key (company_id, campaign_id) references public.postcard_campaigns (company_id, id) on delete cascade,
  foreign key (company_id, client_id) references public.clients (company_id, id) on delete set null (client_id)
);
create index postcard_recipients_waiting_idx on public.postcard_recipients (campaign_id, id) where status in ('pending', 'sending');
create index postcard_recipients_client_idx on public.postcard_recipients (client_id) where status = 'made';
comment on table public.postcard_recipients is 'Each client a postcard campaign goes to, and what happened to their card';

alter table public.postcard_recipients enable row level security;
create policy postcard_recipients_read on public.postcard_recipients for select to authenticated
  using (private.has_role(company_id, '{owner,admin,office}'));
select private.restrict_area('postcard_recipients', 'marketing', true);
revoke all on public.postcard_recipients from anon;
revoke insert, update, delete, truncate on public.postcard_recipients from authenticated;

-- ---------------------------------------------------------------------------------------------
-- Who gets one
-- ---------------------------------------------------------------------------------------------

-- Whether a client is in a campaign's segment: the filters of public.campaign_audience
-- (20261031000210_campaign_audiences.sql), without its email and opt-out checks, which postcards
-- make their own way. As the person asking, like it.
create function private.in_segment(p_company uuid, c public.clients, p_audience jsonb) returns boolean
language sql stable security invoker set search_path = '' as $$
  select (coalesce(jsonb_array_length(p_audience -> 'statuses'), 0) = 0
          or c.status in (select jsonb_array_elements_text(p_audience -> 'statuses')))
    and (coalesce(jsonb_array_length(p_audience -> 'tags_any'), 0) = 0
         or c.tags && array(select jsonb_array_elements_text(p_audience -> 'tags_any')))
    and not (c.tags && array(select jsonb_array_elements_text(coalesce(p_audience -> 'tags_none', '[]'))))
    and (coalesce((p_audience ->> 'no_visit_days')::integer, 0) <= 0 or not exists (
         select 1 from public.visits v join public.jobs j on j.id = v.job_id
         where j.client_id = c.id and v.status = 'completed'
           and v.completed_at > now() - make_interval(days => (p_audience ->> 'no_visit_days')::integer)))
    and (coalesce(jsonb_array_length(p_audience -> 'cities'), 0) = 0
         or exists (select 1 from public.properties p
                     where p.client_id = c.id
                       and lower(trim(p.city)) in (select lower(trim(x)) from jsonb_array_elements_text(p_audience -> 'cities') x))
         or lower(trim(c.billing_address ->> 'city')) in (select lower(trim(x)) from jsonb_array_elements_text(p_audience -> 'cities') x))
    and (coalesce(jsonb_array_length(p_audience -> 'services'), 0) = 0 or exists (
         select 1 from public.job_line_items l
           join public.jobs j on j.id = l.job_id
           left join public.services s on s.id = l.service_id
          where j.client_id = c.id
            and (j.status in ('requires_invoicing', 'completed')
                 or exists (select 1 from public.visits v where v.job_id = j.id and v.status = 'completed'))
            and lower(trim(coalesce(s.name, l.name))) in (select lower(trim(x)) from jsonb_array_elements_text(p_audience -> 'services') x)))
    and (coalesce(p_audience ->> 'recurring', '') not in ('yes', 'no')
         or (p_audience ->> 'recurring' = 'yes') = exists (
              select 1 from public.jobs j where j.client_id = c.id and j.kind = 'recurring' and j.status = 'active'))
    and (p_audience -> 'recurring_ending' is distinct from 'true'::jsonb or exists (
         select 1 from public.jobs j
          where j.client_id = c.id and j.kind = 'recurring' and j.status = 'active'
            and j.ends_on between private.company_today(p_company) and private.company_today(p_company) + 30))
$$;

-- An address that can be mailed: a street, a city, a state and a US ZIP code, in the US (a blank
-- country is the US). The address as Lob gets it, or {"problem": "no_address" | "outside_us"}.
create function private.mailable_address(p_line1 text, p_line2 text, p_city text, p_region text, p_zip text, p_country text) returns jsonb
language sql immutable set search_path = '' as $$
  select case
    when coalesce(trim(p_line1), '') = '' or coalesce(trim(p_city), '') = '' or coalesce(trim(p_region), '') = '' or coalesce(trim(p_zip), '') = ''
      then jsonb_build_object('problem', 'no_address')
    when lower(trim(coalesce(p_country, ''))) not in ('', 'us', 'usa', 'u.s.', 'u.s.a.', 'united states', 'united states of america')
         or trim(p_zip) !~ '^\d{5}(-?\d{4})?$'
      then jsonb_build_object('problem', 'outside_us')
    else jsonb_strip_nulls(jsonb_build_object(
      'line1', regexp_replace(trim(p_line1), '\s+', ' ', 'g'), 'line2', nullif(regexp_replace(trim(coalesce(p_line2, '')), '\s+', ' ', 'g'), ''),
      'city', regexp_replace(trim(p_city), '\s+', ' ', 'g'), 'region', regexp_replace(trim(p_region), '\s+', ' ', 'g'),
      'postal_code', trim(p_zip), 'country', 'US'))
  end
$$;

-- Where a client's card goes: their billing address when it's complete, else their first property's
-- that is (oldest first). When none is, why: an address outside the US, or no complete one.
create function private.mailing_address(c public.clients) returns jsonb
language sql stable security invoker set search_path = '' as $$
  with tries as (
    select 0 as n, private.mailable_address(c.billing_address ->> 'line1', c.billing_address ->> 'line2', c.billing_address ->> 'city',
             coalesce(nullif(c.billing_address ->> 'region', ''), c.billing_address ->> 'state'), c.billing_address ->> 'postal_code', c.billing_address ->> 'country') as a
    union all
    select row_number() over (order by p.created_at, p.id), private.mailable_address(p.line1, p.line2, p.city, p.region, p.postal_code, p.country)
      from public.properties p where p.client_id = c.id and p.company_id = c.company_id
  )
  select coalesce(
    (select a from tries where not a ? 'problem' order by n limit 1),
    (select a from tries where a ->> 'problem' = 'outside_us' limit 1),
    jsonb_build_object('problem', 'no_address'))
$$;

-- Everyone in the segment, each with the address their card goes to, or why they're left out
-- (archived, opted_out, no_address, outside_us; in that order). As the person asking.
create function public.postcard_audience(p_company uuid, p_audience jsonb)
returns table (client_id uuid, display_name text, address jsonb, left_out text)
language sql stable security invoker set search_path = '' as $$
  select c.id, c.display_name,
         case when m.a ? 'problem' then null else m.a end,
         case
           when c.status = 'archived' then 'archived'
           when c.marketing_opt_out then 'opted_out'
           else m.a ->> 'problem'
         end
    from public.clients c
    cross join lateral (select private.mailing_address(c) as a) m
   where c.company_id = p_company
     and private.in_segment(p_company, c, coalesce(p_audience, '{}'::jsonb))
   order by c.display_name, c.id
$$;
revoke execute on function public.postcard_audience(uuid, jsonb) from public, anon;
grant execute on function public.postcard_audience(uuid, jsonb) to authenticated, service_role;

-- For the campaign's Audience card: how many get a card, how many are left out and why, and the
-- first few names with their town, whatever the size of the list.
create function public.postcard_audience_summary(p_company uuid, p_audience jsonb) returns jsonb
language sql stable security invoker set search_path = '' as $$
  with a as (select * from public.postcard_audience(p_company, p_audience))
  select jsonb_build_object(
    'count', (select count(*) from a where left_out is null),
    'left_out', jsonb_build_object(
      'archived', (select count(*) from a where left_out = 'archived'),
      'opted_out', (select count(*) from a where left_out = 'opted_out'),
      'no_address', (select count(*) from a where left_out = 'no_address'),
      'outside_us', (select count(*) from a where left_out = 'outside_us')),
    'sample', coalesce((select jsonb_agg(jsonb_build_object('client_id', s.client_id, 'name', s.display_name, 'city', s.address ->> 'city', 'region', s.address ->> 'region'))
                          from (select * from a where left_out is null limit 5) s), '[]'::jsonb))
$$;
revoke execute on function public.postcard_audience_summary(uuid, jsonb) from public, anon;
grant execute on function public.postcard_audience_summary(uuid, jsonb) to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- Sending (the server's)
-- ---------------------------------------------------------------------------------------------

-- Send: the draft's audience, as it is now, becomes its recipients, each with the address their card
-- goes to; the campaign is being mailed from now, with the key's mode and the front's public copy.
-- Only a draft starts, once (a second Send finds it started). Says how many it's going to.
create function public.start_postcard_campaign(p_campaign uuid, p_mode text, p_image_token text, p_image_path text, p_max integer default 5000)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  v public.postcard_campaigns;
  v_count integer;
begin
  if p_mode is null or p_mode not in ('test', 'live') then
    raise exception 'A postcard campaign is mailed with a test or a live key' using errcode = '22023';
  end if;
  select * into v from public.postcard_campaigns where id = p_campaign for update;
  if not found or v.status <> 'draft' then
    raise exception 'This campaign has already been sent' using errcode = '55000';
  end if;
  select count(*) into v_count from public.postcard_audience(v.company_id, v.audience) a where a.left_out is null;
  if v_count = 0 then
    raise exception 'No one in this audience has a complete mailing address' using errcode = '22023';
  end if;
  if v_count > greatest(coalesce(p_max, 5000), 1) then
    raise exception 'Postcard campaigns are limited to % cards. Narrow the audience.', to_char(greatest(coalesce(p_max, 5000), 1), 'FM999,999') using errcode = '22023';
  end if;
  insert into public.postcard_recipients (company_id, campaign_id, client_id, name, address)
  select v.company_id, v.id, a.client_id, a.display_name, a.address
    from public.postcard_audience(v.company_id, v.audience) a
   where a.left_out is null
  on conflict (campaign_id, client_id) do nothing;
  update public.postcard_campaigns
     set status = 'sending', mode = p_mode, image_token = p_image_token, image_path = p_image_path,
         started_at = now(), recipients_count = v_count
   where id = v.id;
  return v_count;
end $$;

-- A batch of the campaign's recipients to make cards for, claimed with one token for five minutes
-- (renewed before each card). A claim left more than 12 hours, longer than Lob keeps an idempotency
-- key, isn't tried again: the card may have been made, so it fails, saying to look in Lob first.
create function public.claim_postcard_recipients(p_campaign uuid, p_limit integer default 25)
returns setof public.postcard_recipients language plpgsql security definer set search_path = '' as $$
declare v_token uuid := gen_random_uuid();
begin
  update public.postcard_recipients
     set status = 'failed', claim_token = null, locked_until = null,
         error = 'It isn''t known whether this card was made. Look for it in your Lob dashboard before mailing this client again.'
   where campaign_id = p_campaign and claimed_at < now() - interval '12 hours'
     and ((status = 'sending' and locked_until < now()) or (status = 'pending' and attempts > 0));

  -- claimed_at is when it was first claimed, however many times it's tried.
  return query
  update public.postcard_recipients r
     set status = 'sending', claimed_at = coalesce(r.claimed_at, now()),
         locked_until = now() + interval '5 minutes', claim_token = v_token
   where r.id in (
     select x.id from public.postcard_recipients x
      where x.campaign_id = p_campaign
        and (x.status = 'pending' or (x.status = 'sending' and x.locked_until < now()))
      order by x.id
      limit least(greatest(p_limit, 1), 100)
      for update skip locked)
  returning r.*;
end $$;

-- Right before a card is made: true if the worker still holds the recipient (five more minutes),
-- which counts the try.
create function public.renew_postcard_recipient(p_id bigint, p_token uuid)
returns boolean language plpgsql security definer set search_path = '' as $$
begin
  update public.postcard_recipients
     set locked_until = now() + interval '5 minutes', attempts = attempts + 1
   where id = p_id and status = 'sending' and claim_token = p_token;
  return found;
end $$;

-- What happened to a recipient the worker holds: made (with Lob's id and the day it's expected),
-- failed or skipped (p_error says why). False when another worker holds them now.
create function public.finish_postcard_recipient(p_id bigint, p_token uuid, p_status text, p_error text default null,
  p_lob_id text default null, p_expected date default null)
returns boolean language plpgsql security definer set search_path = '' as $$
begin
  if p_status is null or p_status not in ('made', 'failed', 'skipped') then
    raise exception 'A postcard is made, failed or skipped' using errcode = '22023';
  end if;
  update public.postcard_recipients
     set status = p_status, error = left(p_error, 1000), lob_id = case when p_status = 'made' then p_lob_id end,
         expected_delivery = case when p_status = 'made' then p_expected end, made_at = case when p_status = 'made' then now() end,
         claim_token = null, locked_until = null
   where id = p_id and status = 'sending' and claim_token = p_token;
  return found;
end $$;

-- Recipients the worker claimed but didn't get to (rate limited, stopped early, Lob down for now)
-- wait for the next run. Those it no longer holds are left alone.
create function public.release_postcard_recipients(p_token uuid, p_ids bigint[])
returns integer language plpgsql security definer set search_path = '' as $$
declare v_count integer;
begin
  update public.postcard_recipients
     set status = 'pending', locked_until = null, claim_token = null
   where id = any (p_ids) and status = 'sending' and claim_token = p_token;
  get diagnostics v_count = row_count;
  return v_count;
end $$;

-- Stop: the campaign is cancelled with why, and what's waiting is skipped. A card being made right
-- now is recorded as it comes back (its worker still holds it); a worker checks the campaign before
-- each card, so it makes no more.
create function public.stop_postcard_campaign(p_campaign uuid, p_reason text default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  update public.postcard_campaigns
     set status = 'cancelled', finished_at = now(), stopped_reason = left(p_reason, 500)
   where id = p_campaign and status = 'sending';
  update public.postcard_recipients
     set status = 'skipped', error = coalesce(left(p_reason, 1000), 'Campaign stopped')
   where campaign_id = p_campaign and status = 'pending';
  perform public.count_postcard_campaign(p_campaign);
end $$;

-- The campaign's counts from its recipients; one still being mailed with none left is finished.
create function public.count_postcard_campaign(p_campaign uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_made integer;
  v_failed integer;
  v_left integer;
begin
  select count(*) filter (where status = 'made'), count(*) filter (where status = 'failed'), count(*) filter (where status in ('pending', 'sending'))
    into v_made, v_failed, v_left
    from public.postcard_recipients where campaign_id = p_campaign;
  update public.postcard_campaigns
     set made_count = v_made, failed_count = v_failed,
         status = case when status = 'sending' and v_left = 0 then 'sent' else status end,
         finished_at = case when status = 'sending' and v_left = 0 then now() else finished_at end
   where id = p_campaign;
  return jsonb_build_object('made', v_made, 'failed', v_failed, 'left', v_left);
end $$;

revoke execute on function public.start_postcard_campaign(uuid, text, text, text, integer), public.claim_postcard_recipients(uuid, integer),
  public.renew_postcard_recipient(bigint, uuid), public.finish_postcard_recipient(bigint, uuid, text, text, text, date),
  public.release_postcard_recipients(uuid, bigint[]), public.stop_postcard_campaign(uuid, text), public.count_postcard_campaign(uuid)
  from public, anon, authenticated;
grant execute on function public.start_postcard_campaign(uuid, text, text, text, integer), public.claim_postcard_recipients(uuid, integer),
  public.renew_postcard_recipient(bigint, uuid), public.finish_postcard_recipient(bigint, uuid, text, text, text, date),
  public.release_postcard_recipients(uuid, bigint[]), public.stop_postcard_campaign(uuid, text), public.count_postcard_campaign(uuid)
  to service_role;
revoke all on function private.in_segment(uuid, public.clients, jsonb), private.mailable_address(text, text, text, text, text, text),
  private.mailing_address(public.clients) from public;
-- postcard_audience runs as the person asking, and reads these.
grant execute on function private.in_segment(uuid, public.clients, jsonb), private.mailable_address(text, text, text, text, text, text),
  private.mailing_address(public.clients) to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- Results
-- ---------------------------------------------------------------------------------------------

-- Each sent postcard campaign's numbers (or p_campaign's), for the office with Marketing: cards made,
-- failed and skipped, and what paid work from clients a live key mailed came to (paid invoices made
-- after their card and within 90 days, before tax and retainage; null without the Invoices area).
create function public.postcard_results(p_company uuid, p_campaign uuid default null) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_money boolean;
begin
  if not (private.has_role(p_company, '{owner,admin,office}') and private.has_perm(p_company, 'marketing')) then
    raise exception 'Campaign results are part of Marketing' using errcode = '42501';
  end if;
  v_money := private.has_perm(p_company, 'invoices');
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'campaign_id', c.id, 'mode', c.mode,
             'made', coalesce(r.made, 0), 'failed', coalesce(r.failed, 0), 'skipped', coalesce(r.skipped, 0),
             'clients_paid', case when v_money and c.mode = 'live' then coalesce(m.clients, 0) end,
             'revenue', case when v_money and c.mode = 'live' then coalesce(m.revenue, 0) end)
           order by c.created_at desc)
      from public.postcard_campaigns c
      left join lateral (
        select count(*) filter (where x.status = 'made') as made, count(*) filter (where x.status = 'failed') as failed,
               count(*) filter (where x.status = 'skipped') as skipped
          from public.postcard_recipients x where x.campaign_id = c.id) r on true
      left join lateral (
        select count(distinct i.client_id) as clients, sum(greatest(i.total - i.tax_amount - i.retainage_amount, 0)) as revenue
          from public.postcard_recipients x
          join public.invoices i on i.company_id = x.company_id and i.client_id = x.client_id
         where x.campaign_id = c.id and x.status = 'made' and i.status = 'paid'
           and i.created_at >= x.made_at and i.created_at < x.made_at + interval '90 days') m on true
     where c.company_id = p_company and c.status <> 'draft' and (p_campaign is null or c.id = p_campaign)), '[]'::jsonb);
end $$;
revoke execute on function public.postcard_results(uuid, uuid) from public, anon;
grant execute on function public.postcard_results(uuid, uuid) to authenticated;

select private.fold_member_checks('public.postcard_campaigns');
select private.fold_member_checks('public.postcard_recipients');

notify pgrst, 'reload schema';
