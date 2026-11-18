-- Postcards: one card per household. Two client records at one address (a couple entered twice, a
-- landlord and a tenant) each got a card until now, and each is charged for.
--
-- public.postcard_audience now leaves out, as 'same_address', every client after the first whose
-- card would go to an address another client's card already goes to: the same street line and unit
-- and the same five-digit ZIP, whatever the capitals. The card goes to the client who has been on
-- the books longest (created first), so who gets it doesn't change from one day to the next. The
-- row still says the address, so the list shows which one they share.
--
-- start_postcard_campaign takes its recipients from postcard_audience where left_out is null, so a
-- campaign mails what the page counted. postcard_audience_summary counts the new reason.
-- supabase/tests/postcard_fixes_test.sql covers it.

-- From 20261113001400_postcards.sql, with the household rule.
create or replace function public.postcard_audience(p_company uuid, p_audience jsonb)
returns table (client_id uuid, display_name text, address jsonb, left_out text)
language sql stable security invoker set search_path = '' as $$
  with found as (
    select c.id, c.display_name, c.created_at,
           case when m.a ? 'problem' then null else m.a end as address,
           case
             when c.status = 'archived' then 'archived'
             when c.marketing_opt_out then 'opted_out'
             else m.a ->> 'problem'
           end as left_out
      from public.clients c
      cross join lateral (select private.mailing_address(c) as a) m
     where c.company_id = p_company
       and private.in_segment(p_company, c, coalesce(p_audience, '{}'::jsonb))
  ), placed as (
    -- Among those who'd get a card, each one's place at their address: the longest-standing client first.
    select f.*,
           case when f.left_out is null then row_number() over (
             partition by (f.left_out is null), lower(f.address ->> 'line1'), lower(coalesce(f.address ->> 'line2', '')), left(f.address ->> 'postal_code', 5)
             order by f.created_at, f.id) end as place
      from found f
  )
  select p.id, p.display_name, p.address, case when p.place > 1 then 'same_address' else p.left_out end
    from placed p
   order by p.display_name, p.id
$$;

-- From 20261113001550_postcard_addresses.sql, counting clients left out for sharing an address.
create or replace function public.postcard_audience_summary(p_company uuid, p_audience jsonb) returns jsonb
language sql stable security invoker set search_path = '' as $$
  with a as (select * from public.postcard_audience(p_company, p_audience))
  select jsonb_build_object(
    'count', (select count(*) from a where left_out is null),
    'left_out', jsonb_build_object(
      'archived', (select count(*) from a where left_out = 'archived'),
      'opted_out', (select count(*) from a where left_out = 'opted_out'),
      'no_address', (select count(*) from a where left_out = 'no_address'),
      'outside_us', (select count(*) from a where left_out = 'outside_us'),
      'bad_state', (select count(*) from a where left_out = 'bad_state'),
      'too_long', (select count(*) from a where left_out = 'too_long'),
      'same_address', (select count(*) from a where left_out = 'same_address')),
    'sample', coalesce((select jsonb_agg(jsonb_build_object('client_id', s.client_id, 'name', s.display_name, 'city', s.address ->> 'city', 'region', s.address ->> 'region'))
                          from (select * from a where left_out is null limit 5) s), '[]'::jsonb))
$$;

notify pgrst, 'reload schema';
