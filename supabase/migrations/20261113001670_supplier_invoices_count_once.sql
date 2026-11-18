-- A supplier invoice whose lines are logged as a job's materials counts once in the job's costs.
--
-- An expense is either "already in the job's line item costs" (in_line_costs) or it isn't, all of
-- it. But a supplier's invoice is often both: 44 tons of asphalt the estimate covers, logged as
-- materials used (so they count through the job's lines), and a $150 delivery the estimate never
-- had. Saved as one expense it either counted the asphalt twice or dropped the delivery.
--
--   The rule       What's logged against the job's own estimate counts through the job's line
--                  items; everything else on the invoice counts as an expense. Once each.
--   How it's kept  save_read_expense takes how much of the amount is in the line items
--                  (p_expense.in_line_amount). All of it, or none: one expense, as before. Part of
--                  it: two expenses with the same receipt, one for that part (in_line_costs, not
--                  counted again) and one for the rest (counted), which together come to the
--                  receipt's amount. Every screen, report, assistant and older app that costs a job
--                  reads in_line_costs, so every one of them gets it right with nothing changed.
--
-- And two columns so the same receipt entered twice can be noticed before it's saved (the Add
-- expense form looks for the same invoice number, or the same vendor, day and total):
--
--   expenses.invoice_number   the supplier's invoice number, as read from it.
--   expenses.receipt_total    what the whole receipt came to, on each of the two expenses one
--                             receipt became; null on an expense that is its receipt's whole amount.
--
-- supabase/tests/receipt_reading_test.sql covers it.

alter table public.expenses
  add column invoice_number text check (length(invoice_number) <= 60),
  add column receipt_total numeric(12, 2) check (receipt_total >= 0);
comment on column public.expenses.invoice_number is 'The supplier''s invoice number, as read from it. Used to notice the same receipt entered twice.';
comment on column public.expenses.receipt_total is 'What the whole receipt came to, when this expense is one of the two it was saved as (the part in the job''s line items, and the rest). Null otherwise.';
create index expenses_invoice_number_idx on public.expenses (company_id, lower(invoice_number)) where invoice_number is not null;

/**
 * As in 20261113001210_receipt_reading.sql, plus p_expense.in_line_amount: how much of the amount
 * is already in the job's line item costs. More than nothing and less than all of it saves two
 * expenses (see the top of this file) and returns the one that counts. invoice_number is kept.
 */
create or replace function public.save_read_expense(p_expense jsonb, p_materials jsonb default '[]', p_draft uuid default null) returns uuid
language plpgsql set search_path = '' as $$
declare
  e public.expenses := jsonb_populate_record(null::public.expenses, p_expense);
  v_in_lines numeric := round((p_expense ->> 'in_line_amount')::numeric, 2);
  v_id uuid;
  v_count integer;
begin
  if jsonb_typeof(coalesce(p_materials, '[]')) <> 'array' then
    raise exception 'Materials are a list.' using errcode = '22023';
  end if;
  if v_in_lines is not null and (v_in_lines < 0 or v_in_lines > e.amount) then
    raise exception 'What''s already in the line items is between nothing and the whole amount.' using errcode = '22023';
  end if;
  if v_in_lines is not null and e.job_id is null and v_in_lines > 0 then
    raise exception 'Pick the job whose line items it''s in.' using errcode = '22023';
  end if;
  e.invoice_number := left(nullif(btrim(e.invoice_number), ''), 60);
  if v_in_lines is not null and v_in_lines > 0 and v_in_lines < e.amount then
    -- The part the job's lines already count: kept, with the receipt, and not counted again.
    insert into public.expenses (company_id, job_id, vendor, description, category, amount, tax_amount, incurred_on, receipt_path, reimbursable, in_line_costs, line_items,
                                 invoice_number, receipt_total)
    values (e.company_id, e.job_id, e.vendor, left(concat_ws(' · ', nullif(btrim(e.description), ''), 'materials logged on the job'), 300), e.category, v_in_lines, null,
            coalesce(e.incurred_on, current_date), e.receipt_path, coalesce(e.reimbursable, false), true, e.line_items, e.invoice_number, e.amount);
    -- The rest: what the job's lines don't have, which counts.
    insert into public.expenses (company_id, job_id, vendor, description, category, amount, tax_amount, incurred_on, receipt_path, reimbursable, in_line_costs, line_items,
                                 invoice_number, receipt_total)
    values (e.company_id, e.job_id, e.vendor, left(concat_ws(' · ', nullif(btrim(e.description), ''), 'the rest of the invoice'), 300), e.category, e.amount - v_in_lines,
            least(e.tax_amount, e.amount - v_in_lines), coalesce(e.incurred_on, current_date), e.receipt_path, coalesce(e.reimbursable, false), false, null,
            e.invoice_number, e.amount)
    returning id into v_id;
  else
    insert into public.expenses (company_id, job_id, vendor, description, category, amount, tax_amount, incurred_on, receipt_path, reimbursable, in_line_costs, line_items,
                                 invoice_number)
    values (e.company_id, e.job_id, e.vendor, e.description, e.category, e.amount, e.tax_amount, coalesce(e.incurred_on, current_date), e.receipt_path,
            coalesce(e.reimbursable, false),
            case when v_in_lines is null then coalesce(e.in_line_costs, false) else v_in_lines > 0 end, e.line_items, e.invoice_number)
    returning id into v_id;
  end if;
  if jsonb_array_length(coalesce(p_materials, '[]')) > 0 then
    if e.job_id is null then
      raise exception 'Pick the job to log the materials on.' using errcode = '22023';
    end if;
    insert into public.job_materials (company_id, job_id, service_id, name, quantity, unit, supplier, ticket, notes)
    select e.company_id, e.job_id, m.service_id, left(trim(m.name), 200), m.quantity, left(coalesce(nullif(trim(m.unit), ''), 'ea'), 20),
           left(nullif(trim(e.vendor), ''), 120), left(nullif(trim(m.ticket), ''), 60), 'From a supplier invoice'
    from jsonb_to_recordset(p_materials) as m(service_id uuid, name text, unit text, quantity numeric, ticket text);
  end if;
  if p_draft is not null then
    delete from public.expense_drafts d where d.id = p_draft and d.company_id = e.company_id;
    get diagnostics v_count = row_count;
    if v_count = 0 then
      raise exception 'This draft is gone: someone may have saved or discarded it already.' using errcode = 'P0002';
    end if;
  end if;
  return v_id;
end $$;
revoke execute on function public.save_read_expense(jsonb, jsonb, uuid) from public, anon;
grant execute on function public.save_read_expense(jsonb, jsonb, uuid) to authenticated;

notify pgrst, 'reload schema';
