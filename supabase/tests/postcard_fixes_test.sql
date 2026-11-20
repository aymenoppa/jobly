-- Database tests for the postcard fixes after the 2026-11-14 review (20261113001550 to 001575):
-- only an address Lob will take counts as mailable (a full state name becomes its code, a ZIP+4 its
-- hyphen, and what still doesn't fit is left out with why).
-- Run with scripts/test-db.sh (plain Postgres + prelude.sql). Any failed check stops with an error.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema tmkpf;
grant usage on schema tmkpf to authenticated, service_role, anon;
create function tmkpf.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_what; end if;
  raise notice 'ok - %', p_what;
end $$;
create function tmkpf.error_of(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'none';
exception when others then
  return sqlstate || ': ' || sqlerrm;
end $$;
create function tmkpf.as_user(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true)
$$;
create function tmkpf.as_nobody() returns void language sql as $$
  select set_config('request.jwt.claims', '', true)
$$;
create function tmkpf.count_of(p_sql text) returns integer language plpgsql as $$
declare v integer;
begin
  execute 'select count(*) from (' || p_sql || ') x' into v;
  return v;
end $$;
grant execute on all functions in schema tmkpf to authenticated, service_role, anon;

\set pat 'ac200000-0000-0000-0000-000000000001'
\set olive 'ac200000-0000-0000-0000-000000000002'
\set ray 'ac200000-0000-0000-0000-000000000003'

begin;
-- Pat owns Sketchy Gutters, Olive is in the office, Ray is field crew.
insert into auth.users (id, email, raw_user_meta_data) values
  (:'pat', 'pat@fixes.test', '{"full_name": "Pat Owner"}'),
  (:'olive', 'olive@fixes.test', '{"full_name": "Olive Office"}'),
  (:'ray', 'ray@fixes.test', '{"full_name": "Ray Crew"}');
set local role authenticated;
select tmkpf.as_user(:'pat');
select public.create_company('Sketchy Gutters', 'general') as co \gset
reset role;
insert into public.memberships (company_id, user_id, role) values (:'co', :'olive', 'office'), (:'co', :'ray', 'field_crew');

\o
\echo 'Addresses Lob will take'
\o /dev/null
select tmkpf.check(private.us_state_code('IL') = 'IL' and private.us_state_code(' il ') = 'IL' and private.us_state_code('Illinois') = 'IL' and private.us_state_code('new  york') = 'NY'
  and private.us_state_code('D.C.') = 'DC' and private.us_state_code('Puerto Rico') = 'PR', 'a state is its two-letter code, typed as the code or in full');
select tmkpf.check(private.us_state_code('Ill') is null and private.us_state_code('Ontario') is null and private.us_state_code('ZZ') is null and private.us_state_code('') is null,
  'and what isn''t a US state is nothing');
select tmkpf.check(private.mailable_address('12  Oak St', null, 'Springfield', 'Illinois', '627011234', '')
  = '{"line1": "12 Oak St", "city": "Springfield", "region": "IL", "postal_code": "62701-1234", "country": "US"}'::jsonb, 'an address goes as Lob takes it: IL, and 62701-1234');
select tmkpf.check(private.mailable_address('12 Oak St', 'Apt 2', 'Springfield', 'il', '62701 1234', 'USA') ->> 'postal_code' = '62701-1234'
  and private.mailable_address('12 Oak St', null, 'Springfield', 'IL', '62701', null) ->> 'postal_code' = '62701', 'a ZIP is five digits or five, a hyphen and four');
select tmkpf.check(private.mailable_address('12 Oak St', null, 'Springfield', 'Ill.', '62701', '') = '{"problem": "bad_state"}'::jsonb, 'a state that isn''t one is left out as that');
select tmkpf.check(private.mailable_address(repeat('x', 65), null, 'Springfield', 'IL', '62701', '') = '{"problem": "too_long"}'::jsonb
  and private.mailable_address('12 Oak St', repeat('x', 65), 'Springfield', 'IL', '62701', '') = '{"problem": "too_long"}'::jsonb, 'and a line longer than Lob takes as that');
select tmkpf.check(private.mailable_address('1 King St', null, 'Toronto', 'ON', 'M5H 1A1', '') = '{"problem": "outside_us"}'::jsonb
  and private.mailable_address('1 King St', null, 'Toronto', 'ON', '62701', 'CA') = '{"problem": "outside_us"}'::jsonb
  and private.mailable_address('12 Oak St', null, 'Springfield', '', '62701', '') = '{"problem": "no_address"}'::jsonb, 'abroad and incomplete are said as before');

-- Ann's state is typed in full; Bea's is something Lob can't read, with no other address; Cal's
-- billing state is bad but his property is fine; Dot's street line is too long.
insert into public.clients (company_id, display_name, status, billing_address, tags) values
  (:'co', 'Ann Oak', 'active', '{"line1": "12 Oak St", "city": "Springfield", "region": "Illinois", "postal_code": "627011234"}', '{mail}'),
  (:'co', 'Bea Elm', 'active', '{"line1": "8 Elm Ct", "city": "Springfield", "region": "Ill.", "postal_code": "62702"}', '{mail}'),
  (:'co', 'Cal Fir', 'active', '{"line1": "3 Fir Rd", "city": "Springfield", "region": "Illinoy", "postal_code": "62703"}', '{mail}'),
  (:'co', 'Dot Yew', 'active', jsonb_build_object('line1', repeat('Very Long Street Name ', 4), 'city', 'Springfield', 'region', 'IL', 'postal_code', '62704'), '{mail}');
select id as ann from public.clients where display_name = 'Ann Oak' \gset
select id as cal from public.clients where display_name = 'Cal Fir' \gset
insert into public.properties (company_id, client_id, line1, city, region, postal_code) values (:'co', :'cal', '5 Fir Rd', 'Peoria', 'illinois', '61602');

set local role authenticated;
select tmkpf.as_user(:'olive');
select tmkpf.check((select address = '{"line1": "12 Oak St", "city": "Springfield", "region": "IL", "postal_code": "62701-1234", "country": "US"}'::jsonb
  from public.postcard_audience(:'co', '{"tags_any": ["mail"]}') where client_id = :'ann'), 'Ann, in "Illinois", gets a card addressed to IL');
select tmkpf.check((select address ->> 'line1' = '5 Fir Rd' and address ->> 'region' = 'IL' from public.postcard_audience(:'co', '{"tags_any": ["mail"]}') where client_id = :'cal'),
  'Cal''s goes to his property, his billing state being unreadable');
select tmkpf.check((select jsonb_object_agg(display_name, left_out) = '{"Bea Elm": "bad_state", "Dot Yew": "too_long"}'::jsonb
  from public.postcard_audience(:'co', '{"tags_any": ["mail"]}') where left_out is not null), 'Bea and Dot are left out, each with why');
select tmkpf.check((select s -> 'count' = '2' and s -> 'left_out' ->> 'bad_state' = '1' and s -> 'left_out' ->> 'too_long' = '1' and s -> 'left_out' ->> 'no_address' = '0'
  from public.postcard_audience_summary(:'co', '{"tags_any": ["mail"]}') s), 'and the count before Send is the two Lob will take');
reset role;

\o
\echo 'One card per address'
\o /dev/null
-- Hal and Ida are a couple entered twice, Ida first; Jo is at the same street number in another
-- unit; Kit shares their address but opted out; Lu's property is at Hal and Ida's address too.
insert into public.clients (company_id, display_name, status, billing_address, marketing_opt_out, tags, created_at) values
  (:'co', 'Ida Ash', 'active', '{"line1": "4 Ash Ln", "city": "Springfield", "region": "IL", "postal_code": "62704"}', false, '{home}', now() - interval '3 years'),
  (:'co', 'Hal Ash', 'active', '{"line1": "4 ASH LN ", "city": "Springfield", "region": "Illinois", "postal_code": "62704-1111"}', false, '{home}', now() - interval '1 year'),
  (:'co', 'Jo Bay', 'active', '{"line1": "4 Ash Ln", "line2": "Unit B", "city": "Springfield", "region": "IL", "postal_code": "62704"}', false, '{home}', now() - interval '2 years'),
  (:'co', 'Kit Ash', 'active', '{"line1": "4 Ash Ln", "city": "Springfield", "region": "IL", "postal_code": "62704"}', true, '{home}', now() - interval '5 years'),
  (:'co', 'Lu Ash', 'active', '{}', false, '{home}', now() - interval '6 months');
select id as lu from public.clients where display_name = 'Lu Ash' \gset
insert into public.properties (company_id, client_id, line1, city, region, postal_code) values (:'co', :'lu', '4 ash ln', 'Springfield', 'IL', '62704');
set local role authenticated;
select tmkpf.as_user(:'olive');
select tmkpf.check((select array_agg(display_name order by display_name) = '{Ida Ash,Jo Bay}' from public.postcard_audience(:'co', '{"tags_any": ["home"]}') where left_out is null),
  'one card goes to each address, to the client there longest; another unit is another address');
select tmkpf.check((select jsonb_object_agg(display_name, left_out) = '{"Hal Ash": "same_address", "Kit Ash": "opted_out", "Lu Ash": "same_address"}'::jsonb
  from public.postcard_audience(:'co', '{"tags_any": ["home"]}') where left_out is not null), 'the others at it are left out as sharing it; someone who opted out doesn''t take the card from them');
select tmkpf.check((select address ->> 'line1' = '4 ASH LN' from public.postcard_audience(:'co', '{"tags_any": ["home"]}') where display_name = 'Hal Ash'), 'and the list still says which address they share');
select tmkpf.check((select s -> 'count' = '2' and s -> 'left_out' ->> 'same_address' = '2' and s -> 'left_out' ->> 'opted_out' = '1' from public.postcard_audience_summary(:'co', '{"tags_any": ["home"]}') s),
  'the count before Send is one per address');
reset role;
insert into public.postcard_campaigns (company_id, name, message, audience) values (:'co', 'Homes', 'Hi {{client.first_name}}, book with us.', '{"tags_any": ["home"]}') returning id as pc_home \gset
set local role service_role;
select tmkpf.as_nobody();
select tmkpf.check(public.start_postcard_campaign(:'pc_home', 'test', repeat('h', 32), 'x') = 2, 'Send mails that many');
select tmkpf.check((select array_agg(name order by name) = '{Ida Ash,Jo Bay}' from public.postcard_recipients where campaign_id = :'pc_home'), 'to those clients');
reset role;

\o
\echo 'A merged client''s cards follow them'
\o /dev/null
-- Mo and Moe are one person entered twice, at two addresses; Ned is deleted outright. All three
-- were mailed "Merged"; only Mo and Moe were mailed "Both".
insert into public.clients (company_id, display_name, status, billing_address, tags) values
  (:'co', 'Mo Elm', 'active', '{"line1": "1 Elm St", "city": "Springfield", "region": "IL", "postal_code": "62705"}', '{both}'),
  (:'co', 'Moe Elm', 'active', '{"line1": "2 Elm St", "city": "Springfield", "region": "IL", "postal_code": "62705"}', '{both,merged}'),
  (:'co', 'Ned Fir', 'active', '{"line1": "3 Elm St", "city": "Springfield", "region": "IL", "postal_code": "62705"}', '{merged}');
select id as mo from public.clients where display_name = 'Mo Elm' \gset
select id as moe from public.clients where display_name = 'Moe Elm' \gset
select id as ned from public.clients where display_name = 'Ned Fir' \gset
insert into public.postcard_campaigns (company_id, name, message, audience) values (:'co', 'Merged', 'Hi {{client.first_name}}, book with us.', '{"tags_any": ["merged"]}') returning id as pc_m \gset
insert into public.postcard_campaigns (company_id, name, message, audience) values (:'co', 'Both', 'Hi {{client.first_name}}, book with us.', '{"tags_any": ["both"]}') returning id as pc_b \gset
set local role service_role;
select tmkpf.as_nobody();
select public.start_postcard_campaign(:'pc_m', 'live', repeat('m', 32), 'x'), public.start_postcard_campaign(:'pc_b', 'live', repeat('n', 32), 'x');
update public.postcard_recipients set status = 'made', lob_id = 'psc_' || id, made_at = now() - interval '2 days' where campaign_id = :'pc_m';
reset role;
-- Moe pays for work after the card.
insert into public.invoices (company_id, client_id, tax_rate, issued_on) values (:'co', :'moe', 0, current_date) returning id as inv \gset
insert into public.invoice_line_items (company_id, invoice_id, name, quantity, unit, unit_price) values (:'co', :'inv', 'Cleaning', 1, 'ea', 200);
update public.invoices set status = 'sent' where id = :'inv';
insert into public.payments (company_id, invoice_id, client_id, amount, method) select company_id, id, client_id, balance_due, 'check' from public.invoices where id = :'inv';
set local role authenticated;
select tmkpf.as_user(:'pat');
select public.merge_clients(:'co', :'mo', :'moe');
select tmkpf.check((select client_id = :'mo' and status = 'made' and name = 'Moe Elm' from public.postcard_recipients where campaign_id = :'pc_m' and lob_id is not null and name = 'Moe Elm'),
  'a merged client''s card is now the kept client''s, as it was mailed');
select tmkpf.check((select (r ->> 'revenue')::numeric = 200 and r -> 'clients_paid' = '1' from jsonb_array_elements(public.postcard_results(:'co', :'pc_m')) r),
  'and what they paid after it still counts for the campaign');
select tmkpf.check((select count(*) = 1 from public.postcard_recipients where campaign_id = :'pc_b' and client_id = :'mo')
  and (select count(*) = 1 and bool_and(client_id is null) from public.postcard_recipients where campaign_id = :'pc_b' and name = 'Moe Elm'),
  'on a campaign both were on, the kept client keeps their own card and the other stays without a client');
-- A client deleted, not merged, takes no one else's place.
reset role;
select tmkpf.as_nobody();
delete from public.clients where id = :'ned';
select tmkpf.check((select client_id is null from public.postcard_recipients where campaign_id = :'pc_m' and name = 'Ned Fir'), 'a deleted client''s card just loses its client');
update public.postcard_recipients set made_at = now() - interval '9 days' where campaign_id in (:'pc_m', :'pc_b');

\o
\echo 'A card left half-made in a stopped campaign'
\o /dev/null
insert into public.clients (company_id, display_name, status, billing_address, tags) values
  (:'co', 'Sam Oak', 'active', '{"line1": "1 Stuck St", "city": "Springfield", "region": "IL", "postal_code": "62706"}', '{stuck}'),
  (:'co', 'Sue Oak', 'active', '{"line1": "2 Stuck St", "city": "Springfield", "region": "IL", "postal_code": "62706"}', '{stuck}'),
  (:'co', 'Syd Oak', 'active', '{"line1": "3 Stuck St", "city": "Springfield", "region": "IL", "postal_code": "62706"}', '{stuck}');
insert into public.postcard_campaigns (company_id, name, message, audience) values (:'co', 'Stuck', 'Hi {{client.first_name}}, book with us.', '{"tags_any": ["stuck"]}') returning id as pc_s \gset
set local role service_role;
select tmkpf.as_nobody();
select public.start_postcard_campaign(:'pc_s', 'live', repeat('s', 32), 'x');
select min(claim_token::text) as stok from public.claim_postcard_recipients(:'pc_s', 2) \gset
select id as r_sam from public.postcard_recipients where campaign_id = :'pc_s' and name = 'Sam Oak' \gset
select id as r_sue from public.postcard_recipients where campaign_id = :'pc_s' and name = 'Sue Oak' \gset
select id as r_syd from public.postcard_recipients where campaign_id = :'pc_s' and name = 'Syd Oak' \gset
select public.renew_postcard_recipient(:r_sam, :'stok'), public.renew_postcard_recipient(:r_sue, :'stok');
-- Stopped while Sam's and Sue's cards were being made; the worker never came back.
select public.stop_postcard_campaign(:'pc_s', 'Stopped');
select tmkpf.check((select status = 'skipped' from public.postcard_recipients where id = :r_syd) and (select count(*) = 2 from public.postcard_recipients where campaign_id = :'pc_s' and status = 'sending'),
  'Stop skips who was waiting, and leaves the two being made to their worker');
select tmkpf.check(tmkpf.count_of('select 1 from public.stuck_postcard_recipients(100)') = 0, 'a card still within its worker''s time isn''t called stuck');
select tmkpf.check(not public.settle_postcard_recipient(:r_sam, 'skipped', 'Campaign stopped'), 'nor settled from under it');
update public.postcard_recipients set locked_until = now() - interval '11 minutes' where campaign_id = :'pc_s' and status = 'sending';
select tmkpf.check((select count(*) = 2 and min(mode) = 'live' from public.stuck_postcard_recipients(100) where campaign_id = :'pc_s'), 'ten minutes after its claim ran out it is, with the kind of key to ask Lob with');
select tmkpf.check(public.settle_postcard_recipient(:r_sam, 'made', null, 'psc_sam', 'https://lob-assets.com/postcards/psc_sam.pdf'), 'Lob has Sam''s card: it''s recorded made');
select tmkpf.check((select status = 'made' and lob_id = 'psc_sam' and made_at is not null and proof_url like 'https://%' and claim_token is null from public.postcard_recipients where id = :r_sam), 'with Lob''s id and its proof');
select tmkpf.check(public.settle_postcard_recipient(:r_sue, 'skipped', 'Campaign stopped'), 'Lob has no card for Sue: she wasn''t mailed');
select tmkpf.check((select made_count = 1 and status = 'cancelled' from public.postcard_campaigns where id = :'pc_s'), 'and the campaign counts the card that was made');
select tmkpf.check(tmkpf.count_of('select 1 from public.stuck_postcard_recipients(100)') = 0 and not public.settle_postcard_recipient(:r_sam, 'skipped'), 'nothing is left waiting, and a settled card isn''t settled again');
-- In a campaign still being mailed, a claim that ran out is the next run's to pick up, not this.
update public.postcard_campaigns set status = 'sending' where id = :'pc_s';
update public.postcard_recipients set status = 'sending', locked_until = now() - interval '1 hour' where id = :r_sue;
select tmkpf.check(tmkpf.count_of('select 1 from public.stuck_postcard_recipients(100)') = 0 and not public.settle_postcard_recipient(:r_sue, 'skipped'), 'a campaign being mailed isn''t touched');
update public.postcard_recipients set status = 'skipped', made_at = null where campaign_id = :'pc_s';
update public.postcard_campaigns set status = 'cancelled' where id = :'pc_s';
reset role;
set local role authenticated;
select tmkpf.as_user(:'olive');
select tmkpf.check(tmkpf.error_of('select * from public.stuck_postcard_recipients(10)') like '42501:%' and tmkpf.error_of(format('select public.settle_postcard_recipient(%s, %L)', :r_sue, 'made')) like '42501:%',
  'the office can''t settle a card from the browser');
reset role;

\o
\echo 'One mailed to ourselves first'
\o /dev/null
insert into public.postcard_campaigns (company_id, name, message, audience) values (:'co', 'Proofed', 'Hi {{client.first_name}}, book with us.', '{"tags_any": ["stuck"]}') returning id as pc_p \gset
set local role service_role;
select tmkpf.as_nobody();
insert into public.postcard_proofs (company_id, campaign_id, mode, size, address, image_token, image_path, status, lob_id, proof_url)
values (:'co', :'pc_p', 'live', '4x6', '{"line1": "1 Main St", "city": "Springfield", "region": "IL", "postal_code": "62701", "country": "US"}', repeat('p', 32), :'co' || '/postcards/' || :'pc_p' || '/proof.jpg', 'made', 'psc_proof', 'https://lob-assets.com/postcards/psc_proof.pdf')
returning id as proof \gset
reset role;
set local role authenticated;
select tmkpf.as_user(:'olive');
select tmkpf.check((select mode = 'live' and status = 'made' and proof_url like 'https://%' from public.postcard_proofs where id = :'proof'), 'the office reads a card mailed to the company, with Lob''s picture of it');
select tmkpf.check(tmkpf.error_of(format('insert into public.postcard_proofs (company_id, mode, size, address, image_token, image_path) values (%L, %L, %L, %L, %L, %L)', :'co', 'live', '4x6', '{}', repeat('q', 32), 'x')) like '42501:%'
  and tmkpf.error_of(format('update public.postcard_proofs set image_path = %L where id = %L', 'elsewhere/secret.jpg', :'proof')) like '42501:%',
  'and can''t make one, or point its public picture at another file, from the browser');
-- The draft is deleted: the card mailed to us, and the picture Lob may still fetch, stay.
select tmkpf.check(tmkpf.error_of(format('delete from public.postcard_campaigns where id = %L', :'pc_p')) = 'none', 'a draft a card was mailed from can still be deleted');
select tmkpf.check((select campaign_id is null and image_token = repeat('p', 32) from public.postcard_proofs where id = :'proof'), 'and its card to us stays, picture and all');
select tmkpf.as_user(:'ray');
select tmkpf.check(tmkpf.count_of('select 1 from public.postcard_proofs') = 0, 'field crew don''t see them');
reset role;
set local role anon;
select tmkpf.as_nobody();
select tmkpf.check(tmkpf.error_of('select count(*) from public.postcard_proofs') like '42501:%', 'nor anyone without signing in');
reset role;

\o
\echo 'After Lob has accepted the cards'
\o /dev/null
insert into public.postcard_campaigns (company_id, name, message, audience) values (:'co', 'Spring', 'Hi {{client.first_name}}, book with us.', '{"tags_any": ["mail"]}') returning id as pc \gset
set local role service_role;
select tmkpf.as_nobody();
select public.start_postcard_campaign(:'pc', 'live', repeat('a', 32), :'co' || '/postcards/' || :'pc' || '/front.jpg');
select tmkpf.check(tmkpf.count_of('select 1 from public.claim_postcard_checks(5)') = 0, 'Lob isn''t asked about a campaign none of whose cards are made yet');
select min(claim_token::text) as tok from public.claim_postcard_recipients(:'pc', 25) \gset
select id as r_ann from public.postcard_recipients where client_id = :'ann' and campaign_id = :'pc' \gset
select id as r_cal from public.postcard_recipients where client_id = :'cal' and campaign_id = :'pc' \gset
select public.renew_postcard_recipient(:r_ann, :'tok'), public.renew_postcard_recipient(:r_cal, :'tok');
select public.finish_postcard_recipient(:r_ann, :'tok', 'made', null, 'psc_ann', '2026-11-20'), public.finish_postcard_recipient(:r_cal, :'tok', 'made', null, 'psc_cal', '2026-11-20');
update public.postcard_recipients set proof_url = 'https://lob-assets.com/postcards/psc_ann.pdf', proof_at = now() where id = :r_ann;
select public.count_postcard_campaign(:'pc');
select tmkpf.check((select count(*) = 1 and min(mode) = 'live' from public.claim_postcard_checks(5) where id = :'pc'), 'once cards are made, Lob is asked about the campaign');
select tmkpf.check(tmkpf.count_of('select 1 from public.claim_postcard_checks(5)') = 0, 'and not again within the hour, by this server or another');
update public.postcard_campaigns set lob_checked_at = now() - interval '61 minutes' where id = :'pc';
select tmkpf.check(tmkpf.count_of('select 1 from public.claim_postcard_checks(5)') = 1, 'an hour later it''s asked again');
select tmkpf.check(tmkpf.error_of(format('update public.postcard_recipients set proof_url = %L where id = %s', 'javascript:alert(1)', :r_ann)) like '23514:%', 'a proof link is an https link');
reset role;

set local role authenticated;
select tmkpf.as_user(:'olive');
select tmkpf.check((select proof_url = 'https://lob-assets.com/postcards/psc_ann.pdf' from public.postcard_recipients where id = :r_ann), 'the office reads Lob''s proof link for a card');
select tmkpf.check(tmkpf.error_of(format('select * from public.claim_postcard_checks(%s)', 5)) like '42501:%', 'the office can''t claim the check');
select tmkpf.check(tmkpf.error_of(format('delete from public.postcard_campaigns where id = %L', :'pc')) like '22023:%7 days ago%', 'a campaign whose cards were just made can''t be deleted: Lob may still need its picture');
select tmkpf.check(tmkpf.count_of(format('select 1 from public.postcard_campaigns where id = %L and image_token is not null', :'pc')) = 1, 'so its picture stays up');
reset role;
select tmkpf.as_nobody();
-- Eight days on.
update public.postcard_recipients set made_at = now() - interval '8 days' where campaign_id = :'pc';
set local role service_role;
update public.postcard_campaigns set lob_checked_at = null where id = :'pc';
select tmkpf.check(tmkpf.count_of('select 1 from public.claim_postcard_checks(5)') = 0, 'a week after its last card, Lob isn''t asked anymore');
reset role;
set local role authenticated;
select tmkpf.as_user(:'olive');
select tmkpf.check(tmkpf.error_of(format('delete from public.postcard_campaigns where id = %L', :'pc')) = 'none', 'and the campaign can be deleted');
-- A campaign none of whose cards reached Lob has no picture to keep.
insert into public.postcard_campaigns (company_id, name, message, audience) values (:'co', 'Never made', 'Hi there, book with us.', '{"tags_any": ["mail"]}') returning id as pc_none \gset
reset role;
set local role service_role;
select tmkpf.as_nobody();
select public.start_postcard_campaign(:'pc_none', 'live', repeat('b', 32), 'x');
select public.stop_postcard_campaign(:'pc_none', 'Stopped');
reset role;
set local role authenticated;
select tmkpf.as_user(:'olive');
select tmkpf.check(tmkpf.error_of(format('delete from public.postcard_campaigns where id = %L', :'pc_none')) = 'none', 'one stopped before any card was made can be deleted at once');
reset role;

rollback;

\o
\echo 'All postcard fix tests passed.'
