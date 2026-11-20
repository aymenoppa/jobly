-- Database tests for 20261113001400_postcards.sql: who a postcard campaign goes to (a complete US
-- mailing address, never archived or opted out, the rest counted with why); the office writes only
-- drafts, and only what's on the card; sending, claiming and recording are the server's, once per
-- client; a claim left too long isn't tried again; what was mailed brought in counts only for a live
-- key; and nobody outside the office (field crew, anyone without signing in) reads a campaign or the
-- addresses it went to.
-- Run with scripts/test-db.sh (plain Postgres + prelude.sql). Any failed check stops with an error.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema tmkpc;
grant usage on schema tmkpc to authenticated, service_role, anon;
create function tmkpc.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_what; end if;
  raise notice 'ok - %', p_what;
end $$;
create function tmkpc.error_of(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'none';
exception when others then
  return sqlstate || ': ' || sqlerrm;
end $$;
create function tmkpc.as_user(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true)
$$;
create function tmkpc.as_nobody() returns void language sql as $$
  select set_config('request.jwt.claims', '', true)
$$;
create function tmkpc.count_of(p_sql text) returns integer language plpgsql as $$
declare v integer;
begin
  execute 'select count(*) from (' || p_sql || ') x' into v;
  return v;
end $$;
grant execute on all functions in schema tmkpc to authenticated, service_role, anon;

\set pat 'ac100000-0000-0000-0000-000000000001'
\set olive 'ac100000-0000-0000-0000-000000000002'
\set ray 'ac100000-0000-0000-0000-000000000003'

begin;
-- Pat owns Sketchy Gutters, Olive is in the office, Ray is field crew.
insert into auth.users (id, email, raw_user_meta_data) values
  (:'pat', 'pat@sketchy.test', '{"full_name": "Pat Owner"}'),
  (:'olive', 'olive@sketchy.test', '{"full_name": "Olive Office"}'),
  (:'ray', 'ray@sketchy.test', '{"full_name": "Ray Crew"}');
set local role authenticated;
select tmkpc.as_user(:'pat');
select public.create_company('Sketchy Gutters', 'general') as co \gset
reset role;
insert into public.memberships (company_id, user_id, role) values (:'co', :'olive', 'office'), (:'co', :'ray', 'field_crew');

-- Ann has a full billing address; Bob only a property (his billing address has no ZIP); Cy is
-- archived; Dee opted out of marketing; Eve has no address; Fay lives in Canada; Gus is a lead.
insert into public.clients (company_id, display_name, status, billing_address, marketing_opt_out, tags) values
  (:'co', 'Ann Oak', 'active', '{"line1": "12 Oak St", "city": "Springfield", "region": "IL", "postal_code": "62701"}', false, '{gutters}'),
  (:'co', 'Bob Ash', 'active', '{"line1": "4 Ash Ln", "city": "Springfield", "region": "IL"}', false, '{gutters}'),
  (:'co', 'Cy Elm', 'archived', '{"line1": "8 Elm Ct", "city": "Springfield", "region": "IL", "postal_code": "62702"}', false, '{gutters}'),
  (:'co', 'Dee Fir', 'active', '{"line1": "3 Fir Rd", "city": "Springfield", "region": "IL", "postal_code": "62703"}', true, '{gutters}'),
  (:'co', 'Eve Yew', 'active', '{}', false, '{gutters}'),
  (:'co', 'Fay Pine', 'active', '{"line1": "1 King St", "city": "Toronto", "region": "ON", "postal_code": "M5H 1A1", "country": "CA"}', false, '{gutters}'),
  (:'co', 'Gus Bay', 'lead', '{"line1": "7 Bay St", "city": "Peoria", "region": "IL", "postal_code": "61602"}', false, '{}');
select id as ann from public.clients where display_name = 'Ann Oak' \gset
select id as bob from public.clients where display_name = 'Bob Ash' \gset
insert into public.properties (company_id, client_id, line1, city, region, postal_code) values
  (:'co', :'bob', '', 'Nowhere', 'IL', '62704'),
  (:'co', :'bob', '9 Ash Ln', 'Springfield', 'IL', '62704');

\o
\echo 'Who gets a card'
\o /dev/null
set local role authenticated;
select tmkpc.as_user(:'olive');
select tmkpc.check((select count(*) = 6 from public.postcard_audience(:'co', '{"tags_any": ["gutters"]}')), 'the segment is every client tagged gutters');
select tmkpc.check((select array_agg(display_name order by display_name) = '{Ann Oak,Bob Ash}' from public.postcard_audience(:'co', '{"tags_any": ["gutters"]}') where left_out is null),
  'only Ann and Bob, who have a complete US address, get one');
select tmkpc.check((select address ->> 'line1' = '9 Ash Ln' and address ->> 'postal_code' = '62704' from public.postcard_audience(:'co', '{"tags_any": ["gutters"]}') where client_id = :'bob'),
  'Bob''s goes to his property, his billing address being incomplete, skipping one with no street');
select tmkpc.check((select jsonb_object_agg(display_name, left_out) = '{"Cy Elm": "archived", "Dee Fir": "opted_out", "Eve Yew": "no_address", "Fay Pine": "outside_us"}'::jsonb
  from public.postcard_audience(:'co', '{"tags_any": ["gutters"]}') where left_out is not null), 'the rest are left out, each with why');
select tmkpc.check((select s -> 'count' = '2' and s -> 'left_out' @> '{"archived": 1, "opted_out": 1, "no_address": 1, "outside_us": 1}'::jsonb and jsonb_array_length(s -> 'sample') = 2
  from public.postcard_audience_summary(:'co', '{"tags_any": ["gutters"]}') s), 'the summary counts them, with a few names');
select tmkpc.check((select (s ->> 'count')::integer = 3 from public.postcard_audience_summary(:'co', '{"statuses": ["active", "lead", "archived"]}') s),
  'the same segments as email: statuses with leads, archived still left out');

\o
\echo 'The office writes drafts, and only what''s on the card'
\o /dev/null
insert into public.postcard_campaigns (company_id, name, message, audience, status, mode, made_count)
values (:'co', 'Spring', 'Hi {{client.first_name}}, book with us.', '{"tags_any": ["gutters"]}', 'sending', 'live', 99) returning id as pc \gset
select tmkpc.check((select status = 'draft' and mode is null and made_count = 0 from public.postcard_campaigns where id = :'pc'), 'a campaign starts as a draft, whatever the browser says');
update public.postcard_campaigns set status = 'sending', mode = 'live', image_token = repeat('a', 32), size = '6x9' where id = :'pc';
select tmkpc.check((select status = 'draft' and mode is null and image_token is null and size = '6x9' from public.postcard_campaigns where id = :'pc'), 'a change to a draft keeps it a draft, and changes the card');
select tmkpc.check(tmkpc.error_of(format('update public.postcard_campaigns set front_path = %L where id = %L', 'elsewhere/x.jpg', :'pc')) like '23514:%', 'its own picture is only in its company''s postcards folder');
select tmkpc.check(tmkpc.error_of(format('update public.postcard_campaigns set front_path = %L where id = %L', :'co' || '/postcards/../logo/x.jpg', :'pc')) like '23514:%', 'and never a way out of it');
select tmkpc.check(tmkpc.error_of(format('select public.start_postcard_campaign(%L, %L, %L, %L)', :'pc', 'live', repeat('a', 32), 'x')) like '42501:%', 'the office can''t send it straight from the browser');
select tmkpc.check(tmkpc.error_of('insert into public.postcard_recipients (company_id, campaign_id, client_id, name, address) values (''' || :'co' || ''', ''' || :'pc' || ''', ''' || :'ann' || ''', ''x'', ''{}'')') like '42501:%',
  'nor add a recipient');

select tmkpc.as_user(:'ray');
select tmkpc.check(tmkpc.count_of('select 1 from public.postcard_campaigns') = 0, 'field crew don''t see postcard campaigns');
select tmkpc.check(tmkpc.count_of('select 1 from public.postcard_audience(''' || :'co' || ''', ''{}'')') = 0, 'nor anyone''s address through the audience');
reset role;

\o
\echo 'Sending, once per client'
\o /dev/null
set local role service_role;
select tmkpc.as_nobody();
select tmkpc.check(public.start_postcard_campaign(:'pc', 'test', repeat('a', 32), :'co' || '/postcards/' || :'pc' || '/front.jpg') = 2, 'Send makes a recipient for each client who gets a card');
select tmkpc.check((select status = 'sending' and mode = 'test' and recipients_count = 2 from public.postcard_campaigns where id = :'pc'), 'and the campaign is being mailed, with the key''s mode');
select tmkpc.check((select count(*) = 2 and count(distinct idempotency_key) = 2 from public.postcard_recipients where campaign_id = :'pc'), 'each with its own idempotency key');
select tmkpc.check(tmkpc.error_of(format('select public.start_postcard_campaign(%L, %L, %L, %L)', :'pc', 'test', repeat('b', 32), 'x')) like '55000:%', 'a second Send finds it sent');
select tmkpc.check(tmkpc.error_of(format('insert into public.postcard_recipients (company_id, campaign_id, client_id, name, address) values (%L, %L, %L, %L, %L)', :'co', :'pc', :'ann', 'Ann again', '{}')) like '23505:%',
  'a client is on a campaign once');

select count(*) as claimed, min(claim_token::text) as tok from public.claim_postcard_recipients(:'pc', 25) \gset
select tmkpc.check(:claimed = 2, 'a run claims both');
select tmkpc.check(tmkpc.count_of(format('select 1 from public.claim_postcard_recipients(%L, 25)', :'pc')) = 0, 'and another run gets neither while it holds them');
select id as r_ann from public.postcard_recipients where client_id = :'ann' and campaign_id = :'pc' \gset
select id as r_bob from public.postcard_recipients where client_id = :'bob' and campaign_id = :'pc' \gset
select tmkpc.check(public.renew_postcard_recipient(:r_ann, :'tok'), 'the run still holds Ann before her card');
select tmkpc.check(not public.renew_postcard_recipient(:r_ann, gen_random_uuid()), 'another token doesn''t');
select tmkpc.check(public.finish_postcard_recipient(:r_ann, :'tok', 'made', null, 'psc_1', '2026-11-20'), 'her card is recorded made');
select tmkpc.check((select status = 'made' and lob_id = 'psc_1' and expected_delivery = '2026-11-20' and made_at is not null and attempts = 1 from public.postcard_recipients where id = :r_ann),
  'with Lob''s id, when it''s expected and one try');
select tmkpc.check(public.release_postcard_recipients(:'tok', array[:r_bob]::bigint[]) = 1, 'Bob, not started, goes back');
select tmkpc.check(not public.finish_postcard_recipient(:r_bob, :'tok', 'made'), 'and the old token can''t record him');

-- A claim from 13 hours ago that ran out: Lob has forgotten its key, so it isn't tried again.
update public.postcard_recipients set status = 'sending', claimed_at = now() - interval '13 hours', locked_until = now() - interval '1 minute', attempts = 1 where id = :r_bob;
select tmkpc.check(tmkpc.count_of(format('select 1 from public.claim_postcard_recipients(%L, 25)', :'pc')) = 0, 'a claim left 12 hours isn''t claimed again');
select tmkpc.check((select status = 'failed' and error like '%Lob dashboard%' from public.postcard_recipients where id = :r_bob), 'it fails, saying to look in Lob first');
select tmkpc.check((select p -> 'made' = '1' and p -> 'failed' = '1' and p -> 'left' = '0' from public.count_postcard_campaign(:'pc') p), 'the counts');
select tmkpc.check((select status = 'sent' and made_count = 1 and failed_count = 1 and finished_at is not null from public.postcard_campaigns where id = :'pc'), 'and with none left it''s sent');
reset role;

\o
\echo 'Stopping'
\o /dev/null
insert into public.postcard_campaigns (company_id, name, message, audience) values (:'co', 'Fall', 'Hi there, book with us.', '{"tags_any": ["gutters"]}') returning id as pc2 \gset
set local role service_role;
select public.start_postcard_campaign(:'pc2', 'live', repeat('c', 32), 'x');
select public.stop_postcard_campaign(:'pc2', 'Stopped');
select tmkpc.check((select status = 'cancelled' and stopped_reason = 'Stopped' from public.postcard_campaigns where id = :'pc2'), 'Stop cancels it');
select tmkpc.check(tmkpc.count_of(format('select 1 from public.postcard_recipients where campaign_id = %L and status <> %L', :'pc2', 'skipped')) = 0, 'and skips what was waiting');
reset role;
set local role authenticated;
select tmkpc.as_user(:'olive');
select tmkpc.check(tmkpc.error_of(format('update public.postcard_campaigns set name = %L where id = %L', 'Renamed', :'pc2')) like '22023:%', 'a sent campaign can''t be changed');

\o
\echo 'What it brought in'
\o /dev/null
reset role;
select tmkpc.as_nobody();
-- Ann pays an invoice made after her card; one made before it doesn't count.
update public.postcard_recipients set made_at = now() - interval '10 days' where id = :r_ann;
insert into public.invoices (company_id, client_id, tax_rate, issued_on, created_at) values (:'co', :'ann', 0, current_date, now() - interval '20 days') returning id as before_inv \gset
insert into public.invoices (company_id, client_id, tax_rate, issued_on) values (:'co', :'ann', 0, current_date) returning id as after_inv \gset
insert into public.invoice_line_items (company_id, invoice_id, name, quantity, unit, unit_price) values (:'co', :'before_inv', 'Old', 1, 'ea', 50), (:'co', :'after_inv', 'Cleaning', 1, 'ea', 300);
update public.invoices set status = 'sent' where id in (:'before_inv', :'after_inv');
insert into public.payments (company_id, invoice_id, client_id, amount, method) select company_id, id, client_id, balance_due, 'check' from public.invoices where id in (:'before_inv', :'after_inv');
set local role authenticated;
select tmkpc.as_user(:'olive');
select tmkpc.check((select r -> 'revenue' = 'null'::jsonb and r -> 'made' = '1' from jsonb_array_elements(public.postcard_results(:'co', :'pc')) r), 'a test key''s cards bring in nothing: they weren''t mailed');
reset role;
select tmkpc.as_nobody();
update public.postcard_campaigns set mode = 'live' where id = :'pc';
set local role authenticated;
select tmkpc.as_user(:'olive');
select tmkpc.check((select (r ->> 'revenue')::numeric = 300 and r -> 'clients_paid' = '1' from jsonb_array_elements(public.postcard_results(:'co', :'pc')) r),
  'a live key''s count what clients mailed paid for work made after their card');
select tmkpc.as_user(:'ray');
select tmkpc.check(tmkpc.error_of(format('select public.postcard_results(%L)', :'co')) like '42501:%', 'field crew can''t read the results');

\o
\echo 'Nothing for anyone without signing in'
\o /dev/null
reset role;
set local role anon;
select tmkpc.as_nobody();
select tmkpc.check(tmkpc.error_of('select count(*) from public.postcard_campaigns') like '42501:%', 'campaigns aren''t readable');
select tmkpc.check(tmkpc.error_of('select count(*) from public.postcard_recipients') like '42501:%', 'nor the addresses they went to');
select tmkpc.check(tmkpc.error_of(format('select * from public.postcard_audience(%L, %L)', :'co', '{}')) like '42501:%', 'nor anyone''s address through the audience');
reset role;

rollback;

\o
\echo 'All postcard tests passed.'
