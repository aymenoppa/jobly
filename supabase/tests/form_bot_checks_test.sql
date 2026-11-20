-- Database tests for a website form's bot check (20261117000100_form_bot_checks.sql): every form
-- starts with none; the people who manage forms choose one, but what came of it (what passed, what
-- didn't, what was turned away) and whether it refuses are only the server's; refusing needs a
-- message that passed; a changed check, a new address or new Turnstile keys start over; and a form
-- can't ask for Turnstile before the business has keys.
-- Run with scripts/test-db.sh (plain Postgres + prelude.sql). Any failed check stops with an error.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema fbt;
grant usage on schema fbt to authenticated, service_role;
create function fbt.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_what; end if;
  raise notice 'ok - %', p_what;
end $$;
create function fbt.expect_error(p_sql text, p_what text) returns void language plpgsql as $$
begin
  begin execute p_sql; exception when others then raise notice 'ok - % (%)', p_what, sqlerrm; return; end;
  raise exception 'FAIL (expected an error): %', p_what;
end $$;
grant execute on all functions in schema fbt to authenticated, service_role;

-- Ivy owns Fern Lawn; Lou is office. Max owns another business.
insert into auth.users (id, email, raw_user_meta_data) values
  ('bc170000-0000-0000-0000-000000000001', 'ivy@fern.test', '{"full_name": "Ivy Fern"}'),
  ('bc170000-0000-0000-0000-000000000002', 'lou@fern.test', '{"full_name": "Lou Marsh"}'),
  ('bc170000-0000-0000-0000-000000000009', 'max@elm.test', '{"full_name": "Max Elm"}');

begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "bc170000-0000-0000-0000-000000000009", "role": "authenticated"}', true);
select public.create_company('Elm Paving', 'general') as other \gset
select public.website_forms_set_enabled(:'other', true);
commit;

begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "bc170000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select public.create_company('Fern Lawn', 'lawn_care', 'America/Chicago') as co \gset
insert into public.memberships (company_id, user_id, role) values (:'co', 'bc170000-0000-0000-0000-000000000002', 'office');
select public.website_forms_set_enabled(:'co', true);
select public.careers_set_enabled(:'co', true);
commit;

select id as form from public.website_forms where company_id = :'co' and kind = 'contact' \gset
select id as apply from public.website_forms where company_id = :'co' and kind = 'careers' \gset
select id as other_form from public.website_forms where company_id = :'other' \gset

-- ===== Every form starts with no check =======================================================
select fbt.check((select count(*) = 2 and bool_and(bot_check = 'off' and bot_check_armed_at is null and bot_check_passed_at is null and bot_check_missed = 0
    and bot_check_missed_at is null and bots_blocked = 0 and last_blocked_at is null)
  from public.website_forms where company_id = :'co'), 'a new contact form and a new careers form have no check, nothing noted, nothing refused and nothing counted');
select fbt.expect_error(format('update public.website_forms set bot_check = %L where id = %L', 'captcha', :'form'), 'a check is off, script or turnstile');

-- ===== The people who manage forms choose the check; the rest is the server's ================
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "bc170000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
update public.website_forms set bot_check = 'script' where id = :'form';
select fbt.check((select bot_check = 'script' and bot_check_armed_at is null and bot_check_passed_at is null from public.website_forms where id = :'form'),
  'the owner turns on Jobly''s check, and it only watches');
update public.website_forms set bot_check_passed_at = now(), bot_check_missed = 7, bot_check_missed_at = now(), bot_check_armed_at = now(), bots_blocked = 500, last_blocked_at = now() where id = :'form';
select fbt.check((select bot_check_armed_at is null and bot_check_passed_at is null and bot_check_missed = 0 and bot_check_missed_at is null and bots_blocked = 0 and last_blocked_at is null
  from public.website_forms where id = :'form'), 'someone in the browser can''t make it refuse, say a message passed, or change its counts');
insert into public.website_forms (company_id, name, bot_check, bot_check_passed_at, bot_check_missed, bot_check_armed_at, bots_blocked, last_blocked_at)
  values (:'co', 'Quote form', 'script', now(), 3, now(), 9, now()) returning id as quote_form \gset
select fbt.check((select bot_check = 'script' and bot_check_armed_at is null and bot_check_passed_at is null and bot_check_missed = 0 and bots_blocked = 0 and last_blocked_at is null
  from public.website_forms where id = :'quote_form'), 'nor make a form that refuses already');
select fbt.expect_error(format('select public.website_form_blocked(%L)', :'form'), 'counting one turned away is the server''s');
select fbt.expect_error(format('select public.website_form_check_noted(%L, %L, %L, true)', :'form', 'script', 'whatever00'), 'so is noting that a message passed');
select fbt.expect_error('select count(*) from public.website_form_turnstile', 'the Turnstile keys aren''t read in the browser');
select fbt.expect_error(format($q$insert into public.website_form_turnstile (company_id, site_key, ciphertext) values (%L, '0x4AAAAAAAAAAAAAAAAAAAAA', 'v1.x.y')$q$, :'co'), 'nor written there');
select set_config('request.jwt.claims', '{"sub": "bc170000-0000-0000-0000-000000000002", "role": "authenticated"}', true);
update public.website_forms set bot_check = 'off' where id = :'form';
select set_config('request.jwt.claims', '{"sub": "bc170000-0000-0000-0000-000000000009", "role": "authenticated"}', true);
update public.website_forms set bot_check = 'off' where id = :'form';
commit;
select fbt.check((select bot_check = 'script' from public.website_forms where id = :'form'), 'office staff and another business''s owner don''t change a form''s check');

-- ===== The server notes what it sees, and nothing refuses by itself ==========================
select key as form_key from public.website_forms where id = :'form' \gset
begin;
set local role service_role;
select fbt.expect_error(format('update public.website_forms set bot_check_armed_at = now() where id = %L', :'form'), 'not even the server makes a form refuse before a message has passed its check');
select public.website_form_check_noted(:'form', 'script', :'form_key', false);
select public.website_form_check_noted(:'form', 'script', :'form_key', false);
commit;
select fbt.check((select bot_check_missed = 2 and bot_check_missed_at is not null and bot_check_passed_at is null and bot_check_armed_at is null from public.website_forms where id = :'form'),
  'two messages kept without the check are noted, and nothing has passed');

begin;
set local role service_role;
select public.website_form_check_noted(:'form', 'script', :'form_key', true);
select public.website_form_check_noted(:'form', 'script', :'form_key', true);
select public.website_form_check_noted(:'form', 'script', :'form_key', true);
-- A message judged by a check or an address the form no longer has says nothing about this one.
select public.website_form_check_noted(:'form', 'turnstile', :'form_key', false);
select public.website_form_check_noted(:'form', 'script', '0ldaddress', false);
select public.website_form_check_noted(:'apply', 'off', (select key from public.website_forms where id = :'apply'), true);
select public.website_form_blocked(:'form');
select public.website_form_blocked(:'form');
commit;
select fbt.check((select bot_check_passed_at is not null and bot_check_missed = 2 and bot_check_armed_at is null from public.website_forms where id = :'form'),
  'messages that passed are noted, however many, and the form still refuses nothing: that''s an owner''s or admin''s to say');
select fbt.check((select bots_blocked = 2 and last_blocked_at is not null from public.website_forms where id = :'form'), 'and two turned away are counted');
select fbt.check((select bots_blocked = 0 and bot_check_passed_at is null and bot_check_missed = 0 from public.website_forms where id = :'apply'),
  'each form has its own notes and count, and a form with no check has none');

-- The server turns refusing on (when an owner or admin asks), now that a message has passed.
begin;
set local role service_role;
update public.website_forms set bot_check_armed_at = now() where id = :'form';
select fbt.expect_error(format('update public.website_forms set bot_check_armed_at = now() where id = %L', :'apply'), 'a form with no check never refuses');
commit;
select fbt.check((select bot_check_armed_at is not null from public.website_forms where id = :'form'), 'the form refuses messages without the check from then on');

-- Changing anything else keeps all of it.
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "bc170000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
update public.website_forms set name = 'Contact us', email_to = '{ivy@fern.test}', allowed_sites = '{fernlawn.com}', bot_check_armed_at = null where id = :'form';
commit;
select fbt.check((select name = 'Contact us' and bot_check_armed_at is not null and bot_check_passed_at is not null and bot_check_missed = 2 and bots_blocked = 2 from public.website_forms where id = :'form'),
  'renaming the form, or changing who it emails, keeps it refusing and keeps its notes and count (and the browser can''t stop it refusing either: the server does)');

-- A new address: the line on the website names the old one, so everything starts over.
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "bc170000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
update public.website_forms set key = 'k3y9new0ad' where id = :'form';
commit;
select fbt.check((select bot_check = 'script' and bot_check_armed_at is null and bot_check_passed_at is null and bot_check_missed = 0 and bot_check_missed_at is null and bots_blocked = 2
  from public.website_forms where id = :'form'), 'a new address refuses nothing and has seen nothing yet, and keeps the count of what was turned away');

-- ===== Turnstile needs the business's keys ===================================================
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "bc170000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select fbt.expect_error(format('update public.website_forms set bot_check = %L where id = %L', 'turnstile', :'form'), 'a form can''t ask for Turnstile before the business has keys');
select fbt.expect_error(format('insert into public.website_forms (company_id, name, bot_check) values (%L, %L, %L)', :'co', 'Another', 'turnstile'), 'nor a new form');
commit;

begin;
set local role service_role;
select fbt.expect_error(format($q$insert into public.website_form_turnstile (company_id, site_key, ciphertext) values (%L, 'not a "key"', 'v1.x.y')$q$, :'co'), 'a site key is letters, digits, - and _');
insert into public.website_form_turnstile (company_id, site_key, ciphertext) values (:'co', '0x4AAAAAAAAAAAAAAAAAAAAA', 'v1.x.y');
select public.website_form_check_noted(:'form', 'script', 'k3y9new0ad', true);
update public.website_forms set bot_check_armed_at = now() where id = :'form';
commit;

begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "bc170000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
update public.website_forms set bot_check = 'turnstile' where id in (:'form', :'apply');
select fbt.check((select count(*) = 2 and bool_and(bot_check_armed_at is null and bot_check_passed_at is null) from public.website_forms where id in (:'form', :'apply')),
  'with keys, the contact and careers forms both turn on Turnstile, and a form that was refusing with another check starts over');
select set_config('request.jwt.claims', '{"sub": "bc170000-0000-0000-0000-000000000009", "role": "authenticated"}', true);
select fbt.expect_error(format('update public.website_forms set bot_check = %L where id = %L', 'turnstile', :'other_form'), 'another business''s keys don''t count for this one');
commit;

begin;
set local role service_role;
select public.website_form_check_noted(:'apply', 'turnstile', (select key from public.website_forms where id = :'apply'), true);
select public.website_form_check_noted(:'apply', 'turnstile', (select key from public.website_forms where id = :'apply'), false);
update public.website_forms set bot_check_armed_at = now() where id = :'apply';
commit;
select fbt.check((select bot_check = 'turnstile' and bot_check_armed_at is not null and bot_check_missed = 1 from public.website_forms where id = :'apply'), 'the careers form refuses once one passed and the server is asked');

-- New keys: the widget on the website is the old one, so nothing is refused until someone says so again.
begin;
set local role service_role;
update public.website_form_turnstile set updated_at = now() where company_id = :'co';
commit;
select fbt.check((select bot_check_armed_at is not null from public.website_forms where id = :'apply'), 'saving the same keys again changes nothing');
begin;
set local role service_role;
update public.website_form_turnstile set site_key = '0x4CCCCCCCCCCCCCCCCCCCCC', ciphertext = 'v1.new.keys' where company_id = :'co';
commit;
select fbt.check((select bot_check = 'turnstile' and bot_check_armed_at is null and bot_check_passed_at is null and bot_check_missed = 0 and bot_check_missed_at is null from public.website_forms where id = :'apply'),
  'new keys start the Turnstile forms over: nothing passed, nothing missed, nothing refused');
select fbt.check((select bot_check = 'script' from public.website_forms where id = :'quote_form'), 'and leave a form on Jobly''s own check alone');

-- The careers form refuses again, with the new keys, to see what removing them does to it.
begin;
set local role service_role;
select public.website_form_check_noted(:'apply', 'turnstile', (select key from public.website_forms where id = :'apply'), true);
update public.website_forms set bot_check_armed_at = now() where id = :'apply';
commit;

-- Removing the keys: the forms that used them go back to the hidden field only.
begin;
set local role service_role;
delete from public.website_form_turnstile where company_id = :'co';
commit;
select fbt.check((select count(*) = 2 and bool_and(bot_check = 'off' and bot_check_armed_at is null and bot_check_passed_at is null) from public.website_forms where id in (:'form', :'apply')),
  'removing the keys turns the Turnstile forms'' check off, a refusing one included');
select fbt.check((select bot_check = 'script' from public.website_forms where id = :'quote_form'), 'and leaves a form on Jobly''s own check alone');
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "bc170000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select fbt.expect_error(format('update public.website_forms set bot_check = %L where id = %L', 'turnstile', :'apply'), 'and with the keys gone, Turnstile can''t be turned back on');
commit;

-- A business that's deleted takes its forms and keys with it.
begin;
set local role service_role;
insert into public.website_form_turnstile (company_id, site_key, ciphertext) values (:'other', '0x4BBBBBBBBBBBBBBBBBBBBB', 'v1.x.y');
update public.website_forms set bot_check = 'turnstile' where id = :'other_form';
commit;
delete from public.companies where id = :'other';
select fbt.check((select count(*) = 0 from public.website_forms where company_id = :'other') and (select count(*) = 0 from public.website_form_turnstile where company_id = :'other'),
  'deleting a business removes its forms and its keys');
