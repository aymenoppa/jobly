-- Owners and admins can see and set the next request, quote, job and invoice number.
--
-- Numbers come from number_sequences, which starts every company at 1 and which nobody can write
-- (20261016000100_foundation.sql). A business moving from another system at invoice #4310 started
-- again at #1. Settings → Company now shows the next number of each kind and lets it be set, through
-- these two functions, not by opening the table:
--
--   next_numbers(company)                   the next number of each kind, and the highest in use
--   set_next_number(company, kind, next)    sets it, to anything above the highest number in use
--
-- A next number at or below one already used is refused, saying which: two documents can't share
-- a number (unique (company_id, number)), so the next one made would fail. Above that it can go up
-- or come back down (a mistyped 43100 put right). Owners and admins only, checked here. An AI
-- assistant can't: its requests may only write through the functions listed in
-- private.assistant_rpc_area.
--
-- supabase/tests/next_numbers_test.sql covers it.

-- The table a kind of document is numbered in, as number_sequences names it; null for anything else.
create function private.numbered_table(p_kind text) returns text
language sql immutable set search_path = '' as $$
  select case p_kind when 'request' then 'requests' when 'quote' then 'quotes' when 'job' then 'jobs' when 'invoice' then 'invoices' end
$$;

-- The highest number a company has used for a kind (0 when it has none). Quote templates have no number.
create function private.highest_number(p_company uuid, p_table text) returns bigint
language sql stable security definer set search_path = '' as $$
  select coalesce(case p_table
    when 'requests' then (select max(number) from public.requests where company_id = p_company)
    when 'quotes' then (select max(number) from public.quotes where company_id = p_company)
    when 'jobs' then (select max(number) from public.jobs where company_id = p_company)
    when 'invoices' then (select max(number) from public.invoices where company_id = p_company)
  end, 0)
$$;

create function public.next_numbers(p_company uuid) returns table (kind text, next_number bigint, highest_used bigint)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.has_role(p_company, '{owner,admin}') then
    raise exception 'Only owners and admins can see and set the next numbers' using errcode = '42501';
  end if;
  return query
    select k.kind, coalesce(s.next_value, 1), private.highest_number(p_company, private.numbered_table(k.kind))
    from (values ('request', 1), ('quote', 2), ('job', 3), ('invoice', 4)) k (kind, sort)
    left join public.number_sequences s on s.company_id = p_company and s.kind = private.numbered_table(k.kind)
    order by k.sort;
end $$;

create function public.set_next_number(p_company uuid, p_kind text, p_next bigint) returns bigint
language plpgsql security definer set search_path = '' as $$
declare
  v_table text := private.numbered_table(p_kind);
  v_highest bigint;
begin
  if not private.has_role(p_company, '{owner,admin}') then
    raise exception 'Only owners and admins can see and set the next numbers' using errcode = '42501';
  end if;
  if v_table is null then
    raise exception 'Numbers are set for requests, quotes, jobs and invoices' using errcode = '22023';
  end if;
  if p_next is null or p_next < 1 or p_next > 999999999 then
    raise exception 'Enter a whole number from 1 to 999,999,999' using errcode = '22023';
  end if;
  -- The sequence's row is locked first (made, for a company that hasn't numbered one yet), as
  -- next_number locks it: a document being made right now is counted before the check, and none is
  -- numbered between the check and the change.
  insert into public.number_sequences as s (company_id, kind, next_value) values (p_company, v_table, 1)
  on conflict (company_id, kind) do update set next_value = s.next_value;
  v_highest := private.highest_number(p_company, v_table);
  if p_next <= v_highest then
    raise exception '% #% is already used, so the next number has to be % or higher. Two %s can''t share a number.',
      initcap(p_kind), v_highest, v_highest + 1, p_kind using errcode = '22023';
  end if;
  update public.number_sequences set next_value = p_next where company_id = p_company and kind = v_table;
  return p_next;
end $$;

revoke all on function private.numbered_table(text), private.highest_number(uuid, text) from public;
revoke execute on function public.next_numbers(uuid), public.set_next_number(uuid, text, bigint) from public, anon;
grant execute on function public.next_numbers(uuid), public.set_next_number(uuid, text, bigint) to authenticated;

notify pgrst, 'reload schema';
