-- A payment schedule's dates: none already past when the quote is sent, none carried by a copy, and
-- "so many days after they approve" as a choice.
--
-- A payment "on a date" kept whatever day was typed. Nothing checked it against today, and copies
-- and templates carried it, so a quote made from last year's template, or approved late, had that
-- payment invoiced the hour its job existed.
--
--   Days after approval   A dated payment can say {"due": "date", "after": 30} in place of a day:
--                         30 days after the client approves. It has no day until then; approving
--                         works it out, from today where the company is, and keeps it with the
--                         approval ("on"), so the job's payment has its date as any dated one does.
--                         1 to 365 days.
--   Sending               A quote can't go to the client (status sent, however it gets there) while
--                         a dated payment has no day or a day already gone: "Payment 2 is due on
--                         Mar 1, 2026, which has already passed. Give it a new date." The server asks
--                         first (quote_send_problem), so nothing is emailed for a quote that can't
--                         be marked sent.
--   Copies, templates     duplicate_quote takes the day off each dated payment: it has to be set
--                         again on the copy before that's sent. Days after approval carry as they are.
--   Approving             A payment whose day was never set can't be signed. A day that has passed
--                         since the quote was sent is what the client saw: it's due at once.
--
-- An app from before this shows a payment due some days after approval as "On a date" until it's
-- signed, and can't change that schedule without giving it a day. core money.ts (scheduleProblem,
-- scheduleDateProblem, scheduleDueText) says the same as these. supabase/tests/payment_schedule_test.sql covers it.

-- As in 20261113001100_payment_schedules.sql, with days after approval, and a dated payment whose
-- day isn't set yet is a shape that can be saved.
create or replace function private.schedule_shape_problem(p_rows jsonb) returns text
language plpgsql immutable set search_path = '' as $$
declare
  r record;
  v_n integer;
  v_value numeric;
  v_which text;
begin
  if p_rows is null then
    return null;
  end if;
  if jsonb_typeof(p_rows) <> 'array' then
    return 'A payment schedule is a list of payments.';
  end if;
  v_n := jsonb_array_length(p_rows);
  if v_n > 12 then
    return 'A payment schedule has 12 payments at most.';
  end if;
  for r in select e.value as row, e.ordinality as i from jsonb_array_elements(p_rows) with ordinality e loop
    v_which := 'Payment ' || r.i;
    if jsonb_typeof(r.row) <> 'object' then
      return v_which || ' needs an amount.';
    end if;
    if coalesce(r.row ->> 'due', '') not in ('approval', 'date', 'work_starts', 'work_done', 'by_hand') then
      return v_which || ' needs to say when it''s due.';
    end if;
    if r.row ->> 'due' = 'date' then
      if r.row -> 'after' is not null and jsonb_typeof(r.row -> 'after') <> 'null' then
        -- So many days after the quote is approved: the day is worked out then.
        if jsonb_typeof(r.row -> 'after') <> 'number' or (r.row ->> 'after')::numeric <> trunc((r.row ->> 'after')::numeric)
           or not ((r.row ->> 'after')::numeric between 1 and 365) then
          return v_which || ' needs a number of days, 1 to 365.';
        end if;
      elsif coalesce(r.row ->> 'on', '') <> '' then
        if r.row ->> 'on' !~ '^\d{4}-\d{2}-\d{2}$' then
          return v_which || ' needs its date.';
        end if;
        begin
          perform (r.row ->> 'on')::date;
        exception when others then
          return v_which || ' needs its date.';
        end;
      end if;
      -- Neither: a date still to be set (a copy's, a template's). private.schedule_date_problem
      -- says so before the quote is sent or approved.
    end if;
    if r.row ->> 'kind' = 'rest' and r.i <> v_n then
      return 'Only the last payment can be the rest.';
    end if;
    if coalesce(r.row ->> 'kind', '') not in ('percent', 'amount', 'rest') then
      return v_which || ' needs an amount.';
    end if;
    if r.row ->> 'kind' in ('percent', 'amount') then
      if jsonb_typeof(r.row -> 'value') is distinct from 'number' then
        return case r.row ->> 'kind' when 'percent' then v_which || ' needs a percent above 0, up to 100.' else v_which || ' needs an amount.' end;
      end if;
      v_value := (r.row ->> 'value')::numeric;
      if r.row ->> 'kind' = 'percent' and not (v_value > 0 and v_value <= 100) then
        return v_which || ' needs a percent above 0, up to 100.';
      end if;
      if r.row ->> 'kind' = 'amount' and not (v_value > 0 and v_value <= 100000000) then
        return v_which || ' needs an amount.';
      end if;
    end if;
  end loop;
  if (select count(*) from jsonb_array_elements(p_rows) e where e.value ->> 'due' = 'approval') > 1 then
    return 'Only one payment can be due when the quote is approved.';
  end if;
  if (select count(*) from jsonb_array_elements(p_rows) e where e.value ->> 'due' = 'work_done') > 1 then
    return 'Only one payment can be due when the work is done.';
  end if;
  return null;
end $$;

/**
 * Why a schedule can't go to the client as it is, or null: a dated payment with no day, or (given
 * p_today, the day where the company is) with a day already gone. Days after approval are fine.
 */
create function private.schedule_date_problem(p_rows jsonb, p_today date) returns text
language sql stable set search_path = '' as $$
  select case when coalesce(e.value ->> 'on', '') = '' then 'Payment ' || e.i || ' needs its date.'
              else 'Payment ' || e.i || ' is due on ' || to_char((e.value ->> 'on')::date, 'Mon FMDD, YYYY') || ', which has already passed. Give it a new date.' end
    from jsonb_array_elements(case when jsonb_typeof(p_rows) = 'array' then p_rows else '[]'::jsonb end) with ordinality e (value, i)
   where e.value ->> 'due' = 'date'
     and (e.value -> 'after' is null or jsonb_typeof(e.value -> 'after') = 'null')
     and (coalesce(e.value ->> 'on', '') = '' or (p_today is not null and (e.value ->> 'on')::date < p_today))
   order by e.i limit 1
$$;

-- A schedule for a copy or a template: the same payments, each dated one without its day.
create function private.schedule_for_copy(p_rows jsonb) returns jsonb
language sql immutable set search_path = '' as $$
  select case when jsonb_typeof(p_rows) <> 'array' then p_rows
              else (select jsonb_agg(case when e.value ->> 'due' = 'date' then e.value - 'on' else e.value end order by e.i)
                      from jsonb_array_elements(p_rows) with ordinality e (value, i)) end
$$;

revoke all on function private.schedule_date_problem(jsonb, date), private.schedule_for_copy(jsonb) from public;
grant execute on function private.schedule_date_problem(jsonb, date), private.schedule_for_copy(jsonb) to authenticated, service_role;

/** Why a quote can't be sent as it is, in words for whoever is sending it, or null. The server asks before it emails anything. */
create function public.quote_send_problem(p_quote uuid) returns text
language sql stable security invoker set search_path = '' as $$
  select private.schedule_date_problem(q.payment_schedule, private.company_today(q.company_id))
    from public.quotes q where q.id = p_quote and q.payment_schedule is not null and q.status not in ('approved', 'converted')
$$;
revoke execute on function public.quote_send_problem(uuid) from public, anon;
grant execute on function public.quote_send_problem(uuid) to authenticated, service_role;

-- As in 20261113001100_payment_schedules.sql, plus the dates: see the top of this file.
create or replace function private.quote_payment_schedule() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_problem text;
  v_first jsonb;
  v_amounts jsonb;
  v_today date;
begin
  if jsonb_typeof(new.payment_schedule) = 'array' and jsonb_array_length(new.payment_schedule) = 0 then
    new.payment_schedule := null;
  end if;
  if tg_op = 'INSERT' or new.payment_schedule is distinct from old.payment_schedule then
    if tg_op = 'UPDATE' and old.status in ('approved', 'converted') then
      raise exception 'This quote was approved, so its payment schedule stays as it was signed.' using errcode = '22023';
    end if;
    if new.payment_schedule is not null then
      v_problem := private.schedule_shape_problem(new.payment_schedule);
      if v_problem is not null then
        raise exception '%', v_problem using errcode = '22023';
      end if;
      if new.change_order_for is not null then
        raise exception 'A change order is billed with its job, so it has no payment schedule of its own.' using errcode = '22023';
      end if;
      if new.recurrence_rule is not null then
        raise exception 'Repeating work is billed by the visit or the month, so it has no payment schedule.' using errcode = '22023';
      end if;
      -- A new quote has no lines yet (a copy gets its lines after): its total is checked once it's edited.
      if tg_op = 'UPDATE' then
        v_problem := private.schedule_problem(new.payment_schedule, new.total);
        if v_problem is not null then
          raise exception '%', v_problem using errcode = '22023';
        end if;
      end if;
    end if;
  end if;
  if new.payment_schedule is not null and (new.recurrence_rule is not null or new.change_order_for is not null) then
    raise exception 'A quote with a payment schedule is for one-time work. Take the schedule off first.' using errcode = '22023';
  end if;

  -- Going to the client (sent, or sent again after changes, or its schedule changed while it's with
  -- them): every dated payment has its date, and none is a day already gone.
  if new.payment_schedule is not null and new.status = 'sent' and not new.is_template
     and (tg_op = 'INSERT' or old.status is distinct from 'sent' or new.payment_schedule is distinct from old.payment_schedule) then
    v_problem := private.schedule_date_problem(new.payment_schedule, private.company_today(new.company_id));
    if v_problem is not null then
      raise exception '%', v_problem using errcode = '22023';
    end if;
  end if;

  if new.payment_schedule is not null then
    v_amounts := private.schedule_amounts(new.payment_schedule, new.total);
    -- The deposit is the payment due at approval: as a percent when it's one, so it follows the
    -- total as the client picks options; none without one.
    select e.value into v_first from jsonb_array_elements(v_amounts) e where e.value ->> 'due' = 'approval' limit 1;
    if v_first is null then
      new.deposit_amount := 0;
      new.deposit_percent := null;
    else
      new.deposit_amount := (v_first ->> 'amount')::numeric;
      new.deposit_percent := case when v_first ->> 'kind' = 'percent' and jsonb_array_length(v_amounts) > 1 then round((v_first ->> 'value')::numeric, 2) end;
    end if;
    -- Approved (by any path, any server): each payment's amount for the total signed is kept.
    -- A payment due so many days after approval gets its day now, counted from today where the
    -- company is; one whose date was never set can't be signed. (A date that has passed since the
    -- quote was sent stays as the client saw it: it's due at once.)
    if tg_op = 'UPDATE' and new.status in ('approved', 'converted') and old.status not in ('approved', 'converted') then
      v_today := private.company_today(new.company_id);
      v_problem := private.schedule_date_problem(new.payment_schedule, null);
      if v_problem is not null then
        raise exception '%', v_problem using errcode = '22023';
      end if;
      select jsonb_agg(case when e.value ->> 'due' = 'date' and jsonb_typeof(e.value -> 'after') = 'number'
                            then e.value || jsonb_build_object('on', (v_today + (e.value ->> 'after')::integer)::text) else e.value end order by e.i)
        into v_amounts from jsonb_array_elements(v_amounts) with ordinality e (value, i);
      new.approval := coalesce(new.approval, '{}') || jsonb_build_object('payment_schedule', v_amounts);
    end if;
  end if;
  return new;
end $$;

-- As in 20261113001100_payment_schedules.sql, and the copy's dated payments have their days to set.
create or replace function public.duplicate_quote(p_quote uuid, p_template_name text default null, p_client uuid default null,
  p_property uuid default null, p_title text default null, p_custom_fields jsonb default null)
returns uuid language plpgsql security invoker set search_path = '' as $$
declare
  q public.quotes;
  o public.quote_options;
  v_template boolean;
  v_new uuid;
  v_id uuid;
  v_map jsonb := '{}';
begin
  select * into q from public.quotes where id = p_quote;
  if not found then
    raise exception 'Quote not found' using errcode = 'P0002';
  end if;
  if p_template_name is not null and p_client is not null then
    raise exception 'A quote template has no client.' using errcode = '22023';
  end if;
  if p_template_name is not null and btrim(p_template_name) = '' then
    raise exception 'Give the template a name.' using errcode = '22023';
  end if;
  v_template := p_template_name is not null or (q.is_template and p_client is null);

  insert into public.quotes (company_id, client_id, property_id, is_template, title, message, discount_amount, tax_rate, deposit_amount, deposit_percent,
                             valid_until, roof_package_id, section_ids, recurrence_rule, active_months, starts_on, ends_on, custom_fields,
                             every_job_items_left_off, payment_schedule)
  select q.company_id,
         case when not v_template then coalesce(p_client, q.client_id) end,
         case when v_template then null when p_client is not null then p_property else q.property_id end,
         v_template,
         left(coalesce(nullif(btrim(p_template_name), ''), nullif(btrim(p_title), ''),
                       case when q.is_template and not v_template then q.title else q.title || ' (copy)' end), 200),
         q.message, q.discount_amount, q.tax_rate, q.deposit_amount, q.deposit_percent,
         case when v_template then null
              when q.is_template then (now() at time zone coalesce(c.timezone, 'UTC'))::date
                                      + coalesce((c.settings ->> 'quote_valid_days')::numeric::integer, 30)
              when q.valid_until > (now() at time zone coalesce(c.timezone, 'UTC'))::date then q.valid_until end,
         q.roof_package_id, q.section_ids, q.recurrence_rule, q.active_months, q.starts_on, q.ends_on,
         case when p_client is not null and p_custom_fields is not null then p_custom_fields
              when v_template or q.is_template then q.custom_fields else '{}' end,
         case when q.is_template then q.every_job_items_left_off else '{}' end,
         private.schedule_for_copy(q.payment_schedule)
    from public.companies c where c.id = q.company_id
  returning id into v_new;

  for o in select * from public.quote_options where quote_id = p_quote order by sort, id loop
    insert into public.quote_options (company_id, quote_id, package_id, name, tier, picture, picture_width, picture_height,
                                      style, highlights, warranty, section_ids, sort)
    values (o.company_id, v_new, o.package_id, o.name, o.tier, o.picture, o.picture_width, o.picture_height,
            o.style, o.highlights, o.warranty, o.section_ids, o.sort)
    returning id into v_id;
    v_map := v_map || jsonb_build_object(o.id::text, v_id);
  end loop;
  if q.option_id is not null then
    update public.quotes set option_id = (v_map ->> q.option_id::text)::uuid
     where id = v_new and option_id is distinct from (v_map ->> q.option_id::text)::uuid;
  end if;

  insert into public.quote_line_items (company_id, quote_id, option_id, service_id, name, description, quantity, unit, unit_price,
                                       unit_cost, taxable, optional, selected, option_group, formula, sort, materials, material_cost)
  select l.company_id, v_new, (v_map ->> l.option_id::text)::uuid, l.service_id, l.name, l.description, l.quantity, l.unit, l.unit_price,
         l.unit_cost, l.taxable, l.optional, not l.optional, l.option_group, l.formula, l.sort, l.materials, l.material_cost
    from public.quote_line_items l where l.quote_id = p_quote
   order by l.sort;
  return v_new;
end $$;

notify pgrst, 'reload schema';
