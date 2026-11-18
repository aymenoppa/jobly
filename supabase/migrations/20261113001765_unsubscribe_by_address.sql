-- An unsubscribe is the email address's, not one client record's. A person with two client records
-- under one address (a duplicate, or a home and a rental kept apart) who unsubscribed from one was
-- picked by the next campaign through the other: the audience takes one record for each address
-- among those not opted out. The FTC's CAN-SPAM guide: "You must honor a recipient's opt-out
-- request within 10 business days."
--
--   * Turning marketing off (or back on) for a client does the same for every client record of
--     the company with that address, whoever does it: the unsubscribe link, the office's switch,
--     an assistant.
--   * A campaign's audience also leaves out an address that any record of the company has opted
--     out, so a record added or given that address later is covered too.
--
-- supabase/tests/unsubscribe_by_address_test.sql covers it.

-- Finding the opted-out records for an address without reading every client.
create index clients_opted_out_email_idx on public.clients (company_id, private.email_key(email)) where marketing_opt_out and email is not null;

-- The other records with the same address follow. They change only when they differ, so this
-- settles after one pass.
create function private.marketing_opt_out_by_address() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if private.email_key(new.email) is not null then
    update public.clients c
       set marketing_opt_out = new.marketing_opt_out
     where c.company_id = new.company_id and c.id <> new.id and c.email is not null
       and private.email_key(c.email) = private.email_key(new.email)
       and c.marketing_opt_out is distinct from new.marketing_opt_out;
  end if;
  return null;
end $$;
revoke all on function private.marketing_opt_out_by_address() from public;
create trigger marketing_opt_out_by_address after update of marketing_opt_out on public.clients
  for each row when (new.marketing_opt_out is distinct from old.marketing_opt_out)
  execute function private.marketing_opt_out_by_address();

-- The records that are out of step today: an address one record opted out is opted out on all.
update public.clients c
   set marketing_opt_out = true
 where not c.marketing_opt_out and c.email is not null
   and exists (select 1 from public.clients o
                where o.company_id = c.company_id and o.marketing_opt_out and o.email is not null
                  and private.email_key(o.email) = private.email_key(c.email));

-- As in 20261031000210_campaign_audiences.sql, and an address is left out when any of the
-- company's records with it has opted out.
create or replace function public.campaign_audience(p_company_id uuid, p_audience jsonb)
returns table (client_id uuid, display_name text, email text)
language sql stable security invoker set search_path = '' as $$
  select distinct on (lower(trim(c.email))) c.id, c.display_name, lower(trim(c.email))
  from public.clients c
  where c.company_id = p_company_id
    and c.email is not null
    and trim(c.email) ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'
    and not c.marketing_opt_out
    and not exists (select 1 from public.clients o
                     where o.company_id = c.company_id and o.marketing_opt_out and o.email is not null
                       and private.email_key(o.email) = private.email_key(c.email))
    and (coalesce(jsonb_array_length(p_audience -> 'statuses'), 0) = 0
         or c.status in (select jsonb_array_elements_text(p_audience -> 'statuses')))
    and (coalesce(jsonb_array_length(p_audience -> 'tags_any'), 0) = 0
         or c.tags && array(select jsonb_array_elements_text(p_audience -> 'tags_any')))
    and not (c.tags && array(select jsonb_array_elements_text(coalesce(p_audience -> 'tags_none', '[]'))))
    and (coalesce((p_audience ->> 'no_visit_days')::integer, 0) <= 0 or not exists (
         select 1 from public.visits v join public.jobs j on j.id = v.job_id
         where j.client_id = c.id and v.status = 'completed'
           and v.completed_at > now() - make_interval(days => (p_audience ->> 'no_visit_days')::integer)))
    and (coalesce(jsonb_array_length(p_audience -> 'cities'), 0) = 0
         or exists (select 1 from public.properties p
                     where p.client_id = c.id
                       and lower(trim(p.city)) in (select lower(trim(x)) from jsonb_array_elements_text(p_audience -> 'cities') x))
         or lower(trim(c.billing_address ->> 'city')) in (select lower(trim(x)) from jsonb_array_elements_text(p_audience -> 'cities') x))
    and (coalesce(jsonb_array_length(p_audience -> 'services'), 0) = 0 or exists (
         select 1 from public.job_line_items l
           join public.jobs j on j.id = l.job_id
           left join public.services s on s.id = l.service_id
          where j.client_id = c.id
            and (j.status in ('requires_invoicing', 'completed')
                 or exists (select 1 from public.visits v where v.job_id = j.id and v.status = 'completed'))
            and lower(trim(coalesce(s.name, l.name))) in (select lower(trim(x)) from jsonb_array_elements_text(p_audience -> 'services') x)))
    and (coalesce(p_audience ->> 'recurring', '') not in ('yes', 'no')
         or (p_audience ->> 'recurring' = 'yes') = exists (
              select 1 from public.jobs j where j.client_id = c.id and j.kind = 'recurring' and j.status = 'active'))
    and (p_audience -> 'recurring_ending' is distinct from 'true'::jsonb or exists (
         select 1 from public.jobs j
          where j.client_id = c.id and j.kind = 'recurring' and j.status = 'active'
            and j.ends_on between private.company_today(p_company_id) and private.company_today(p_company_id) + 30))
  order by lower(trim(c.email)), c.created_at
$$;

notify pgrst, 'reload schema';
