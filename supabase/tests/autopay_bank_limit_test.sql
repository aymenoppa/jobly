-- Database tests for 20261116000100_bank_charges_over_the_limit_go_to_the_client.sql: a saved bank
-- account is never charged more than the autopay limit. Which methods are bank accounts and what
-- the limit is (the business's now, or the one in the words the client agreed to when that's lower);
-- the automatic run closing such a charge and handing its invoice over to be sent; the office's OK,
-- Charge card, a retry on a bank account agreed to since, and a charge already in a server's hands
-- all refused; a card over the limit and a bank account within it charged as before; other reasons
-- to ask the office still asked within the limit, and over it the invoice left for the office to
-- look over; charges waiting as the update arrives; a bank payment already on its way left to
-- finish; the invoice claimed once to send and the office told once, sent or not; nobody asked to
-- agree again.
-- Run with scripts/test-db.sh (plain Postgres + prelude.sql). Any failed check stops with an error.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema tbl;
grant usage on schema tbl to authenticated, service_role, anon;
create sequence tbl.checks;
grant usage on sequence tbl.checks to authenticated, service_role, anon;
create function tbl.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_what; end if;
  perform nextval('tbl.checks');
  raise notice 'ok - %', p_what;
end $$;
-- Signs in as someone, or as nobody (the server), for the rest of the transaction.
create function tbl.as_user(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', case when p_user is null then '' else json_build_object('sub', p_user, 'role', 'authenticated')::text end, true)
$$;
create function tbl.settings(p_max numeric default 500) returns jsonb language sql as $$
  select jsonb_build_object('enabled', true, 'terms', 'We charge the card or bank account on file after each visit is done.', 'timing', 'now', 'days', null,
    'max_amount', p_max, 'receipts', true, 'jobs_default', true, 'card_required', false)
$$;
grant execute on all functions in schema tbl to authenticated, service_role, anon;

-- The rest are the server's and the test's own shortcuts, run past row-level security.

-- A saved method for a client, as the server saves one.
create function tbl.method(p_company uuid, p_client uuid, p_type text, p_key text) returns uuid language sql as $$
  select public.autopay_save_payment_method(p_company, p_client, jsonb_build_object(
    'stripe_payment_method_id', 'pm_' || p_key, 'stripe_customer_id', 'cus_' || p_key, 'stripe_account', 'acct_limit', 'livemode', false,
    'type', p_type, 'status', 'active', 'source', 'hub', 'make_default', true)
    || case when p_type = 'card' then '{"brand": "visa", "last4": "4242", "exp_month": 8, "exp_year": 2030}'::jsonb else '{"bank_name": "Chase", "last4": "6789"}'::jsonb end)
$$;
-- A client on autopay with a card or a bank account, agreed to today's terms.
create function tbl.ready_client(p_company uuid, p_name text, p_type text default 'us_bank_account') returns uuid language plpgsql as $$
declare
  v_client uuid;
  v_pm uuid;
begin
  insert into public.clients (company_id, display_name, email) values (p_company, p_name, replace(lower(p_name), ' ', '.') || '@limit.test') returning id into v_client;
  v_pm := tbl.method(p_company, v_client, p_type, replace(lower(p_name), ' ', '_'));
  perform public.autopay_record_authorization(p_company, v_client, v_pm, 'hub', private.autopay_terms_version(p_company), '203.0.113.7', 'Test browser', 'client', 'client');
  return v_client;
end $$;
-- A weekly mow at p_price a visit, with one visit finished now: its charge, due at once.
create function tbl.finished_visit(p_company uuid, p_client uuid, p_price numeric, p_held text default null) returns uuid language plpgsql as $$
declare
  v_job uuid;
  v_visit uuid;
  v_charge uuid;
begin
  insert into public.jobs (company_id, client_id, title, kind, recurrence_rule, billing_mode)
  values (p_company, p_client, 'Weekly mow', 'recurring', 'FREQ=WEEKLY;BYDAY=MO', 'per_visit') returning id into v_job;
  insert into public.job_line_items (company_id, job_id, name, quantity, unit, unit_price) values (p_company, v_job, 'Mowing', 1, 'visit', p_price);
  insert into public.visits (company_id, job_id, title, scheduled_on) values (p_company, v_job, 'Mow', private.company_today(p_company)) returning id into v_visit;
  update public.visits set status = 'completed' where id = v_visit;
  select id into v_charge from public.autopay_charges where job_id = v_job and status = 'waiting';
  if v_charge is null then raise exception 'FAIL: the finished visit queued no charge'; end if;
  -- As autopay_queue holds one an AI assistant finished.
  update public.autopay_charges set held = p_held where id = v_charge and p_held is not null;
  return v_charge;
end $$;
-- An invoice for a client, for p_amount: sent, or left a draft.
create function tbl.invoice(p_company uuid, p_client uuid, p_amount numeric, p_draft boolean default false) returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.invoices (company_id, client_id, subject) values (p_company, p_client, 'Mowing') returning id into v_id;
  insert into public.invoice_line_items (company_id, invoice_id, name, unit_price) values (p_company, v_id, 'Mowing', p_amount);
  if not p_draft then update public.invoices set status = 'sent' where id = v_id; end if;
  return v_id;
end $$;
-- The task's claim of one charge: its token. Fails if anything else was due.
create function tbl.claim(p_company uuid, p_charge uuid) returns uuid language plpgsql as $$
declare
  v_token uuid;
  v_others text;
begin
  select (array_agg(claim_token) filter (where id = p_charge))[1], string_agg(id::text, ', ') filter (where id <> p_charge)
  into v_token, v_others from public.claim_autopay_charges(100, p_company);
  if v_others is not null then raise exception 'FAIL: the claim took other charges too: %', v_others; end if;
  return v_token;
end $$;
-- Claim it and bill it, as the task does before it asks Stripe: autopay_bill's answer, with the token.
create function tbl.bill(p_company uuid, p_charge uuid) returns jsonb language plpgsql as $$
declare
  v_token uuid := tbl.claim(p_company, p_charge);
begin
  if v_token is null then raise exception 'FAIL: % wasn''t due', p_charge; end if;
  return public.autopay_bill(p_charge, v_token) || jsonb_build_object('token', v_token);
end $$;
-- Then mark it sent and say how Stripe answered.
create function tbl.finish(p_charge uuid, p_bill jsonb, p_outcome text) returns boolean language plpgsql as $$
begin
  if not public.autopay_mark_sent(p_charge, (p_bill ->> 'token')::uuid, round((p_bill ->> 'balance_due')::numeric * 100)::integer) then return false; end if;
  return public.finish_autopay_charge(p_charge, p_outcome, (p_bill ->> 'token')::uuid, case when p_outcome = 'declined' then 'Your card was declined' end,
    case when p_outcome = 'declined' then 'card_declined' end, (p_bill ->> 'balance_due')::numeric);
end $$;
-- A charge as "status: last_error".
create function tbl.state(p_charge uuid) returns text language sql as $$
  select status || coalesce(': ' || last_error, '') from public.autopay_charges where id = p_charge
$$;
-- Whether a charge was closed over a bank account's limit of p_limit, with its invoice waiting to go to the client.
create function tbl.to_client(p_charge uuid, p_limit numeric, p_send text default 'waiting') returns boolean language sql as $$
  select status = 'called_off' and last_error = 'Over the limit for a bank account. The client pays this one themselves'
    and bank_limit = p_limit and bank_limit_at is not null and send_state is not distinct from p_send and claim_token is null
  from public.autopay_charges where id = p_charge
$$;
-- Notifications about autopay for someone, as "title | body" lines.
create function tbl.told(p_user uuid, p_like text default '%') returns text language sql as $$
  select string_agg(title || ' | ' || coalesce(body, ''), E'\n' order by created_at, title)
  from public.notifications where user_id = p_user and kind = 'autopay' and title like p_like
$$;
create function tbl.error_of(p_sql text) returns text language plpgsql as $$
begin
  begin execute p_sql; exception when others then return sqlstate || ': ' || sqlerrm; end;
  return 'none';
end $$;
grant execute on all functions in schema tbl to authenticated;

\set ora 'b1b10000-0000-0000-0000-000000000001'
\set reason 'Over the limit for a bank account. The client pays this one themselves'
\set old_words 'If you pay from a bank account: you have the right to be told the amount and date of each charge at least 10 days before it''s made. By agreeing, you choose to be told ahead only when a charge is more than $500.00, and we''ll send you its amount and date at least 10 days before we make it. Charges of $500.00 or less are made without notice ahead of time.'

-- Everything below is rolled back at the end.
begin;
insert into auth.users (id, email, raw_user_meta_data) values (:'ora', 'ora@limit.test', '{"full_name": "Ora Owner"}');
set local role authenticated;
select tbl.as_user(:'ora');
select public.create_company('Limit Lawn', 'lawn_exterior') as co \gset
reset role;
insert into public.integrations (company_id, provider, status, settings) values (:'co', 'stripe', 'connected', '{"autopay": true, "refunds": true}');
set local role authenticated;
select public.autopay_set_settings(:'co', tbl.settings()) ->> 'terms_version' as v500 \gset
reset role;
select tbl.as_user(null);

\o
\echo 'Which methods, and which limit'
\o /dev/null
select tbl.check(private.autopay_is_bank('us_bank_account') and private.autopay_is_bank('sepa_debit') and private.autopay_is_bank('acss_debit')
    and not private.autopay_is_bank('card') and not private.autopay_is_bank('link') and not private.autopay_is_bank(null),
  'a US bank account and another country''s bank debit are bank accounts; a card and Link are not');
select tbl.check(private.autopay_agreed_cap(private.autopay_terms_shown(:'co')) = 500
    and private.autopay_agreed_cap('Our words.' || E'\n\n' || private.autopay_bank_text('{"max_amount": 1250.5}')) = 1250.5
    and private.autopay_agreed_cap('Our words.' || E'\n\n' || :'old_words') = 500,
  'the limit a client agreed to is read from the bank account paragraph of their words, as it''s written now and as it was before');
select tbl.check(private.autopay_agreed_cap('Our words.' || E'\n\n' || private.autopay_bank_text('{"max_amount": null}')) is null
    and private.autopay_agreed_cap('We charge the card on file after each visit is done.') is null
    and private.autopay_agreed_cap('Jobs of more than $50.00 need a deposit.' || E'\n\n' || private.autopay_bank_text('{"max_amount": null}')) is null
    and private.autopay_agreed_cap('Jobs of more than $50.00 need a deposit.' || E'\n\n' || private.autopay_bank_text('{"max_amount": 300}')) = 300
    and private.autopay_agreed_cap(null) is null,
  'words that name no limit have none, and an amount in the business''s own words is never taken for it');

select tbl.ready_client(:'co', 'Bea Bank') as bea \gset
select tbl.ready_client(:'co', 'Cal Card', 'card') as cal \gset
select id as bea_pm from public.client_payment_methods where client_id = :'bea' \gset
select id as cal_pm from public.client_payment_methods where client_id = :'cal' \gset
select tbl.check(private.autopay_bank_limit(:'co', :'bea', :'bea_pm') = 500 and private.autopay_bank_limit(:'co', :'cal', :'cal_pm') is null
    and private.autopay_bank_limit(:'co', :'bea', null) is null,
  'a bank account''s limit is the business''s; a card has none');

\o
\echo 'The automatic run'
\o /dev/null
select tbl.finished_visit(:'co', :'bea', 600) as bea600 \gset
select tbl.bill(:'co', :'bea600') as bill \gset
select invoice_id as bea600_inv from public.autopay_charges where id = :'bea600' \gset
select tbl.check((:'bill'::jsonb) ->> 'outcome' = 'called_off' and (:'bill'::jsonb) -> 'to_client' = 'true' and (:'bill'::jsonb) ->> 'reason' = :'reason'
    and tbl.to_client(:'bea600', 500),
  'a $600 visit on a bank account with a $500 limit isn''t charged: the charge is closed, and its invoice waits to go to the client');
select tbl.check((select status = 'draft' and balance_due = 600 from public.invoices where id = :'bea600_inv')
    and not exists (select 1 from public.stripe_invoices where invoice_id = :'bea600_inv'),
  'the invoice is there as a draft, with nothing made in Stripe');
select tbl.check(tbl.told(:'ora') is null, 'nobody is told yet: not asked for an OK, and not told to send it, until it has gone or couldn''t');
select tbl.check((select count(*) = 1 from public.outbox where topic = 'stripe.invoice' and payload ->> 'invoice_id' = :'bea600_inv' and done_at is null),
  'its Stripe invoice is brought in step, as for any charge called off');

select tbl.finished_visit(:'co', :'bea', 450) as bea450 \gset
select tbl.bill(:'co', :'bea450') as bill \gset
select tbl.finish(:'bea450', :'bill', 'processing') as done \gset
select tbl.check((:'bill'::jsonb) ->> 'outcome' = 'charge' and (:'bill'::jsonb) -> 'method' ->> 'type' = 'us_bank_account'
    and :'done' and tbl.state(:'bea450') = 'processing',
  'a $450 visit on the same bank account is charged as before');
select tbl.finished_visit(:'co', :'bea', 500) as bea500 \gset
select tbl.bill(:'co', :'bea500') as bill \gset
select tbl.finish(:'bea500', :'bill', 'processing') as done \gset
select tbl.check((:'bill'::jsonb) ->> 'outcome' = 'charge' and :'done', 'and so is one for exactly the limit');

select tbl.finished_visit(:'co', :'cal', 600) as cal600 \gset
select tbl.bill(:'co', :'cal600') as bill \gset
select tbl.check((:'bill'::jsonb) ->> 'outcome' = 'needs_approval' and tbl.state(:'cal600') = 'needs_approval'
    and tbl.told(:'ora', 'Approve%Cal%') = 'Approve a $600.00 charge for Cal Card | It''s over your autopay limit, so it waits for your OK.',
  'a $600 visit on a card waits for the office''s OK, as before');
set local role authenticated;
select tbl.as_user(:'ora');
select public.approve_autopay_charge(:'cal600');
reset role;
select tbl.as_user(null);
select tbl.bill(:'co', :'cal600') as bill \gset
select tbl.finish(:'cal600', :'bill', 'paid') as done \gset
select tbl.check((:'bill'::jsonb) ->> 'outcome' = 'charge' and (:'bill'::jsonb) -> 'method' ->> 'type' = 'card' and :'done'
    and tbl.state(:'cal600') = 'paid' and (select bank_limit is null and send_state is null from public.autopay_charges where id = :'cal600'),
  'and the OK charges the card');

\o
\echo 'Other reasons to ask the office'
\o /dev/null
select tbl.finished_visit(:'co', :'bea', 450, 'An AI assistant marked the work done') as held450 \gset
select tbl.bill(:'co', :'held450') as bill \gset
select tbl.check((:'bill'::jsonb) ->> 'outcome' = 'needs_approval' and tbl.state(:'held450') = 'needs_approval: An AI assistant marked the work done',
  'work an assistant marked done still waits for the OK on a bank account, within the limit');
set local role authenticated;
select tbl.as_user(:'ora');
select public.approve_autopay_charge(:'held450');
reset role;
select tbl.as_user(null);
select tbl.bill(:'co', :'held450') as bill \gset
select tbl.check((:'bill'::jsonb) ->> 'outcome' = 'charge' and tbl.finish(:'held450', :'bill', 'processing'), 'and the OK charges the bank account, as before');
select tbl.finished_visit(:'co', :'bea', 600, 'An AI assistant marked the work done') as held600 \gset
select tbl.bill(:'co', :'held600') as bill \gset
select tbl.check((:'bill'::jsonb) ->> 'outcome' = 'called_off' and tbl.to_client(:'held600', 500, 'held') and tbl.told(:'ora', 'Approve%Bea%') like '%$450.00%'
    and tbl.told(:'ora', 'Approve%Bea%') not like '%$600.00%',
  'over the limit as well, no OK is asked for, since none could charge it: the charge is closed');
select tbl.check((select send_error = 'An AI assistant marked the work done' and send_draft from public.autopay_charges where id = :'held600')
    and (select i.status = 'draft' from public.invoices i join public.autopay_charges a on a.invoice_id = i.id where a.id = :'held600')
    and tbl.told(:'ora', 'Send invoice%Bea%') like 'Send invoice #% to Bea Bank | $600.00 is over the $500.00 limit for their bank account, so it wasn''t taken from it. Look it over before you send it: An AI assistant marked the work done.',
  'and because the office was to look at it first, it isn''t sent by itself: they''re told once to look it over and send it');

\o
\echo 'The office''s OK, and charges already waiting'
\o /dev/null
-- As a charge stood before this: over the limit on a bank account, waiting for the OK.
select tbl.ready_client(:'co', 'Dee Before') as dee \gset
select tbl.ready_client(:'co', 'Eli Before') as eli \gset
select tbl.ready_client(:'co', 'Fay Before') as fay \gset
select tbl.finished_visit(:'co', :'dee', 600) as dee600 \gset
select tbl.finished_visit(:'co', :'eli', 700) as eli700 \gset
select tbl.finished_visit(:'co', :'fay', 800) as fay800 \gset
update public.autopay_charges set due_at = now() + interval '1 day' where id in (:'dee600', :'eli700', :'fay800');
select public.create_invoice_for_job(job_id, 'visits') from public.autopay_charges where id in (:'dee600', :'eli700', :'fay800');
update public.autopay_charges a set status = 'needs_approval', invoice_id = (select i.id from public.invoices i where i.job_id = a.job_id),
  last_error = case when a.id = :'fay800' then 'Includes extra work added to a visit' end
where a.id in (:'dee600', :'eli700', :'fay800');
select tbl.check((select count(*) = 3 from public.autopay_charges where id in (:'dee600', :'eli700', :'fay800') and status = 'needs_approval' and invoice_id is not null)
    and tbl.told(:'ora', 'Approve%Dee%') like 'Approve a $600.00 charge for Dee Before | %',
  'three bank account charges over the limit wait for the OK, as they did before the update');

set local role authenticated;
select tbl.as_user(:'ora');
select public.approve_autopay_charge(:'dee600');
reset role;
select tbl.as_user(null);
select count(*) as claimed_dee from public.claim_autopay_charges(100, :'co') c where c.id = :'dee600' \gset
select tbl.check(tbl.to_client(:'dee600', 500) and (select approved_at is null and approved_by is null from public.autopay_charges where id = :'dee600')
    and :claimed_dee = 0,
  'the office''s OK doesn''t charge one: it''s closed, its invoice goes to the client, and nothing is left to claim');
select tbl.check(tbl.to_client(:'eli700', 500), 'every claim closes the ones still waiting, without anyone pressing anything');
select tbl.check(tbl.to_client(:'fay800', 500, 'held') and tbl.told(:'ora', 'Send invoice%Fay%') like '%Look it over before you send it: Includes extra work added to a visit.',
  'one that waited for another reason too is closed and left for the office to look over and send');
select tbl.check(private.autopay_bank_limit_sweep() = 0, 'and a second pass finds nothing: each is closed once');

-- A card's waiting charge, and a bank account's within the limit, are left for the office.
select tbl.finished_visit(:'co', :'cal', 900) as cal900 \gset
select tbl.bill(:'co', :'cal900') as bill \gset
select tbl.finished_visit(:'co', :'bea', 300, 'An AI assistant marked the work done') as held300 \gset
select tbl.bill(:'co', :'held300') as bill \gset
select tbl.check(private.autopay_bank_limit_sweep() = 0 and tbl.state(:'cal900') = 'needs_approval' and tbl.state(:'held300') like 'needs_approval:%',
  'a card''s charge over the limit, and a bank account''s within it, go on waiting for the OK');
set local role authenticated;
select tbl.as_user(:'ora');
select public.call_off_autopay_charge(:'cal900');
select public.call_off_autopay_charge(:'held300');
reset role;
select tbl.as_user(null);

-- With autopay off in Settings nothing is closed or sent by this rule: the OK ends as it always did.
select tbl.ready_client(:'co', 'Lou Off') as lou \gset
select tbl.finished_visit(:'co', :'lou', 600) as lou600 \gset
update public.autopay_charges set due_at = now() + interval '1 day' where id = :'lou600';
select public.create_invoice_for_job(job_id, 'visits') from public.autopay_charges where id = :'lou600';
update public.autopay_charges a set status = 'needs_approval', invoice_id = (select i.id from public.invoices i where i.job_id = a.job_id) where a.id = :'lou600';
set local role authenticated;
select tbl.as_user(:'ora');
select public.autopay_set_settings(:'co', tbl.settings() || '{"enabled": false}') as nothing \gset
reset role;
select tbl.as_user(null);
select tbl.check(private.autopay_bank_limit_sweep() = 0 and tbl.state(:'lou600') = 'needs_approval', 'with autopay off in Settings, a waiting charge isn''t closed by this rule or sent to anyone');
set local role authenticated;
select tbl.as_user(:'ora');
select public.approve_autopay_charge(:'lou600');
reset role;
select tbl.as_user(null);
select tbl.bill(:'co', :'lou600') as bill \gset
select tbl.check(tbl.state(:'lou600') = 'called_off: Autopay is turned off in Settings' and (select bank_limit is null and send_state is null from public.autopay_charges where id = :'lou600')
    and tbl.told(:'ora', 'Send invoice%Lou%') like 'Send invoice #% to Lou Off the usual way | Autopay is turned off in Settings',
  'the OK then ends as it always did: called off, and the office told to send it the usual way');
set local role authenticated;
select tbl.as_user(:'ora');
select public.autopay_set_settings(:'co', tbl.settings()) as nothing \gset
reset role;
select tbl.as_user(null);

-- A bank payment already on its way for the invoice (the charge's own, its answer lost): left to finish.
select tbl.ready_client(:'co', 'Moe Clearing') as moe \gset
select tbl.finished_visit(:'co', :'moe', 600) as moe600 \gset
select tbl.bill(:'co', :'moe600') as nothing \gset
select invoice_id as moe_inv from public.autopay_charges where id = :'moe600' \gset
update public.invoices set status = 'sent' where id = :'moe_inv';
update public.autopay_charges set status = 'charging', claim_token = '00000000-0000-0000-0000-00000000bbbb', locked_until = now() + interval '5 minutes',
  last_error = null, bank_limit = null, bank_limit_at = null, send_state = null, send_draft = null where id = :'moe600';
insert into public.stripe_invoices (company_id, invoice_id, stripe_id, origin, status, amount_due, collection, purpose)
values (:'co', :'moe_inv', 'in_moe_clearing', 'jobly', 'processing', 600, 'charge_automatically', 'invoice');
select public.autopay_bill(:'moe600', '00000000-0000-0000-0000-00000000bbbb') as bill \gset
select tbl.check((:'bill'::jsonb) ->> 'outcome' = 'charge' and tbl.state(:'moe600') = 'charging',
  'a charge whose bank payment is already on its way isn''t closed: the server follows that payment, and the client isn''t told to pay meanwhile');
select tbl.check(not public.autopay_mark_sent(:'moe600', '00000000-0000-0000-0000-00000000bbbb', 60000), 'and nothing new could be asked of the bank for it');
-- It bounced.
delete from public.stripe_invoices where stripe_id = 'in_moe_clearing';
select public.autopay_bill(:'moe600', '00000000-0000-0000-0000-00000000bbbb') as bill \gset
select tbl.check((:'bill'::jsonb) ->> 'outcome' = 'called_off' and tbl.to_client(:'moe600', 500)
    and (select not send_draft from public.autopay_charges where id = :'moe600'),
  'once nothing is on its way, it''s closed and the invoice goes to the client');

-- One a server from before this had in hand as the update arrived: billed, about to be charged.
select tbl.ready_client(:'co', 'Gus Inflight') as gus \gset
select tbl.finished_visit(:'co', :'gus', 600) as gus600 \gset
select tbl.bill(:'co', :'gus600') as nothing \gset
-- Put back as the earlier server left it: claimed, billed, its Stripe invoice made.
update public.autopay_charges set status = 'charging', claim_token = '00000000-0000-0000-0000-00000000aaaa', locked_until = now() + interval '5 minutes',
  last_error = null, bank_limit = null, bank_limit_at = null, send_state = null, send_draft = null where id = :'gus600';
select tbl.check(not public.autopay_mark_sent(:'gus600', '00000000-0000-0000-0000-00000000aaaa', 60000)
    and (select i.status = 'draft' from public.invoices i join public.autopay_charges a on a.invoice_id = i.id where a.id = :'gus600'),
  'a charge already in a server''s hands stops at the last step before Stripe is told to charge');
select public.finish_autopay_charge(:'gus600', 'retry', '00000000-0000-0000-0000-00000000aaaa', 'The invoice changed');
update public.autopay_charges set locked_until = now() - interval '1 minute' where id = :'gus600';
select tbl.bill(:'co', :'gus600') as bill \gset
select tbl.check((:'bill'::jsonb) ->> 'outcome' = 'called_off' and tbl.to_client(:'gus600', 500), 'and its next claim closes it');

\o
\echo 'A retry, and Charge card'
\o /dev/null
-- A card declined twice, then the client agrees to a bank account: the charge is tried on it.
select tbl.ready_client(:'co', 'Hal Switch', 'card') as hal \gset
select tbl.finished_visit(:'co', :'hal', 520) as hal520 \gset
select tbl.bill(:'co', :'hal520') as bill \gset
set local role authenticated;
select tbl.as_user(:'ora');
select public.approve_autopay_charge(:'hal520');
reset role;
select tbl.as_user(null);
select tbl.bill(:'co', :'hal520') as bill \gset
select tbl.finish(:'hal520', :'bill', 'declined') as nothing \gset
update public.autopay_charges set due_at = now() where id = :'hal520';
select tbl.bill(:'co', :'hal520') as bill \gset
select tbl.finish(:'hal520', :'bill', 'declined') as nothing \gset
select invoice_id as hal_inv from public.autopay_charges where id = :'hal520' \gset
select tbl.check(tbl.state(:'hal520') like 'needs_client:%' and (select status = 'sent' from public.invoices where id = :'hal_inv'), 'a $520 card charge, approved, is declined twice and waits on the client');
select public.autopay_record_authorization(:'co', :'hal', tbl.method(:'co', :'hal', 'us_bank_account', 'hal_bank'), 'hub', private.autopay_terms_version(:'co'), null, null, 'client', 'client') as nothing \gset
select tbl.check(tbl.state(:'hal520') like 'failed:%' and (select due_at <= now() from public.autopay_charges where id = :'hal520'), 'agreeing to a bank account puts the charge up to be tried on it');
select tbl.bill(:'co', :'hal520') as bill \gset
select tbl.check((:'bill'::jsonb) ->> 'outcome' = 'called_off' and tbl.to_client(:'hal520', 500) and (select status = 'sent' and balance_due = 520 from public.invoices where id = :'hal_inv'),
  'the retry isn''t made on the bank account: the charge is closed, and the invoice, still owed, goes to them to pay');

select tbl.invoice(:'co', :'bea', 650) as bea650 \gset
select tbl.invoice(:'co', :'bea', 120) as bea120 \gset
select tbl.invoice(:'co', :'cal', 650) as cal650 \gset
set local role authenticated;
select tbl.as_user(:'ora');
select tbl.check((select string_agg(outcome || coalesce(': ' || reason, ''), ' / ') from public.request_manual_charges(:'co', array[:'bea650', :'bea120', :'cal650']::uuid[], array[650, 120, 650]::numeric[]))
    = 'bank_limit: It''s over the $500.00 limit for their bank account, so it isn''t taken from it. Send it to them to pay / queued / queued',
  'Charge card refuses a bank account''s invoice over the limit, and takes one within it and a card''s over it');
select tbl.check((select array_agg(id order by balance_due) = array[:'bea120', :'cal650']::uuid[] from public.chargeable_invoices(:'co') where id in (:'bea650', :'bea120', :'cal650')),
  'and the list of invoices it can charge leaves it out');
select tbl.check((select count(*) = 0 from public.chargeable_invoices(:'co', :'bea650')), 'so the invoice page has no Charge card for it');
reset role;
select tbl.as_user(null);
select tbl.check((select count(*) = 0 from public.autopay_charges where invoice_id = :'bea650'), 'nothing was queued for it');
-- One queued by a Charge card pressed before the update.
insert into public.autopay_charges (company_id, client_id, source, invoice_id, payment_method_id, due_at, status, approved_by, approved_at, approved_amount, requested_by)
values (:'co', :'bea', 'manual', :'bea650', :'bea_pm', now(), 'waiting', :'ora', now(), 650, :'ora') returning id as bea650_c \gset
select (array_agg(claim_token))[1] as token from public.claim_autopay_charges(100, :'co') \gset
select public.autopay_bill(:'bea650_c', :'token') as bill \gset
select tbl.check((:'bill'::jsonb) ->> 'outcome' = 'called_off' and tbl.to_client(:'bea650_c', 500),
  'a Charge card queued before the update isn''t made either');
select public.release_autopay_charges(:'token', array(select id from public.autopay_charges where claim_token = :'token'));
update public.autopay_charges set status = 'called_off', last_error = 'Called off by the office' where invoice_id in (:'bea120', :'cal650') and status = 'waiting';

\o
\echo 'The limit a client agreed to'
\o /dev/null
set local role authenticated;
select tbl.as_user(:'ora');
select public.autopay_set_settings(:'co', tbl.settings(800)) as nothing \gset
reset role;
select tbl.as_user(null);
select tbl.ready_client(:'co', 'Ivy Later') as ivy \gset
select tbl.check(private.autopay_bank_limit(:'co', :'bea', :'bea_pm') = 500
    and private.autopay_bank_limit(:'co', :'ivy', (select id from public.client_payment_methods where client_id = :'ivy')) = 800,
  'the business raises its limit to $800: a bank account that agreed to $500 keeps $500, and one that agrees now has $800');
select tbl.finished_visit(:'co', :'bea', 600) as bea600b \gset
select tbl.bill(:'co', :'bea600b') as bill \gset
select tbl.check((:'bill'::jsonb) ->> 'outcome' = 'called_off' and tbl.to_client(:'bea600b', 500), 'so $600 still isn''t taken from the first');
select tbl.finished_visit(:'co', :'ivy', 600) as ivy600 \gset
select tbl.bill(:'co', :'ivy600') as bill \gset
select tbl.check((:'bill'::jsonb) ->> 'outcome' = 'charge' and tbl.finish(:'ivy600', :'bill', 'processing'), 'and is from the second');
set local role authenticated;
select tbl.as_user(:'ora');
select public.autopay_set_settings(:'co', tbl.settings(300)) as nothing \gset
reset role;
select tbl.as_user(null);
select tbl.check(private.autopay_bank_limit(:'co', :'bea', :'bea_pm') = 300 and private.autopay_bank_limit(:'co', :'ivy', (select id from public.client_payment_methods where client_id = :'ivy')) = 300,
  'a limit brought down to $300 holds for every bank account, whatever it agreed to');
set local role authenticated;
select tbl.as_user(:'ora');
select public.autopay_set_settings(:'co', tbl.settings(null)) as nothing \gset
reset role;
select tbl.as_user(null);
select tbl.ready_client(:'co', 'Kay Nolimit') as kay \gset
select id as kay_pm from public.client_payment_methods where client_id = :'kay' \gset
select tbl.check(private.autopay_bank_limit(:'co', :'bea', :'bea_pm') = 500 and private.autopay_bank_limit(:'co', :'kay', :'kay_pm') is null,
  'with the limit taken off, a bank account that agreed to $500 keeps $500, and one that agrees now has none');
select tbl.finished_visit(:'co', :'kay', 5000) as kay5000 \gset
select tbl.bill(:'co', :'kay5000') as bill \gset
select tbl.check((:'bill'::jsonb) ->> 'outcome' = 'charge' and tbl.finish(:'kay5000', :'bill', 'processing'), 'so every charge of theirs is taken, as their words say');
set local role authenticated;
select tbl.as_user(:'ora');
select public.autopay_set_settings(:'co', tbl.settings(500)) as nothing \gset
reset role;
select tbl.as_user(null);
select tbl.check(private.autopay_bank_limit(:'co', :'kay', :'kay_pm') = 500, 'and a limit set later holds for them too');

\o
\echo 'Nobody is asked to agree again'
\o /dev/null
-- Jan agreed to the words as they were before this, bank account paragraph and all.
insert into public.clients (company_id, display_name, email) values (:'co', 'Jan Agreed', 'jan@limit.test') returning id as jan \gset
select tbl.method(:'co', :'jan', 'us_bank_account', 'jan') as jan_pm \gset
insert into public.autopay_authorizations (company_id, client_id, payment_method_id, terms, terms_version, source, link_kind, link_via, accepted_at)
values (:'co', :'jan', :'jan_pm', 'We charge the card or bank account on file after each visit is done.' || E'\n\nWe charge right after each visit.\n\n' || :'old_words',
  '2026-11-01T09:00:00+bank', 'hub', 'client', 'client', now() - interval '10 days') returning id as jan_agreed \gset
select tbl.check(private.autopay_ready(:'co', :'jan') = :'jan_pm' and private.autopay_bank_limit(:'co', :'jan', :'jan_pm') = 500,
  'an agreement made with the earlier words and version is in force as it is, with the limit those words named');
select tbl.finished_visit(:'co', :'jan', 80) as jan80 \gset
select tbl.bill(:'co', :'jan80') as bill \gset
select tbl.check((:'bill'::jsonb) ->> 'outcome' = 'charge' and tbl.finish(:'jan80', :'bill', 'processing'), 'their $80 visit is charged without them agreeing to anything new');
select tbl.finished_visit(:'co', :'jan', 600) as jan600 \gset
select tbl.bill(:'co', :'jan600') as bill \gset
select tbl.check((:'bill'::jsonb) ->> 'outcome' = 'called_off' and tbl.to_client(:'jan600', 500), 'and their $600 one goes to them to pay');
select tbl.check((select revoked_at is null and terms like '%at least 10 days before we make it%' and terms_version = '2026-11-01T09:00:00+bank' from public.autopay_authorizations where id = :'jan_agreed')
    and (select count(*) = 1 from public.autopay_authorizations where client_id = :'jan'),
  'the agreement is untouched: its words and version are the ones they agreed to');

\o
\echo 'The invoice goes to the client, and the office is told once'
\o /dev/null
-- Waiting to go: Bea's two visits and her Charge card, Dee, Eli, Gus, Hal, Jan and Moe. The two
-- held for the office's look (the assistant's, Fay's) are not.
select tbl.check((select count(*) = 9 from public.autopay_charges where company_id = :'co' and send_state = 'waiting' and bank_limit is not null)
    and (select count(*) = 2 from public.autopay_charges where company_id = :'co' and send_state = 'held'),
  'every charge closed over the limit has its invoice waiting to go, but for the ones the office looks over first');
-- Deleted, voided, or a draft the office sent since: nothing is left to send.
delete from public.invoices where id = (select invoice_id from public.autopay_charges where id = :'bea600b');
update public.invoices set status = 'void' where id = (select invoice_id from public.autopay_charges where id = :'eli700');
update public.invoices set status = 'sent' where id = (select invoice_id from public.autopay_charges where id = :'jan600');
-- A bank payment for Hal's is on its way (they paid on Stripe's page): it waits for that.
insert into public.stripe_invoices (company_id, invoice_id, stripe_id, origin, status, amount_due, collection, purpose)
values (:'co', :'hal_inv', 'in_hal_clearing', 'jobly', 'processing', 520, 'send_invoice', 'invoice');
create temporary table claimed on commit drop as select * from public.claim_autopay_sends(3, :'co');
select tbl.check((select count(*) = 3 and bool_and(bank_limit = 500 and invoice_id is not null and send_draft is not null) from claimed)
    and (select count(*) = 3 from public.autopay_charges where company_id = :'co' and send_state = 'sending' and send_claimed_at is not null),
  'the server claims as many as it asked for, each with its invoice and the limit it was over');
select tbl.check((select bool_and(send_state is null) from public.autopay_charges where id in (:'bea600b', :'eli700', :'jan600'))
    and not exists (select 1 from claimed where id in (:'bea600b', :'eli700', :'jan600')),
  'one deleted, one voided and a draft the office sent meanwhile are not sent');
select count(*) as second from public.claim_autopay_sends(20, :'co') \gset
select count(*) as third from public.claim_autopay_sends(20, :'co') \gset
select tbl.check(:second = 2 and :third = 0 and tbl.to_client(:'hal520', 500),
  'the next run takes the rest, nothing is claimed twice, and one with a bank payment on its way waits');
-- An invoice that had gone out before its charge was closed (Moe's, Hal's) is sent all the same: the client hasn't been told it's theirs.
select tbl.check(:'moe600' in (select id from public.autopay_charges where send_state = 'sending'), 'one already sent before its charge was closed is still handed over, to say it''s theirs to pay');
delete from public.stripe_invoices where stripe_id = 'in_hal_clearing';
select tbl.check((select array_agg(id) = array[:'hal520']::uuid[] from public.claim_autopay_sends(20, :'co')), 'and once that payment has bounced, it goes');
select tbl.check(tbl.to_client(:'held600', 500, 'held') and tbl.to_client(:'fay800', 500, 'held'), 'the ones held for the office''s look are never handed to the server to send');

select tbl.check(:'bea600' in (select id from public.autopay_charges where send_state = 'sending'), 'Bea''s first invoice is among them');
select number as bea_no from public.invoices where id = :'bea600_inv' \gset
select public.autopay_sent(:'bea600', true);
select public.autopay_sent(:'bea600', true);
select public.autopay_sent(:'bea600', false, 'Again');
select tbl.check(tbl.to_client(:'bea600', 500, 'sent')
    and tbl.told(:'ora', 'Invoice #' || :'bea_no' || ' %') = 'Invoice #' || :'bea_no' || ' went to Bea Bank to pay | $600.00 is over the $500.00 limit for their bank account, so it wasn''t taken from it. They were sent the invoice to pay themselves.',
  'sent: the office is told once that it went to the client to pay, and why');
select number as dee_no from public.invoices where id = (select invoice_id from public.autopay_charges where id = :'dee600') \gset
select public.autopay_sent(:'dee600', false, 'Add a valid email address for this client first.');
select public.autopay_sent(:'dee600', false, 'Add a valid email address for this client first.');
select tbl.check(tbl.to_client(:'dee600', 500, 'failed') and (select send_error = 'Add a valid email address for this client first' from public.autopay_charges where id = :'dee600')
    and tbl.told(:'ora', '%#' || :'dee_no' || ' %') = 'Send invoice #' || :'dee_no' || ' to Dee Before | $600.00 is over the $500.00 limit for their bank account, so it wasn''t taken from it. It couldn''t be sent to them (Add a valid email address for this client first), so send it from the invoice.'
    and (select status = 'draft' from public.invoices where number = :'dee_no' and company_id = :'co'),
  'not sent: the office is told once that it''s theirs to send, and the invoice waits as a draft');
select tbl.check((select count(*) = 0 from public.claim_autopay_charges(100, :'co')), 'and nothing falls back to charging');
select public.autopay_send_called_off(:'gus600');
select tbl.check((select send_state is null from public.autopay_charges where id = :'gus600') and tbl.told(:'ora', '%Gus%') is null,
  'one the server finds already sent just before sending is let go, and nobody is told');
-- A run that claimed one and never answered.
update public.autopay_charges set send_claimed_at = now() - interval '31 minutes' where id = :'hal520';
select count(*) as fourth from public.claim_autopay_sends(20, :'co') \gset
select tbl.check(:fourth = 0 and tbl.to_client(:'hal520', 500, 'failed')
    and tbl.told(:'ora', 'Send invoice%Hal%') like '%It couldn''t be sent to them (The server stopped while it was sending it, so check whether it went), so send it from the invoice.',
  'a send its server never answered for isn''t sent a second time: the office is asked to look');

\o
\echo 'Who calls what'
\o /dev/null
select tbl.check(not has_function_privilege('authenticated', 'public.claim_autopay_sends(integer, uuid)', 'execute')
    and not has_function_privilege('authenticated', 'public.autopay_sent(uuid, boolean, text)', 'execute')
    and not has_function_privilege('anon', 'public.autopay_send_called_off(uuid)', 'execute')
    and has_function_privilege('service_role', 'public.claim_autopay_sends(integer, uuid)', 'execute')
    and has_function_privilege('service_role', 'public.autopay_sent(uuid, boolean, text)', 'execute')
    and has_function_privilege('service_role', 'public.autopay_send_called_off(uuid)', 'execute'),
  'only the server claims the invoices to send and says how sending went');
select tbl.check(has_function_privilege('authenticated', 'public.approve_autopay_charge(uuid)', 'execute')
    and has_function_privilege('authenticated', 'public.request_manual_charges(uuid, uuid[], numeric[])', 'execute')
    and has_function_privilege('authenticated', 'public.chargeable_invoices(uuid, uuid)', 'execute')
    and not has_function_privilege('authenticated', 'public.autopay_bill(uuid, uuid)', 'execute')
    and not has_function_privilege('authenticated', 'public.autopay_mark_sent(uuid, uuid, integer)', 'execute')
    and not has_function_privilege('authenticated', 'public.claim_autopay_charges(integer, uuid)', 'execute'),
  'and the functions this changed are called by who called them before');

rollback;

select last_value as checks from tbl.checks \gset
\o
\echo 'All autopay bank limit tests passed (':checks' checks).'
