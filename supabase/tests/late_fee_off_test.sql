-- Database tests for 20261113000420_late_fee_off_for_an_invoice.sql: Remove late fee takes the fee
-- line off a sent invoice (partly paid or not) and keeps the hourly run from putting it back; "No
-- late fee on this invoice" keeps one from ever going on; a fee that's been paid can't be removed
-- without a refund; and only the office with the invoices area does either.
-- Run with scripts/test-db.sh (plain Postgres + prelude.sql). Any failed check stops with an error.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema tlf;
grant usage on schema tlf to authenticated, service_role;
create function tlf.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_what; end if;
  raise notice 'ok - %', p_what;
end $$;
-- Expects p_sql to fail with SQLSTATE p_state and a message like p_like.
create function tlf.refused(p_sql text, p_state text, p_like text, p_what text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlstate <> p_state or sqlerrm not ilike p_like then
      raise exception 'FAIL (wrong error % "%"): %', sqlstate, sqlerrm, p_what;
    end if;
    raise notice 'ok - % (%)', p_what, sqlerrm;
    return;
  end;
  raise exception 'FAIL (expected an error): %', p_what;
end $$;
create function tlf.as_user(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', case when p_user is null then '' else json_build_object('sub', p_user, 'role', 'authenticated')::text end, true)
$$;
-- A sent $200 invoice, due p_days_late days ago.
create function tlf.invoice(p_company uuid, p_client uuid, p_days_late integer) returns uuid language plpgsql as $$
declare v_invoice uuid;
begin
  insert into public.invoices (company_id, client_id, tax_rate, issued_on, due_on)
  values (p_company, p_client, 0, current_date - p_days_late - 30, current_date - p_days_late) returning id into v_invoice;
  insert into public.invoice_line_items (company_id, invoice_id, name, quantity, unit, unit_price) values (p_company, v_invoice, 'Cleanup', 1, 'ea', 200);
  update public.invoices set status = 'sent' where id = v_invoice;
  return v_invoice;
end $$;
create function tlf.figures(p_invoice uuid) returns text language sql stable as $$
  select total || '/' || amount_paid || '/' || balance_due || '/' || status || case when no_late_fee then '/off' else '' end from public.invoices where id = p_invoice
$$;
create function tlf.fees(p_invoice uuid) returns bigint language sql stable as $$
  select count(*) from public.invoice_line_items where invoice_id = p_invoice and kind = 'late_fee'
$$;
grant execute on all functions in schema tlf to authenticated, service_role;

\set lena 'd4200000-0000-0000-0000-000000000001'
\set finn 'd4200000-0000-0000-0000-000000000002'
\set rita 'd4200000-0000-0000-0000-000000000003'

-- Lena owns Larch Lawns ($25 late fee, no grace days); Finn is on a crew; Rita owns another business.
insert into auth.users (id, email, raw_user_meta_data) values
  (:'lena', 'lena@larch-lawns.test', '{"full_name": "Lena Larch"}'),
  (:'finn', 'finn@larch-lawns.test', '{"full_name": "Finn Field"}'),
  (:'rita', 'rita@rival-lawns.test', '{"full_name": "Rita Rival"}');

begin;
set local role authenticated;
select tlf.as_user(:'lena');
select public.create_company('Larch Lawns', 'general') as co \gset
insert into public.memberships (company_id, user_id, role) values (:'co', :'finn', 'field_crew');
insert into public.clients (company_id, display_name) values (:'co', 'Gus Grove') returning id as gus \gset
select tlf.invoice(:'co', :'gus', 10) as late \gset
select tlf.invoice(:'co', :'gus', 10) as part \gset
select tlf.invoice(:'co', :'gus', 10) as settled \gset
select tlf.invoice(:'co', :'gus', 10) as spared \gset
select tlf.invoice(:'co', :'gus', 10) as clearing \gset
select tlf.invoice(:'co', :'gus', 10) as lost \gset
select tlf.invoice(:'co', :'gus', 10) as plain \gset
insert into public.payments (company_id, invoice_id, client_id, amount, method) values (:'co', :'part', :'gus', 80, 'check');
select tlf.as_user(:'rita');
select public.create_company('Rival Lawns', 'general') as other \gset
commit;
update public.companies set settings = settings || '{"late_fee": {"type": "flat", "amount": 25, "grace_days": 0}}' where id = :'co';

-- ===== "No late fee on this invoice", before one goes on =======================================
begin;
set local role authenticated;
select tlf.as_user(:'lena');
update public.invoices set no_late_fee = true where id = :'spared';
commit;

begin;
set local role service_role;
select public.add_late_fees() as added \gset
commit;
select tlf.check(:'added'::integer = 6, 'the hourly run puts a late fee on each of the six invoices past due');
select tlf.check(tlf.fees(:'spared') = 0 and tlf.figures(:'spared') = '200.00/0.00/200.00/overdue/off' and (select late_fee_at is null from public.invoices where id = :'spared'),
  'but none on the one ticked "No late fee on this invoice"');
select tlf.check(tlf.figures(:'late') = '225.00/0.00/225.00/overdue' and tlf.figures(:'part') = '225.00/80.00/145.00/overdue', 'the others owe $25 more');

-- ===== Remove late fee ==========================================================================
-- Gus pays the settled one in full, fee and all; a bank payment is on its way for another; one is written off.
insert into public.payments (company_id, invoice_id, client_id, amount, method, processor, processor_ref) values (:'co', :'settled', :'gus', 225, 'card', 'stripe', 'pi_tlf_settled');
insert into public.stripe_invoices (company_id, invoice_id, stripe_id, origin, status, amount_due, livemode) values (:'co', :'clearing', 'in_tlf_clearing', 'jobly', 'processing', 225, true);
update public.invoices set status = 'written_off' where id = :'lost';

begin;
set local role authenticated;
select tlf.as_user(:'finn');
select tlf.refused(format('select public.remove_late_fee(%L)', :'late'), 'P0002', 'Invoice not found', 'someone on a crew can''t take a late fee off');
select tlf.as_user(:'rita');
select tlf.refused(format('select public.remove_late_fee(%L)', :'late'), 'P0002', 'Invoice not found', 'nor can another business');
select tlf.as_user(:'lena');
select tlf.check(public.remove_late_fee(:'late') = 25, 'the owner takes the $25 late fee off an unpaid invoice');
select tlf.check(public.remove_late_fee(:'part') = 25, 'and off a partly paid one');
select tlf.refused(format('select public.remove_late_fee(%L)', :'settled'), '22023', 'This invoice has $225.00 paid on it, so its total can''t go below that. Refund the difference first.',
  'a fee that''s been paid stays until the difference is refunded');
select tlf.refused(format('select public.remove_late_fee(%L)', :'clearing'), '22023', 'A bank payment for this invoice is on its way%', 'not while a bank payment for the amount with the fee is on its way');
select tlf.refused(format('select public.remove_late_fee(%L)', :'lost'), '22023', 'Undo the write-off%', 'nor on a written-off invoice');
select tlf.check(public.remove_late_fee(:'spared') = 0, 'on an invoice with no fee there''s nothing to take off');
commit;
select tlf.check(tlf.fees(:'late') = 0 and tlf.figures(:'late') = '200.00/0.00/200.00/overdue/off', 'the line is gone, the total is back to $200, and late fees are off for it');
select tlf.check(tlf.fees(:'part') = 0 and tlf.figures(:'part') = '200.00/80.00/120.00/overdue/off', 'the partly paid one keeps its payment and owes $25 less');
select tlf.check(tlf.fees(:'settled') = 1 and tlf.figures(:'settled') = '225.00/225.00/0.00/paid', 'the paid one is as it was');
select tlf.check(tlf.fees(:'clearing') = 1 and tlf.fees(:'lost') = 1, 'and so are the ones refused');
select tlf.check((select count(*) = 2 and bool_and(actor_id = :'lena') from public.activity where company_id = :'co' and verb = 'invoice.late_fee_removed')
  and exists (select 1 from public.activity where subject_id = :'late' and verb = 'invoice.late_fee_removed'
              and summary = format('$25.00 late fee taken off invoice #%s for Gus Grove', (select number from public.invoices where id = :'late'))),
  'each removal is in the activity log, with who did it');

-- The hourly run leaves them alone, whatever the late_fee_at mark says.
set session_replication_role = replica;
update public.invoices set late_fee_at = null where id in (:'late', :'part');
set session_replication_role = default;
begin;
set local role service_role;
select public.add_late_fees() as again \gset
commit;
select tlf.check(:'again'::integer = 0 and tlf.fees(:'late') = 0 and tlf.fees(:'part') = 0, 'the next hourly run doesn''t put a removed fee back');

-- Turned back on by the office, an invoice that never had one gets its fee on the next run.
begin;
set local role authenticated;
select tlf.as_user(:'lena');
update public.invoices set no_late_fee = false where id = :'spared';
commit;
begin;
set local role service_role;
select public.add_late_fees() as third \gset
commit;
select tlf.check(:'third'::integer = 1 and tlf.fees(:'spared') = 1, 'unticked again, the invoice gets its late fee like any other');

-- A crew member can't tick the box either (the invoices rules).
begin;
set local role authenticated;
select tlf.as_user(:'finn');
update public.invoices set no_late_fee = true where id = :'plain';
commit;
select tlf.check((select not no_late_fee from public.invoices where id = :'plain'), 'someone on a crew can''t turn late fees off for an invoice');

select tlf.check(not has_function_privilege('anon', 'public.remove_late_fee(uuid)', 'execute'), 'nobody signed out can call it');
select tlf.check(private.assistant_rpc_area('remove_late_fee') = 'invoices' and private.assistant_rpc_area('create_invoice_for_job') = 'invoices' and private.assistant_rpc_area('merge_clients') = 'invoices',
  'an assistant needs the invoices area for it, and the functions listed before still have theirs');

\echo 'All late fee off tests passed.'
