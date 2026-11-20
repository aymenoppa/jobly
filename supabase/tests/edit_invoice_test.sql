-- Database tests for 20261113000440_edit_sent_invoices.sql: edit_invoice changes a sent invoice's
-- lines in place with its payments untouched; the total can't go below what's been paid; status is
-- worked out once from the result; locked lines stay; void, written-off, Stripe-made, charging and
-- clearing invoices are refused; a job's deposit, progress and retainage rules hold; the edit is in
-- the activity log and queued for the books; a preview changes nothing; and only the office with
-- the invoices area may.
-- Run with scripts/test-db.sh (plain Postgres + prelude.sql). Any failed check stops with an error.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema tei;
grant usage on schema tei to authenticated, service_role;
create function tei.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_what; end if;
  raise notice 'ok - %', p_what;
end $$;
-- Expects p_sql to fail with SQLSTATE p_state and a message like p_like.
create function tei.refused(p_sql text, p_state text, p_like text, p_what text) returns void language plpgsql as $$
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
create function tei.as_user(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', case when p_user is null then '' else json_build_object('sub', p_user, 'role', 'authenticated')::text end, true)
$$;
-- A sent invoice with one taxed "Labor" line of p_amount, due p_due days from today, at p_tax.
create function tei.invoice(p_company uuid, p_client uuid, p_amount numeric, p_due integer default 30, p_tax numeric default 0) returns uuid language plpgsql as $$
declare v_invoice uuid;
begin
  insert into public.invoices (company_id, client_id, tax_rate, issued_on, due_on)
  values (p_company, p_client, p_tax, current_date + p_due - 30, current_date + p_due) returning id into v_invoice;
  insert into public.invoice_line_items (company_id, invoice_id, name, quantity, unit, unit_price, sort) values (p_company, v_invoice, 'Labor', 1, 'ea', p_amount, 0);
  update public.invoices set status = 'sent' where id = v_invoice;
  return v_invoice;
end $$;
create function tei.figures(p_invoice uuid) returns text language sql stable as $$
  select total || '/' || amount_paid || '/' || balance_due || '/' || status from public.invoices where id = p_invoice
$$;
-- Its lines in order, as "name qty x price".
create function tei.lines(p_invoice uuid) returns text language sql stable as $$
  select string_agg(name || ' ' || trim_scale(quantity) || ' x ' || unit_price, ', ' order by sort, id) from public.invoice_line_items where invoice_id = p_invoice
$$;
-- The invoice's ordinary lines as edit_invoice takes them, each as it is.
create function tei.as_is(p_invoice uuid) returns jsonb language sql stable security definer as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'description', description, 'quantity', quantity, 'unit', unit, 'unit_price', unit_price, 'taxable', taxable) order by sort, id), '[]')
  from public.invoice_line_items l where invoice_id = p_invoice and not private.invoice_line_locked(l)
$$;
-- Its locked lines, as "how many/their sum/the first one's place".
create function tei.locked(p_invoice uuid) returns text language sql stable security definer as $$
  select count(*) || '/' || coalesce(sum(round(quantity * unit_price, 2)), 0) || '/' || coalesce(min(sort)::text, '-')
  from public.invoice_line_items l where invoice_id = p_invoice and private.invoice_line_locked(l)
$$;
-- The same with its first line's price changed.
create function tei.repriced(p_invoice uuid, p_price numeric) returns jsonb language sql stable as $$
  select jsonb_set(tei.as_is(p_invoice), '{0,unit_price}', to_jsonb(p_price))
$$;
create function tei.payments(p_invoice uuid) returns text language sql stable as $$
  select string_agg(amount || ' ' || method || ' ' || received_at::date || ' ' || coalesce(processor_ref, '-'), ', ' order by received_at, id) from public.payments where invoice_id = p_invoice
$$;
create function tei.queued(p_invoice uuid) returns bigint language sql stable as $$
  select count(*) from public.outbox where topic = 'accounting.invoice' and payload ->> 'invoice_id' = p_invoice::text and done_at is null
$$;
-- The queue's run of it: done, and in the books.
create function tei.synced(p_invoice uuid) returns void language sql as $$
  update public.outbox set done_at = now() where topic = 'accounting.invoice' and payload ->> 'invoice_id' = p_invoice::text and done_at is null;
  insert into public.sync_links (company_id, provider, entity, local_id, external_id)
  select company_id, 'quickbooks', 'invoice', id, 'qbo-' || number from public.invoices where id = p_invoice
  on conflict do nothing;
$$;
grant execute on all functions in schema tei to authenticated, service_role;

\set ella 'd4400000-0000-0000-0000-000000000001'
\set cody 'd4400000-0000-0000-0000-000000000002'
\set rex 'd4400000-0000-0000-0000-000000000003'

-- Ella owns Elm Electric (books in QuickBooks); Cody is on a crew; Rex owns another business.
insert into auth.users (id, email, raw_user_meta_data) values
  (:'ella', 'ella@elm-electric.test', '{"full_name": "Ella Elm"}'),
  (:'cody', 'cody@elm-electric.test', '{"full_name": "Cody Crew"}'),
  (:'rex', 'rex@rival-electric.test', '{"full_name": "Rex Rival"}');

begin;
set local role authenticated;
select tei.as_user(:'ella');
select public.create_company('Elm Electric', 'general') as co \gset
insert into public.memberships (company_id, user_id, role) values (:'co', :'cody', 'field_crew');
insert into public.clients (company_id, display_name) values (:'co', 'Fay Fir') returning id as fay \gset
select tei.invoice(:'co', :'fay', 500) as part \gset
select tei.invoice(:'co', :'fay', 500) as full \gset
select tei.invoice(:'co', :'fay', 500, -10) as late \gset
select tei.invoice(:'co', :'fay', 500) as unpaid \gset
select tei.invoice(:'co', :'fay', 500, 30, 0.1) as taxed \gset
select tei.invoice(:'co', :'fay', 500) as void \gset
select tei.invoice(:'co', :'fay', 500) as lost \gset
select tei.invoice(:'co', :'fay', 500) as imported \gset
select tei.invoice(:'co', :'fay', 500) as clearing \gset
select tei.invoice(:'co', :'fay', 500, -10) as feed \gset
insert into public.payments (company_id, invoice_id, client_id, amount, method, received_at) values (:'co', :'part', :'fay', 300, 'check', now() - interval '3 days');
insert into public.payments (company_id, invoice_id, client_id, amount, method) values (:'co', :'late', :'fay', 500, 'cash');
update public.invoices set status = 'void' where id = :'void';
update public.invoices set status = 'written_off' where id = :'lost';
select tei.as_user(:'rex');
select public.create_company('Rival Electric', 'general') as other \gset
commit;
-- Paid in full through Stripe; one made in Stripe; one with a bank payment on its way.
insert into public.payments (company_id, invoice_id, client_id, amount, method, processor, processor_ref, fee_amount) values (:'co', :'full', :'fay', 500, 'card', 'stripe', 'pi_tei_full', 14.8);
insert into public.stripe_invoices (company_id, invoice_id, stripe_id, origin, status, amount_due) values
  (:'co', :'imported', 'in_tei_imported', 'stripe', 'open', 500), (:'co', :'clearing', 'in_tei_clearing', 'jobly', 'processing', 500);
insert into public.integrations (company_id, provider, status) values (:'co', 'quickbooks', 'connected');
select tei.synced(:'part');
select tei.synced(:'unpaid');
select tei.payments(:'part') as part_payments \gset
select tei.payments(:'full') as full_payments \gset
select updated_at as part_seen from public.invoices where id = :'part' \gset

-- ===== Who may ==================================================================================
begin;
set local role authenticated;
select tei.as_user(:'cody');
select tei.refused(format('select public.edit_invoice(%L, %L::jsonb)', :'part', '[{"name": "Labor", "unit_price": 1}]'), 'P0002', 'Invoice not found', 'someone on a crew can''t edit an invoice');
select tei.as_user(:'rex');
select tei.refused(format('select public.edit_invoice(%L, %L::jsonb)', :'part', '[{"name": "Labor", "unit_price": 1}]'), 'P0002', 'Invoice not found', 'nor can another business');
-- By hand, a sent invoice's lines are still closed, and the refusal names the way in.
select tei.as_user(:'ella');
select tei.refused(format('update public.invoice_line_items set unit_price = 1 where invoice_id = %L', :'part'), '22023', '%Use Edit invoice%', 'a sent invoice''s lines don''t change line by line');
commit;
select tei.check(not has_function_privilege('anon', 'public.edit_invoice(uuid, jsonb, boolean, timestamptz)', 'execute'), 'nobody signed out can call it');

-- ===== A preview changes nothing ================================================================
begin;
set local role authenticated;
select tei.as_user(:'ella');
select public.edit_invoice(:'part', tei.as_is(:'part') || '[{"name": "Extra outlet", "quantity": 2, "unit_price": 75}]'::jsonb, true) as preview \gset
commit;
select tei.check(:'preview'::jsonb @> '{"total": 650, "amount_paid": 300, "balance_due": 350, "status": "partially_paid", "old_total": 500, "changed": 1}',
  'a preview says what the invoice would come to');
select tei.check(tei.figures(:'part') = '500.00/300.00/200.00/partially_paid' and tei.lines(:'part') = 'Labor 1 x 500.00'
  and (select updated_at = :'part_seen' from public.invoices where id = :'part')
  and not exists (select 1 from public.activity where subject_id = :'part' and verb = 'invoice.edited') and tei.queued(:'part') = 0,
  'and leaves the invoice, its lines, the log and the books'' queue exactly as they were');

-- ===== Extra work on a partly paid invoice ======================================================
begin;
set local role authenticated;
select tei.as_user(:'ella');
select public.edit_invoice(:'part', tei.as_is(:'part') || '[{"name": "Extra outlet", "description": "Garage", "quantity": 2, "unit_price": 75}]'::jsonb, false, :'part_seen') as saved \gset
commit;
select tei.check(tei.figures(:'part') = '650.00/300.00/350.00/partially_paid' and tei.lines(:'part') = 'Labor 1 x 500.00, Extra outlet 2 x 75.00',
  'extra work goes on a partly paid invoice: the total and balance go up, the status is worked out as always');
select tei.check(:'saved'::jsonb @> '{"total": 650, "balance_due": 350, "changed": 1}', 'and the answer says what it came to');
select tei.check(tei.payments(:'part') = :'part_payments', 'its payment is exactly as it was: amount, method and date');
select tei.check((select actor_id = :'ella' and summary = format('Invoice #%s for Fay Fir edited: total $650.00, was $500.00', (select number from public.invoices where id = :'part'))
                         and data @> '{"old_total": 500, "new_total": 650, "balance_due": 350, "lines_added": 1, "lines_removed": 0}'
                    from public.activity where subject_id = :'part' and verb = 'invoice.edited'),
  'the edit is in the activity log with who made it and the old and new total');
select tei.check(tei.queued(:'part') = 1, 'and the books'' copy is queued for its update');
select tei.check((select count(*) = 0 from public.activity where subject_id = :'part' and verb in ('invoice.sent', 'invoice.paid', 'invoice.overdue') and created_at > :'part_seen'),
  'nothing is raised as if it had just been sent, paid or gone past due');

-- Someone editing the copy they opened before that change is told, and changes nothing.
begin;
set local role authenticated;
select tei.as_user(:'ella');
select tei.refused(format('select public.edit_invoice(%L, %L::jsonb, false, %L)', :'part', '[{"name": "Labor", "unit_price": 400}]', :'part_seen'), '22023', 'This invoice changed while you were editing it%',
  'an edit of a copy opened before the last change is refused');

-- ===== The total can''t go below what''s been paid ===============================================
select tei.refused(format('select public.edit_invoice(%L, %L::jsonb)', :'part', '[{"name": "Labor", "unit_price": 299.99}]'), '22023',
  'This invoice has $300.00 paid on it, so its total can''t go below that. Refund the difference first.', 'the total can''t go below the $300 paid');
select tei.refused(format('select public.edit_invoice(%L, %L::jsonb, true)', :'part', '[{"name": "Labor", "unit_price": 299.99}]'), '22023',
  'This invoice has $300.00 paid on it%', 'and a preview says so too');
select public.edit_invoice(:'part', tei.repriced(:'part', 150));
commit;
select tei.check(tei.figures(:'part') = '300.00/300.00/0.00/paid' and tei.lines(:'part') = 'Labor 1 x 150.00, Extra outlet 2 x 75.00',
  'brought down to exactly what was paid, it''s paid');
select tei.check((select count(*) = 1 from public.activity where subject_id = :'part' and verb = 'invoice.paid'), 'which is raised once, as any invoice being paid');

-- ===== A fully paid invoice, paid through Stripe ================================================
begin;
set local role authenticated;
select tei.as_user(:'ella');
select tei.refused(format('select public.edit_invoice(%L, %L::jsonb)', :'full', tei.repriced(:'full', 450)), '22023', 'This invoice has $500.00 paid on it%', 'a paid invoice can''t be cut below what was paid');
-- A line renamed and split, coming to the same: nothing about the money moves.
select public.edit_invoice(:'full', jsonb_set(tei.repriced(:'full', 400), '{0,name}', '"Panel swap"') || '[{"name": "Permit", "unit_price": 100, "taxable": false}]'::jsonb);
commit;
select tei.check(tei.figures(:'full') = '500.00/500.00/0.00/paid' and tei.lines(:'full') = 'Panel swap 1 x 400.00, Permit 1 x 100.00', 'a paid invoice''s lines are corrected, and it stays paid');
select tei.check(tei.payments(:'full') = :'full_payments' and (select fee_amount = 14.8 and processor = 'stripe' from public.payments where invoice_id = :'full'),
  'its Stripe payment keeps its link, its date and its fee');
select tei.check((select summary like '%edited (total still $500.00)' from public.activity where subject_id = :'full' and verb = 'invoice.edited'), 'the log says the total didn''t move');
-- Work added to it: owed again, awaiting payment (it isn't due yet).
begin;
set local role authenticated;
select tei.as_user(:'ella');
select public.edit_invoice(:'full', tei.as_is(:'full') || '[{"name": "Surge protector", "unit_price": 120}]'::jsonb);
commit;
select tei.check(tei.figures(:'full') = '620.00/500.00/120.00/partially_paid', 'work added to a paid invoice: it owes the difference');

-- ===== A paid invoice past its due date =========================================================
begin;
set local role authenticated;
select tei.as_user(:'ella');
select public.edit_invoice(:'late', tei.as_is(:'late') || '[{"name": "Second trip", "unit_price": 80}]'::jsonb);
commit;
select tei.check(tei.figures(:'late') = '580.00/500.00/80.00/overdue' and (select owed_again_at is not null and past_due_notice_pending from public.invoices where id = :'late'),
  'work added to a paid invoice past its due date reads past due, with its past-due notice held for a day');
select tei.check((select count(*) = 1 from public.activity where subject_id = :'late' and verb = 'invoice.overdue'), 'so the client isn''t reminded for the office''s own edit');

-- ===== An unpaid one, and what it does to the tax ================================================
begin;
set local role authenticated;
select tei.as_user(:'ella');
select public.edit_invoice(:'unpaid', '[{"name": "Fixture", "quantity": 3, "unit": "ea", "unit_price": 60.5}]');
select public.edit_invoice(:'taxed', tei.as_is(:'taxed') || '[{"name": "Permit", "unit_price": 100, "taxable": false}, {"name": "Wire", "quantity": 2.5, "unit": "ft", "unit_price": 10}]'::jsonb);
commit;
select tei.check(tei.figures(:'unpaid') = '181.50/0.00/181.50/sent' and tei.lines(:'unpaid') = 'Fixture 3 x 60.50', 'the lines given replace an unpaid invoice''s lines');
select tei.check(tei.queued(:'unpaid') = 1, 'and the books get that too');
select tei.check(tei.figures(:'taxed') = '677.50/0.00/677.50/sent' and (select tax_amount = 52.5 and subtotal = 625 from public.invoices where id = :'taxed'),
  'tax is worked out again on the taxable lines');
-- Saved again with nothing different: nothing happens.
select count(*) as edits_before from public.activity where verb = 'invoice.edited' \gset
begin;
set local role authenticated;
select tei.as_user(:'ella');
select tei.check(public.edit_invoice(:'taxed', tei.as_is(:'taxed')) @> '{"changed": 0, "total": 677.5}', 'saved with nothing changed, it says so');
commit;
select tei.check((select count(*) = :edits_before from public.activity where verb = 'invoice.edited'), 'and the log gets no entry');

-- ===== Never seen half changed ===================================================================
-- $300 paid on Labor $300 + Trench $200. Trench is swapped for Conduit $200: taking Trench off first
-- would, for a moment, leave an invoice that's paid in full.
begin;
set local role authenticated;
select tei.as_user(:'ella');
select tei.invoice(:'co', :'fay', 300) as swap \gset
select public.edit_invoice(:'swap', tei.as_is(:'swap') || '[{"name": "Trench", "unit_price": 200}]'::jsonb);
insert into public.payments (company_id, invoice_id, client_id, amount, method) values (:'co', :'swap', :'fay', 300, 'check');
select public.edit_invoice(:'swap', jsonb_build_array(tei.as_is(:'swap') -> 0, '{"name": "Conduit", "unit_price": 200}'::jsonb));
commit;
select tei.check(tei.figures(:'swap') = '500.00/300.00/200.00/partially_paid' and tei.lines(:'swap') = 'Labor 1 x 300.00, Conduit 1 x 200.00', 'a line swapped for another of the same price leaves the invoice owing what it did');
select tei.check(not exists (select 1 from public.activity where subject_id = :'swap' and verb = 'invoice.paid')
  and not exists (select 1 from public.notifications where link = '/invoices/' || :'swap'),
  'and it was never paid in between: nothing was raised, and nobody was told it was');

-- ===== What''s refused outright ==================================================================
begin;
set local role authenticated;
select tei.as_user(:'ella');
select tei.refused(format('select public.edit_invoice(%L, %L::jsonb)', :'void', '[{"name": "Labor", "unit_price": 1}]'), '22023', 'A void invoice stays as it is', 'a void invoice stays locked');
select tei.refused(format('select public.edit_invoice(%L, %L::jsonb)', :'lost', '[{"name": "Labor", "unit_price": 1}]'), '22023', 'Undo the write-off%', 'and a written-off one');
select tei.refused(format('select public.edit_invoice(%L, %L::jsonb)', :'imported', '[{"name": "Labor", "unit_price": 1}]'), '22023', 'This invoice was made in Stripe%', 'one made in Stripe is changed there');
select tei.refused(format('select public.edit_invoice(%L, %L::jsonb)', :'clearing', '[{"name": "Labor", "unit_price": 1}]'), '22023', 'A bank payment for this invoice is on its way%', 'not while a bank payment is on its way');
select tei.refused(format('select public.edit_invoice(%L, %L::jsonb)', :'unpaid', '[]'), '22023', 'An invoice needs at least one line', 'an invoice isn''t left with no lines');
select tei.refused(format('select public.edit_invoice(%L, %L::jsonb)', :'unpaid', '[{"name": "  ", "unit_price": 1}]'), '22023', 'Every line needs a name', 'nor a line with no name');
select tei.refused(format('select public.edit_invoice(%L, %L::jsonb)', :'unpaid', jsonb_build_array(jsonb_build_object('id', (select id from public.invoice_line_items where invoice_id = :'taxed' limit 1), 'name', 'Theirs', 'unit_price', 1))),
  '22023', 'One of those lines isn''t on this invoice%', 'a line of another invoice can''t be named');
commit;
select tei.check(tei.figures(:'void') = '500.00/0.00/500.00/void' and tei.figures(:'lost') = '500.00/0.00/500.00/written_off' and tei.lines(:'imported') = 'Labor 1 x 500.00', 'the ones refused are untouched');

-- ===== Locked lines stay =========================================================================
update public.companies set settings = settings || '{"late_fee": {"type": "flat", "amount": 25, "grace_days": 0}}' where id = :'co';
begin;
set local role service_role;
select public.add_late_fees();
commit;
select id as fee_line from public.invoice_line_items where invoice_id = :'feed' and kind = 'late_fee' \gset
begin;
set local role authenticated;
select tei.as_user(:'ella');
select tei.check(jsonb_array_length(tei.as_is(:'feed')) = 1, 'a late fee isn''t among the lines an edit takes');
select tei.refused(format('select public.edit_invoice(%L, %L::jsonb)', :'feed', jsonb_build_array(jsonb_build_object('id', :'fee_line', 'name', 'Late fee', 'unit_price', 1))),
  '22023', 'One of those lines isn''t on this invoice, or can''t be changed here%', 'the late fee line can''t be changed by an edit');
select public.edit_invoice(:'feed', tei.as_is(:'feed') || '[{"name": "Breaker", "unit_price": 40}, {"name": "Cover plate", "unit_price": 5}]'::jsonb);
commit;
select tei.check(tei.lines(:'feed') = 'Labor 1 x 500.00, Breaker 1 x 40.00, Cover plate 1 x 5.00, Late fee 1 x 25.00' and tei.figures(:'feed') = '570.00/0.00/570.00/overdue',
  'the late fee stays, after the lines the edit put on');

-- ===== A job''s deposit, progress and retainage ==================================================
begin;
set local role authenticated;
select tei.as_user(:'ella');
insert into public.jobs (company_id, client_id, title, billing_mode, retainage_pct) values (:'co', :'fay', 'Rewire', 'progress', 10) returning id as rewire \gset
insert into public.job_line_items (company_id, job_id, name, unit_price, taxable) values (:'co', :'rewire', 'Rewire the house', 10000, false);
select public.create_invoice_for_job(:'rewire', 'deposit', 2000) as deposit \gset
select public.create_invoice_for_job(:'rewire', 'progress', 3000) as progress \gset
update public.invoices set status = 'sent' where id in (:'deposit', :'progress');
insert into public.payments (company_id, invoice_id, client_id, amount, method) values (:'co', :'deposit', :'fay', 1000, 'check');
-- The deposit comes down to what was agreed since, and can't pass what's left on the job.
select public.edit_invoice(:'deposit', tei.repriced(:'deposit', 1500));
select tei.check(tei.figures(:'deposit') = '1500.00/1000.00/500.00/partially_paid', 'a partly paid deposit invoice is changed to the deposit agreed since');
select tei.refused(format('select public.edit_invoice(%L, %L::jsonb)', :'deposit', tei.repriced(:'deposit', 7000.01)), '22023', 'That''s more than what''s left to bill on this job ($7,000.00)',
  'but never past what''s left to bill on the job');
select tei.refused(format('select public.edit_invoice(%L, %L::jsonb)', :'progress', tei.repriced(:'progress', 8500.01)), '22023', 'That''s more than what''s left to bill on this job ($8,500.00)',
  'nor a progress invoice');
-- The final invoice takes them off as they stand, and from then on they're closed.
select public.create_invoice_for_job(:'rewire', 'standard') as final \gset
update public.invoices set status = 'sent' where id = :'final';
select tei.check((select total = 5500 and retainage_amount = 550 from public.invoices where id = :'final'), 'the final invoice takes $1,500 and $3,000 off the $10,000');
select tei.refused(format('select public.edit_invoice(%L, %L::jsonb)', :'deposit', tei.repriced(:'deposit', 1000)), '22023',
  format('Invoice #%s already takes this one off the job''s total. Void that invoice to change this one', (select number from public.invoices where id = :'final')),
  'a deposit the final invoice has taken off stays as it is');
select tei.refused(format('select public.edit_invoice(%L, %L::jsonb)', :'progress', tei.repriced(:'progress', 1000)), '22023', 'Invoice #% already takes this one off%', 'and a progress invoice');
-- The final invoice's own work can change; its credits for the deposit and progress can't.
select tei.check(jsonb_array_length(tei.as_is(:'final')) = 1, 'the final invoice''s credits aren''t among the lines an edit takes');
select public.edit_invoice(:'final', tei.as_is(:'final') || '[{"name": "Extra circuit", "unit_price": 500, "taxable": false}]'::jsonb);
select tei.check((select total = 6000 and retainage_amount = 600 from public.invoices where id = :'final')
  and tei.locked(:'final') = '2/-4500.00/2',
  'extra work goes on the final invoice, its credits stay, after the work, and more is held back');
-- Retainage: what the job's invoices hold back is billed, and neither side can break that.
select public.create_invoice_for_job(:'rewire', 'retainage') as retainage \gset
update public.invoices set status = 'sent' where id = :'retainage';
select tei.check((select total = 900 from public.invoices where id = :'retainage'), 'the retainage invoice bills the $300 and $600 held back');
select tei.refused(format('select public.edit_invoice(%L, %L::jsonb)', :'retainage', tei.repriced(:'retainage', 900.01)), '22023', 'That''s more than the retainage held back on this job ($900.00)',
  'a retainage invoice can''t bill more than is held back');
select tei.refused(format('select public.edit_invoice(%L, %L::jsonb)', :'final', tei.repriced(:'final', 9000)), '22023', 'This job''s retainage invoice bills what this one holds back%',
  'and an invoice it bills the holdback of can''t be cut under it');
select public.edit_invoice(:'retainage', tei.repriced(:'retainage', 800));
select public.edit_invoice(:'final', tei.as_is(:'final') || '[{"name": "Trim", "unit_price": 100, "taxable": false}]'::jsonb);
select tei.check((select total = 800 from public.invoices where id = :'retainage') and (select total = 6100 from public.invoices where id = :'final'),
  'changes that keep the holdback covered go through');
commit;

-- ===== A draft, the same way (an assistant's path) ==============================================
begin;
set local role authenticated;
select tei.as_user(:'ella');
insert into public.invoices (company_id, client_id, tax_rate) values (:'co', :'fay', 0) returning id as draft \gset
insert into public.invoice_line_items (company_id, invoice_id, name, unit_price) values (:'co', :'draft', 'Call out', 90);
select public.edit_invoice(:'draft', tei.repriced(:'draft', 95) || '[{"name": "Bulb", "quantity": 4, "unit_price": 3}]'::jsonb);
commit;
select tei.check(tei.figures(:'draft') = '107.00/0.00/107.00/draft' and not exists (select 1 from public.activity where subject_id = :'draft' and verb = 'invoice.edited'),
  'a draft''s lines can be given the same way, with nothing in the log: it hasn''t been sent');

select tei.check(private.assistant_rpc_area('edit_invoice') = 'invoices' and private.assistant_rpc_area('remove_late_fee') = 'invoices' and private.assistant_rpc_area('merge_clients') = 'invoices',
  'an assistant needs the invoices area for it, and the functions listed before still have theirs');

\echo 'All edit invoice tests passed.'
