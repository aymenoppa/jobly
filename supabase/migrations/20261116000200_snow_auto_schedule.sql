-- Snow: storms that schedule themselves, for a business that turns it on (Snow → Storm).
--
-- settings.snow_auto_schedule: with it on, the snow task (snowWatch, apps/api/src/tasks.ts)
-- schedules a customer's storm as it tells the customer's people, through public.snow_schedule_auto:
-- the same visits the office's Schedule button makes (public.snow_schedule), never doubled. It only
-- ever schedules what it's telling people about, so a visit the office cancelled isn't made again
-- an hour later. Off until someone who schedules the whole team turns it on
-- (public.set_snow_auto_schedule). It's a setting of its own, beside the standard storm prices, and
-- not under snow_app: that key is the Apps area's to change (company_settings_area_guard), and
-- the people who schedule needn't have it.

-- What both schedule with: public.snow_schedule's own body (20261113000100_snow_app.sql) as it was,
-- without its check of who's asking, which each of the two below does for itself.
create function private.snow_schedule_visits(p_company uuid, p_date date, p_plan jsonb) returns integer
language plpgsql security definer set search_path = '' as $$
declare
  p record; s public.snow_sites; j public.jobs;
  v_has integer; v_pushes integer; v_visit uuid; v_made integer := 0; v_first boolean;
begin
  if p_date is null or p_date < private.company_today(p_company) then
    raise exception 'Pick today or a later day.' using errcode = '22023';
  end if;
  if jsonb_typeof(p_plan) is distinct from 'array' or jsonb_array_length(p_plan) > 1000 then
    raise exception 'Say which snow customers to schedule.' using errcode = '22023';
  end if;
  for p in
    select (x ->> 'job_id')::uuid as job_id, (x ->> 'inches')::numeric as inches,
           least(12, greatest(1, coalesce((x ->> 'pushes')::integer, 1))) as pushes,
           case when x ->> 'kind' = 'salt' then 'salt' else 'plow' end as kind
      from jsonb_array_elements(p_plan) x
  loop
    select * into s from public.snow_sites where job_id = p.job_id and company_id = p_company;
    continue when not found;
    select * into j from public.jobs where id = p.job_id and company_id = p_company and status = 'active';
    continue when not found;
    v_first := not exists (select 1 from public.snow_visits where job_id = p.job_id and snow_date = p_date);
    insert into public.snow_events (company_id, job_id, snow_date, kind, forecast_in, pushes)
    values (p_company, p.job_id, p_date, p.kind, p.inches, p.pushes)
    on conflict (job_id, snow_date) do update
      set forecast_in = coalesce(excluded.forecast_in, public.snow_events.forecast_in),
          pushes = greatest(public.snow_events.pushes, excluded.pushes),
          kind = case when excluded.kind = 'plow' then 'plow' else public.snow_events.kind end
    returning pushes into v_pushes;
    -- What it has that day already: the storm's own visits, or one somebody made by hand.
    select greatest(
        (select count(*) from public.snow_visits sv join public.visits v on v.id = sv.visit_id
          where sv.job_id = p.job_id and sv.snow_date = p_date and v.status <> 'cancelled'),
        (select least(1, count(*)) from public.visits v where v.job_id = p.job_id and v.scheduled_on = p_date and v.status <> 'cancelled'))
      into v_has;
    for n in v_has + 1 .. v_pushes loop
      insert into public.visits (company_id, job_id, property_id, title, scheduled_on, crew_id, notes)
      values (p_company, j.id, j.property_id,
              left(case p.kind when 'salt' then 'Salt: ' else '' end || j.title || case when v_pushes > 1 then format(' (push %s of %s)', n, v_pushes) else '' end, 200),
              p_date, j.default_crew_id,
              nullif(concat_ws(E'\n',
                case when s.clear_by is not null then 'Clear by ' || trim(to_char(s.clear_by, 'FMHH12:MI AM')) end,
                case s.priority when 1 then 'First priority' when 3 then 'After the others' end), ''))
      returning id into v_visit;
      insert into public.snow_visits (company_id, visit_id, job_id, snow_date) values (p_company, v_visit, j.id, p_date);
      insert into public.visit_assignees (company_id, visit_id, user_id)
      select p_company, v_visit, r.user_id from public.snow_recipients(array[j.id]) r where not r.office;
      if v_first and s.tell_client and n = v_has + 1 then
        perform private.emit(p_company, 'snow.scheduled', 'visit', v_visit, 'Snow service scheduled: ' || j.title,
          jsonb_build_object('client_id', j.client_id, 'kind', p.kind));
      end if;
      v_made := v_made + 1;
    end loop;
    perform private.snow_price(p.job_id, p_date);
  end loop;
  return v_made;
end $$;
revoke execute on function private.snow_schedule_visits(uuid, date, jsonb) from public;

-- Schedule them, on the Snow page: for the people who schedule the whole team.
create or replace function public.snow_schedule(p_company uuid, p_date date, p_plan jsonb) returns integer
language plpgsql security definer set search_path = '' as $$
begin
  if not (private.has_role(p_company, '{owner,admin,office}') and private.has_perm(p_company, 'schedule')) then
    raise exception 'Your role can''t schedule the whole team.' using errcode = '42501';
  end if;
  return private.snow_schedule_visits(p_company, p_date, p_plan);
end $$;

-- Schedule them as their people are told, for the server alone, and only for a business with the
-- switch on: 0 visits for any other, whatever the server asks.
create function public.snow_schedule_auto(p_company uuid, p_date date, p_plan jsonb) returns integer
language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.companies where id = p_company and settings -> 'snow_auto_schedule' = 'true'::jsonb) then
    return 0;
  end if;
  return private.snow_schedule_visits(p_company, p_date, p_plan);
end $$;
revoke execute on function public.snow_schedule_auto(uuid, date, jsonb) from public, anon, authenticated;
grant execute on function public.snow_schedule_auto(uuid, date, jsonb) to service_role;

-- The switch. Whoever may schedule a storm by hand may have storms schedule themselves.
create function public.set_snow_auto_schedule(p_company uuid, p_on boolean) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  if not (private.has_role(p_company, '{owner,admin,office}') and private.has_perm(p_company, 'schedule')) then
    raise exception 'Your role can''t schedule the whole team.' using errcode = '42501';
  end if;
  update public.companies set settings = jsonb_set(coalesce(settings, '{}'), '{snow_auto_schedule}', to_jsonb(coalesce(p_on, false))) where id = p_company;
  return coalesce(p_on, false);
end $$;
revoke execute on function public.set_snow_auto_schedule(uuid, boolean) from public, anon;
grant execute on function public.set_snow_auto_schedule(uuid, boolean) to authenticated;
