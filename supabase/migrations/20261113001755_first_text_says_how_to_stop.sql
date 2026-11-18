-- The first text Jobly sends a number says how to stop them ("Reply STOP to opt out."), as
-- Twilio's messaging policy asks of the initial message to a recipient. Until now only review asks
-- carried the line. This keeps which numbers have been told, for each company, so the line goes
-- once and a reminder or a quote's text isn't a segment longer every time.
--
--   sms_told   a number a company's text has told how to stop, and when. The server writes it
--              when such a text goes (services/stopLine.ts) and nobody else reads it.
--
-- Numbers already asked for a review by text have had the line, so they start as told. Everyone
-- else a business texts gets it once, on the next text Jobly writes for them.
--
-- supabase/tests/first_text_says_how_to_stop_test.sql covers it.

create table public.sms_told (
  company_id uuid not null references public.companies (id) on delete cascade,
  -- The number's last 10 digits, as sms_stops keeps numbers (core phoneMatchKey).
  phone_key text not null check (phone_key ~ '^[0-9]{7,10}$'),
  told_at timestamptz not null default now(),
  primary key (company_id, phone_key)
);
comment on table public.sms_told is 'Numbers a company''s text has told how to stop texts ("Reply STOP to opt out."), so the line goes on the first text only. The server writes and reads it.';

-- The server's alone: nothing in the app shows it.
alter table public.sms_told enable row level security;
revoke all on public.sms_told from anon, authenticated;

insert into public.sms_told (company_id, phone_key, told_at)
select distinct on (r.company_id, k.key) r.company_id, k.key, r.sent_at
  from public.review_requests r
  join public.clients c on c.id = r.client_id
  cross join lateral (select right(regexp_replace(c.phone, '\D', '', 'g'), 10) as key) k
 where r.channel in ('sms', 'both') and r.status <> 'failed' and c.phone is not null and k.key ~ '^[0-9]{7,10}$'
 order by r.company_id, k.key, r.sent_at
on conflict do nothing;

notify pgrst, 'reload schema';
