-- Autopay from a bank account: the terms say what the client agrees to about notice.
--
-- A client can save a bank account for autopay where the business takes them, and each charge is
-- for the work done, so its amount varies. For a preauthorized transfer that varies, Regulation E
-- (12 CFR 1005.10(d)) has the payee send "written notice of the amount and date of the transfer at
-- least 10 days before the scheduled date of transfer" ((d)(1)), and lets it "give the consumer the
-- option of receiving notice only when a transfer falls outside a specified range of amounts" once
-- it has told them of "the right to receive notice of all varying transfers" ((d)(2)). The terms
-- said "the card on file" and nothing about either.
--
-- Now:
--   - The starter words say "the card or bank account on file" (core starterAutopayTerms has the
--     same). A business with autopay on has saved words of its own, which stay as they are.
--   - What every client agrees to ends with a paragraph for bank accounts (autopay_bank_text; core
--     autopayBankText has the same words): the right to notice of every charge, and the range they
--     choose instead, which is the business's own "most to charge without asking". A charge over
--     that already waits for the office's OK; the paragraph promises its amount and date 10 days
--     ahead, which the office is reminded of where it gives that OK. With no limit set there is no
--     range to name, and the paragraph says so plainly (Settings → Payments tells the business).
--   - The words changed, so the version does: a company still on the starter version goes to
--     starter-<trade>-2, one with a saved version gets "+bank" on the end of it, and changing the
--     limit from here on makes a new version as changing the words or the timing does. A client
--     part way through agreeing is asked to read the terms again rather than being recorded as
--     agreeing to words they didn't see. Nobody who already agreed is asked again: their agreement
--     keeps the words and the version it was made with.
--
-- supabase/tests/autopay_bank_terms_test.sql covers it.

-- As in 20261104000900_monthly_plan_autopay.sql, with "card or bank account".
create or replace function private.autopay_starter_terms(p_trade text) returns text
language sql immutable security definer set search_path = '' as $$
  select case
    when p_trade = 'lawn_exterior' then
      'We charge the card or bank account on file after each visit is done, or once a month for a monthly plan, and for other invoices we send you. You''ll get a receipt each time. Turn it off anytime from your client page or by calling us.'
    when p_trade = 'cleaning' then
      'We charge the card or bank account on file after each cleaning, or once a month for a monthly plan, and for other invoices we send you. You''ll get a receipt each time. Turn it off anytime from your client page or by calling us.'
    when p_trade = 'pool_service' then
      'We charge the card or bank account on file after each pool service visit, or once a month for a monthly plan, and for other invoices we send you. You''ll get a receipt each time. Turn it off anytime from your client page or by calling us.'
    when p_trade = 'pest_control' then
      'We charge the card or bank account on file after each treatment, or once a month for a monthly plan, and for other invoices we send you. You''ll get a receipt each time. Turn it off anytime from your client page or by calling us.'
    when p_trade in ('paving', 'roofing_exteriors') then
      'We charge the card or bank account on file when the work on your job is done, and for other invoices we send you. Charges over the amount we agreed wait until we''ve talked with you. You''ll get a receipt each time. Turn it off anytime from your client page or by calling us.'
    else
      'We charge the card or bank account on file when each visit or job is done, or once a month for a monthly plan, and for other invoices we send you. You''ll get a receipt each time. Turn it off anytime from your client page or by calling us.'
  end
$$;

-- The most charged without asking, as core autopaySettings reads it: the number saved, no limit
-- (null) only when that was saved, and the starter $500 for anything else.
create function private.autopay_cap(p_autopay jsonb) returns numeric
language sql immutable security definer set search_path = '' as $$
  select case
    when p_autopay ? 'max_amount' and p_autopay -> 'max_amount' = 'null'::jsonb then null
    when jsonb_typeof(p_autopay -> 'max_amount') = 'number' and (p_autopay -> 'max_amount')::numeric > 0 and (p_autopay -> 'max_amount')::numeric <= 1000000
      then (p_autopay -> 'max_amount')::numeric
    else 500
  end
$$;

-- What a client paying from a bank account agrees to about notice (core autopayBankText's words,
-- exactly): the right 12 CFR 1005.10(d)(2) has them told of, and the range they choose instead.
create function private.autopay_bank_text(p_autopay jsonb) returns text
language sql immutable security definer set search_path = '' as $$
  select 'If you pay from a bank account: you have the right to be told the amount and date of each charge at least 10 days before it''s made. '
    || case when private.autopay_cap(p_autopay) is null
      then 'By agreeing, you choose not to be told ahead: each charge is for the invoice it pays, whatever its amount.'
      else 'By agreeing, you choose to be told ahead only when a charge is more than ' || private.money(private.autopay_cap(p_autopay))
        || ', and we''ll send you its amount and date at least 10 days before we make it. Charges of ' || private.money(private.autopay_cap(p_autopay))
        || ' or less are made without notice ahead of time.'
    end
$$;
revoke all on function private.autopay_cap(jsonb), private.autopay_bank_text(jsonb) from public;

-- As in 20261101000100_autopay.sql, then the bank account paragraph.
create or replace function private.autopay_terms_shown(p_company uuid) returns text
language sql stable security definer set search_path = '' as $$
  select coalesce(case when jsonb_typeof(a -> 'terms') = 'string' then nullif(btrim(a ->> 'terms'), '') end, private.autopay_starter_terms(c.trade_preset))
    || E'\n\n' || 'We charge ' || private.autopay_timing_text(a) || '.'
    || E'\n\n' || private.autopay_bank_text(a)
  from public.companies c cross join lateral (select private.autopay_of(c.settings) as a) x
  where c.id = p_company
$$;

-- As in 20261101000100_autopay.sql: the starter words changed, so their version did.
create or replace function private.autopay_terms_version(p_company uuid) returns text
language sql stable security definer set search_path = '' as $$
  select coalesce(nullif(private.autopay_of(c.settings) ->> 'terms_version', ''), 'starter-' || coalesce(nullif(c.trade_preset, ''), 'general') || '-2')
  from public.companies c where c.id = p_company
$$;

-- As in 20261101000100_autopay.sql, plus: a new limit is a new version, now that it's in the words.
create or replace function public.autopay_set_settings(p_company uuid, p_settings jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_old jsonb;
  v_terms text;
  v_timing text := p_settings ->> 'timing';
  v_days integer;
  v_max numeric;
  v_version text;
  v_saved jsonb;
begin
  if not (private.has_role(p_company, '{owner,admin}') and private.has_perm(p_company, 'invoices')) then
    raise exception 'Only owners and admins with the invoices area can change autopay' using errcode = '42501';
  end if;
  if jsonb_typeof(p_settings -> 'enabled') is distinct from 'boolean' then
    raise exception 'Say whether autopay is on' using errcode = '22023';
  end if;
  if jsonb_typeof(p_settings -> 'terms') is distinct from 'string' or length(btrim(p_settings ->> 'terms')) not between 1 and 4000 then
    raise exception 'Write the terms clients agree to' using errcode = '22023';
  end if;
  v_terms := btrim(p_settings ->> 'terms');
  if v_timing is null or v_timing not in ('now', 'end_of_day', 'days') then
    raise exception 'Choose when to charge' using errcode = '22023';
  end if;
  if v_timing = 'days' then
    if jsonb_typeof(p_settings -> 'days') is distinct from 'number'
       or (p_settings -> 'days')::numeric not between 1 and 14 or (p_settings -> 'days')::numeric <> trunc((p_settings -> 'days')::numeric) then
      raise exception 'Choose 1 to 14 days' using errcode = '22023';
    end if;
    v_days := (p_settings -> 'days')::numeric::integer;
  end if;
  if p_settings -> 'max_amount' is not null and p_settings -> 'max_amount' <> 'null'::jsonb then
    if jsonb_typeof(p_settings -> 'max_amount') <> 'number'
       or (p_settings -> 'max_amount')::numeric <= 0 or (p_settings -> 'max_amount')::numeric > 1000000 then
      raise exception 'The most to charge without asking has to be more than $0' using errcode = '22023';
    end if;
    v_max := round((p_settings -> 'max_amount')::numeric, 2);
  end if;
  if jsonb_typeof(p_settings -> 'receipts') is distinct from 'boolean' then
    raise exception 'Say whether to email receipts' using errcode = '22023';
  end if;
  if jsonb_typeof(p_settings -> 'jobs_default') is distinct from 'boolean' then
    raise exception 'Say whether new recurring jobs start on autopay' using errcode = '22023';
  end if;
  if jsonb_typeof(p_settings -> 'card_required') is distinct from 'boolean' then
    raise exception 'Say whether every client needs a card on file' using errcode = '22023';
  end if;
  -- The key's saved capability (apps/api/src/integrations/stripe.ts stripeCapabilities): a company
  -- calling this straight through the API gets the same answer as PUT /autopay/settings.
  if p_settings -> 'enabled' = 'true'::jsonb and not exists (
    select 1 from public.integrations i
    where i.company_id = p_company and i.provider = 'stripe' and i.status = 'connected' and i.settings -> 'autopay' = 'true'::jsonb
  ) then
    raise exception 'Update your Stripe key on the Apps page to turn on autopay' using errcode = '22023';
  end if;

  select private.autopay_of(c.settings) into v_old from public.companies c where c.id = p_company for update;
  v_version := case
    when nullif(v_old ->> 'terms_version', '') is null
      or v_old -> 'terms' is distinct from to_jsonb(v_terms)
      or v_old -> 'timing' is distinct from to_jsonb(v_timing)
      or coalesce(v_old -> 'days', 'null'::jsonb) is distinct from coalesce(to_jsonb(v_days), 'null'::jsonb)
      -- The most charged without asking is in the words now (what a bank account agrees to).
      or private.autopay_cap(v_old) is distinct from v_max
    then to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS')
    else v_old ->> 'terms_version'
  end;

  perform set_config('jobly.autopay', 'on', true);
  update public.companies c
  set settings = jsonb_set(coalesce(c.settings, '{}'), '{autopay}', jsonb_build_object(
    'enabled', p_settings -> 'enabled',
    'terms', v_terms,
    'terms_version', v_version,
    'timing', v_timing,
    'days', v_days,
    'max_amount', v_max,
    'receipts', p_settings -> 'receipts',
    'jobs_default', p_settings -> 'jobs_default',
    'card_required', p_settings -> 'card_required',
    'changed_at', now(),
    'changed_by', (select auth.uid())))
  where c.id = p_company
  returning c.settings -> 'autopay' into v_saved;
  perform set_config('jobly.autopay', 'off', true);
  return v_saved;
end $$;

-- A version saved before this is for words without the bank account paragraph.
do $$
begin
  perform set_config('jobly.autopay', 'on', true);
  update public.companies c
  set settings = jsonb_set(c.settings, '{autopay,terms_version}', to_jsonb(left(c.settings -> 'autopay' ->> 'terms_version', 35) || '+bank'))
  where jsonb_typeof(c.settings -> 'autopay' -> 'terms_version') = 'string'
    and nullif(c.settings -> 'autopay' ->> 'terms_version', '') is not null
    and c.settings -> 'autopay' ->> 'terms_version' not like '%+bank';
  perform set_config('jobly.autopay', 'off', true);
end $$;

notify pgrst, 'reload schema';
