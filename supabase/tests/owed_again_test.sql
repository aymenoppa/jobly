-- Database tests for 20261113000430_owed_again_without_chasing.sql: a paid invoice that's owed
-- again past its due date (a payment removed, a refund) reads past due at once but raises no
-- past-due event that day; the hourly run raises it from the next day, once; its late fee's grace
-- days count from the day it was owed again; taken off the invoice (written off) or paid again
-- first, nothing is raised; and an invoice going past its due date in the ordinary way is as before.
-- Run with scripts/test-db.sh (plain Postgres + prelude.sql). Any failed check stops with an error.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema toa;
grant usage on schema toa to authenticated, service_role;
create function toa.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_what; end if;
  raise notice 'ok - %', p_what;
end $$;
create function toa.as_user(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', case when p_user is null then '' else json_build_object('sub', p_user, 'role', 'authenticated')::text end, true)
$$;
-- A sent $200 invoice due p_due days from today (negative: that many days ago).
create function toa.invoice(p_company uuid, p_client uuid, p_due integer) returns uuid language plpgsql as $$
declare v_invoice uuid;
begin
  insert into public.invoices (company_id, client_id, tax_rate, issued_on, due_on)
  values (p_company, p_client, 0, current_date + p_due - 30, current_date + p_due) returning id into v_invoice;
  insert into public.invoice_line_items (company_id, invoice_id, name, quantity, unit, unit_price) values (p_company, v_invoice, 'Cleanup', 1, 'ea', 200);
  update public.invoices set status = 'sent' where id = v_invoice;
  return v_invoice;
end $$;
-- Pays it by check, and gives back the payment's id.
create function toa.pay(p_invoice uuid, p_amount numeric) returns uuid language sql as $$
  insert into public.payments (company_id, invoice_id, client_id, amount, method)
  select company_id, id, client_id, p_amount, 'check' from public.invoices where id = p_invoice returning id
$$;
create function toa.state(p_invoice uuid) returns text language sql stable as $$
  select status || '/' || balance_due || case when owed_again_at is not null then '/owed again' else '' end || case when past_due_notice_pending then '/notice pending' else '' end
  from public.invoices where id = p_invoice
$$;
-- How many times its past-due event has been raised.
create function toa.raised(p_invoice uuid) returns bigint language sql stable as $$
  select count(*) from public.activity where subject_id = p_invoice and verb = 'invoice.overdue'
$$;
-- As a night would: the day it was owed again moves back, without the triggers.
create function toa.days_pass(p_invoice uuid, p_days integer) returns void language plpgsql as $$
begin
  set session_replication_role = replica;
  update public.invoices set owed_again_at = owed_again_at - make_interval(days => p_days) where id = p_invoice;
  set session_replication_role = default;
end $$;
create function toa.fees(p_invoice uuid) returns bigint language sql stable as $$
  select count(*) from public.invoice_line_items where invoice_id = p_invoice and kind = 'late_fee'
$$;
grant execute on all functions in schema toa to authenticated, service_role;

\set olga 'd4300000-0000-0000-0000-000000000001'

-- Olga owns Oak Outdoors: a $25 late fee two days after the due date. Pia is her client.
insert into auth.users (id, email, raw_user_meta_data) values (:'olga', 'olga@oak-outdoors.test', '{"full_name": "Olga Oak"}');

begin;
set local role authenticated;
select toa.as_user(:'olga');
select public.create_company('Oak Outdoors', 'general', 'America/Chicago') as co \gset
insert into public.clients (company_id, display_name) values (:'co', 'Pia Pine') returning id as pia \gset
select toa.invoice(:'co', :'pia', -10) as removed \gset
select toa.invoice(:'co', :'pia', -10) as refunded \gset
select toa.invoice(:'co', :'pia', -10) as taken_off \gset
select toa.invoice(:'co', :'pia', -10) as repaid \gset
select toa.invoice(:'co', :'pia', -10) as part \gset
select toa.invoice(:'co', :'pia', -10) as online \gset
select toa.invoice(:'co', :'pia', 10) as not_due \gset
select toa.invoice(:'co', :'pia', 10) as ordinary \gset
select toa.pay(:'removed', 200) as removed_payment \gset
select toa.pay(:'refunded', 200) as refunded_payment \gset
select toa.pay(:'taken_off', 200) as taken_off_payment \gset
select toa.pay(:'repaid', 200) as repaid_payment \gset
select toa.pay(:'part', 80) as part_payment \gset
select toa.pay(:'not_due', 200) as not_due_payment \gset
commit;
insert into public.payments (company_id, invoice_id, client_id, amount, method, processor, processor_ref) values (:'co', :'online', :'pia', 200, 'card', 'stripe', 'pi_toa_online');
update public.companies set settings = settings || '{"late_fee": {"type": "flat", "amount": 25, "grace_days": 2}}' where id = :'co';

select toa.check(toa.state(:'removed') = 'paid/0.00' and toa.raised(:'removed') = 1, 'to start: paid in full, after going past due once in the ordinary way');
select toa.raised(:'removed') + toa.raised(:'refunded') + toa.raised(:'taken_off') + toa.raised(:'repaid') + toa.raised(:'part') + toa.raised(:'online') + toa.raised(:'not_due') as before \gset

-- ===== The office's own action puts the balance back ===========================================
begin;
set local role authenticated;
select toa.as_user(:'olga');
-- A mis-keyed payment removed.
delete from public.payments where id = :'removed_payment';
-- A refund recorded, and one recorded and taken off the invoice (written off), as the dialog does.
insert into public.payments (company_id, invoice_id, client_id, amount, method, notes) values (:'co', :'refunded', :'pia', -200, 'check', 'Refund');
insert into public.payments (company_id, invoice_id, client_id, amount, method, notes) values (:'co', :'taken_off', :'pia', -200, 'check', 'Refund');
update public.invoices set status = 'written_off' where id = :'taken_off';
-- Removed, then recorded again the same day.
delete from public.payments where id = :'repaid_payment';
select toa.pay(:'repaid', 200);
-- One that was only partly paid was past due already; one not due yet isn't past due.
delete from public.payments where id = :'part_payment';
delete from public.payments where id = :'not_due_payment';
commit;
-- Stripe refunds one in full (the server books it).
insert into public.payments (company_id, invoice_id, client_id, amount, method, processor, processor_ref, notes)
values (:'co', :'online', :'pia', -200, 'card', 'stripe', 'pi_toa_online:refund:20000', 'Refunded in Stripe');

select toa.check(toa.state(:'removed') = 'overdue/200.00/owed again/notice pending', 'a payment removed from a paid invoice past its due date: it reads past due at once');
select toa.check(toa.state(:'refunded') = 'overdue/200.00/owed again/notice pending', 'a refund recorded on one: the same');
select toa.check(toa.state(:'online') = 'overdue/200.00/owed again/notice pending', 'a refund through Stripe: the same');
select toa.check(toa.state(:'taken_off') = 'written_off/200.00/owed again', 'a refund taken off the invoice leaves it written off, with no notice waiting');
select toa.check(toa.state(:'repaid') = 'paid/0.00/owed again', 'one paid again has no notice waiting');
select toa.check(toa.state(:'part') = 'overdue/200.00', 'a partly paid invoice already past due just owes more: nothing new to say');
select toa.check(toa.state(:'not_due') = 'sent/200.00', 'one not due yet goes back to awaiting payment');
select toa.check(toa.raised(:'removed') + toa.raised(:'refunded') + toa.raised(:'taken_off') + toa.raised(:'repaid') + toa.raised(:'part') + toa.raised(:'online') + toa.raised(:'not_due') = :before,
  'and none of it raises a past-due event, so no reminder goes to the client for the office''s own change');

-- ===== That day's hourly runs ===================================================================
begin;
set local role service_role;
select public.mark_overdue_invoices() as marked \gset
select public.raise_past_due_notices() as today \gset
select public.add_late_fees() as fees_today \gset
commit;
select toa.check(:'today'::integer = 0 and toa.raised(:'removed') = 1, 'the hourly run raises nothing the same day');
select toa.check(toa.fees(:'removed') = 0 and toa.fees(:'refunded') = 0 and toa.fees(:'online') = 0,
  'and adds no late fee: the grace days count from today, not from the old due date');
select toa.check(toa.fees(:'part') = 1, 'the invoice that was past due all along gets its late fee as before');

-- ===== The next day =============================================================================
select toa.days_pass(:'removed', 1);
select toa.days_pass(:'refunded', 1);
select toa.days_pass(:'online', 1);
select toa.days_pass(:'taken_off', 1);
select toa.days_pass(:'repaid', 1);
begin;
set local role service_role;
select public.raise_past_due_notices() as tomorrow \gset
select public.raise_past_due_notices() as tomorrow_again \gset
select public.add_late_fees() as fees_tomorrow \gset
commit;
select toa.check(:'tomorrow'::integer = 3 and :'tomorrow_again'::integer = 0, 'the next day the hourly run raises the three still owed, once');
select toa.check(toa.raised(:'removed') = 2 and toa.raised(:'refunded') = 2 and toa.raised(:'online') = 2, 'each gets its past-due event, so reminders carry on from then');
select toa.check((select summary = format('Invoice #%s for Pia Pine is past due ($200.00 owing)', (select number from public.invoices where id = :'removed'))
                         and data @> '{"total": 200, "balance_due": 200, "autopay": false}' and actor_id is null
                    from public.activity where subject_id = :'removed' and verb = 'invoice.overdue' order by created_at desc limit 1),
  'worded and filled in as an invoice going past due always is');
select toa.check(toa.state(:'removed') = 'overdue/200.00/owed again', 'and no notice is left waiting');
select toa.check(toa.raised(:'taken_off') = 1 and toa.raised(:'repaid') = 1, 'nothing is raised for the one taken off the invoice, or the one paid again');
select toa.check(toa.fees(:'removed') = 0, 'still inside the grace days: no late fee yet');

-- ===== Past the grace days ======================================================================
select toa.days_pass(:'removed', 2);
select toa.days_pass(:'refunded', 2);
begin;
set local role service_role;
select public.add_late_fees() as fees_later \gset
commit;
select toa.check(toa.fees(:'removed') = 1 and toa.fees(:'refunded') = 1 and toa.fees(:'online') = 0,
  'once the grace days have passed since it was owed again, the late fee goes on');

-- ===== Undoing the write-off, as before =========================================================
begin;
set local role authenticated;
select toa.as_user(:'olga');
update public.invoices set status = 'sent' where id = :'taken_off';
commit;
select toa.check(toa.state(:'taken_off') = 'overdue/200.00/owed again' and toa.raised(:'taken_off') = 1, 'a write-off undone is past due again without a past-due event, as before');

-- ===== An invoice going past its due date in the ordinary way ====================================
set session_replication_role = replica;
-- (Four days back by the server's date: at least three where the business is.)
update public.invoices set issued_on = issued_on - 20, due_on = due_on - 14 where id = :'ordinary';
set session_replication_role = default;
begin;
set local role service_role;
select public.mark_overdue_invoices() as marked_later \gset
select public.raise_past_due_notices() as none \gset
select public.add_late_fees() as ordinary_fee \gset
commit;
select toa.check(toa.state(:'ordinary') = 'overdue/225.00' and toa.raised(:'ordinary') = 1 and :'none'::integer = 0,
  'an invoice that goes past its due date raises its event at once and gets its late fee after the grace days, as before');

-- ===== Only the database sets them ==============================================================
begin;
set local role authenticated;
select toa.as_user(:'olga');
update public.invoices set owed_again_at = now() + interval '30 days', past_due_notice_pending = true where id in (:'ordinary', :'removed');
commit;
select toa.check(toa.state(:'ordinary') = 'overdue/225.00' and (select owed_again_at < now() from public.invoices where id = :'removed') and toa.state(:'removed') = 'overdue/225.00/owed again',
  'someone signed in can''t push the late fee back or queue a notice by writing the columns');
insert into public.invoices (company_id, client_id, owed_again_at, past_due_notice_pending) values (:'co', :'pia', now(), true) returning id as made \gset
select toa.check((select owed_again_at is null and not past_due_notice_pending from public.invoices where id = :'made'), 'nor does a new invoice start with them set');

select toa.check(not has_function_privilege('authenticated', 'public.raise_past_due_notices()', 'execute') and not has_function_privilege('anon', 'public.raise_past_due_notices()', 'execute'),
  'only the server runs the hourly notices');

\echo 'All owed again tests passed.'
