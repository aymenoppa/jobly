-- Online booking books.
--
-- A booking form could be named "Book an estimate" or "Book a service", but it only ever made a
-- request: there was no time to pick, and the visit length, lead time, most a day and "needs
-- approval" a form kept (presets set them) were never read. Now a form with "Let clients pick a
-- time" on (intake_forms.pick_time) offers real openings, and the client picks one:
--
--   * Needs the office's OK (requires_approval): the request keeps the time asked for
--     (requests.asked_starts_at, asked_ends_at). The office books it at that time with one press
--     (the API, as the person), or schedules it any other way.
--   * Books at once: public.book_form_time checks the opening again and makes the request and its
--     visit together, one booking at a time for the company's day, so two people can't take the
--     same opening and a day never passes the form's most (max_per_day).
--
-- The visit is what the office makes when it schedules an assessment from a request: an
-- assessment on the request (kind, request_id), at a fixed time (time_fixed: organizing a route
-- never moves a time a client picked), for the form's crew (intake_forms.crew_id), and the request
-- moves to "Assessment booked". "Book a service" forms get the same: a job visit needs a job, and
-- a job needs a price someone agreed to.
--
-- Whose time a form books:
--   * its crew: the crew's timed visits, the visits its people are listed on, and busy events on
--     the whole team's calendars, the crew's and its people's;
--   * no crew: everything on the company's schedule, as "Find a time" reads it with no crew
--     picked. Every timed visit of the company is in the way, so a company with one crew (or none
--     set up) is never double-booked.
-- Either way a time asked for online that still waits for the office's OK is in the way too.
--
-- Off for every form that exists: no live form starts offering times by itself. The API turns it
-- on for the estimate and booking forms a new company gets from its trade's starter set.
--
-- supabase/tests/online_booking_test.sql covers it.

alter table public.intake_forms
  add column pick_time boolean not null default false,
  add column crew_id uuid,
  add constraint intake_forms_crew_fkey foreign key (company_id, crew_id) references public.crews (company_id, id) on delete set null (crew_id);

alter table public.requests
  add column asked_starts_at timestamptz,
  add column asked_ends_at timestamptz,
  add constraint requests_asked_time_check check ((asked_starts_at is null) = (asked_ends_at is null) and (asked_ends_at is null or asked_ends_at > asked_starts_at));
-- A form's online bookings are looked up by the form and the day.
create index requests_asked_idx on public.requests (intake_form_id, asked_starts_at) where asked_starts_at is not null;
-- A request's visits are looked up by the request (which of them are booked, and when).
create index if not exists visits_request_idx on public.visits (request_id) where request_id is not null;

-- ---------------------------------------------------------------------------------------------
-- Whose time is taken
-- ---------------------------------------------------------------------------------------------

-- A crew's people: its members and its lead, as "Find a time" counts them.
create function private.crew_people(p_crew uuid) returns setof uuid
language sql stable security definer set search_path = '' as $$
  select m.user_id from public.crew_members m where m.crew_id = p_crew
  union
  select c.lead_user_id from public.crews c where c.id = p_crew and c.lead_user_id is not null
$$;

-- When whoever a booking form books is busy between two times: times only, never whose or what.
-- p_except_request leaves out that request's own asked-for time (the office booking it), and
-- p_except_visit that visit (a client moving the visit they booked).
create function public.booking_busy_times(
  p_company uuid, p_crew uuid, p_from timestamptz, p_to timestamptz, p_except_request uuid default null, p_except_visit uuid default null
) returns table (starts_at timestamptz, ends_at timestamptz)
language sql stable security definer set search_path = '' as $$
  with people as (select u as user_id from private.crew_people(p_crew) u),
  tz as (select coalesce(timezone, 'UTC') as name from public.companies where id = p_company)
  select o.starts_at, coalesce(o.ends_at, o.starts_at)
  from public.visits o
  where o.company_id = p_company and o.status <> 'cancelled' and o.starts_at is not null
    and o.id is distinct from p_except_visit
    and o.starts_at < p_to and coalesce(o.ends_at, o.starts_at) > p_from
    and (p_crew is null or o.crew_id = p_crew
         or exists (select 1 from public.visit_assignees a where a.visit_id = o.id and a.user_id in (select user_id from people)))
  union all
  select b.starts_at, b.ends_at
  from public.calendar_events e
  join public.calendar_sources s on s.id = e.source_id
  cross join tz
  -- An all-day event takes its whole days, where the company is.
  cross join lateral (select case when e.all_day or e.starts_at is null then e.starts_on::timestamp at time zone tz.name else e.starts_at end as starts_at,
                             case when e.all_day or e.ends_at is null then (e.ends_on + 1)::timestamp at time zone tz.name else e.ends_at end as ends_at) b
  where e.company_id = p_company and e.busy and s.enabled and s.blocks_time
    and b.starts_at < p_to and b.ends_at > p_from
    and (p_crew is null or (s.crew_id is null and s.user_id is null) or s.crew_id = p_crew or s.user_id in (select user_id from people))
  union all
  -- A time asked for online that the office hasn't answered: held, so nobody else is offered it.
  select r.asked_starts_at, r.asked_ends_at
  from public.requests r
  left join public.intake_forms f on f.id = r.intake_form_id
  where r.company_id = p_company and r.status = 'new' and r.asked_starts_at is not null
    and r.id is distinct from p_except_request
    and r.asked_starts_at < p_to and r.asked_ends_at > p_from
    and (p_crew is null or f.crew_id is null or f.crew_id = p_crew)
$$;

-- How many online bookings from a form each day has, between two days where the company is: the
-- requests whose visit is on that day now (wherever the office moved it; a cancelled one gives its
-- place back), and the ones still waiting for the office's OK on the day they asked for.
create function public.booking_day_counts(p_company uuid, p_form uuid, p_from date, p_to date)
returns table (day date, booked integer)
language sql stable security definer set search_path = '' as $$
  with tz as (select coalesce(timezone, 'UTC') as name from public.companies where id = p_company)
  select d.day, count(distinct d.request_id)::integer
  from (
    select v.scheduled_on as day, r.id as request_id
    from public.requests r
    join public.visits v on v.request_id = r.id
    where r.company_id = p_company and r.intake_form_id = p_form and r.asked_starts_at is not null
      and v.kind = 'assessment' and v.status <> 'cancelled' and v.scheduled_on between p_from and p_to
    union all
    select (r.asked_starts_at at time zone tz.name)::date, r.id
    from public.requests r cross join tz
    where r.company_id = p_company and r.intake_form_id = p_form and r.status = 'new' and r.asked_starts_at is not null
      and not exists (select 1 from public.visits v where v.request_id = r.id and v.kind = 'assessment')
      and (r.asked_starts_at at time zone tz.name)::date between p_from and p_to
  ) d
  group by d.day
$$;

-- The online booking a client already has coming up from a form: the visit still on the schedule
-- (where it is now), or the time they asked for that waits for the office's OK. Nothing: no rows.
create function private.upcoming_booking(p_company uuid, p_form uuid, p_client uuid)
returns table (scheduled_on date, starts_at timestamptz)
language sql stable security definer set search_path = '' as $$
  with tz as (select coalesce(timezone, 'UTC') as name from public.companies where id = p_company)
  select b.scheduled_on, b.starts_at
  from (
    select v.scheduled_on, v.starts_at
    from public.requests r
    join public.visits v on v.request_id = r.id
    cross join tz
    where r.company_id = p_company and r.intake_form_id = p_form and r.client_id = p_client and r.asked_starts_at is not null
      and r.status <> 'archived' and v.kind = 'assessment' and v.status = 'scheduled'
      and coalesce(v.starts_at, (v.scheduled_on + 1)::timestamp at time zone tz.name) > now()
    union all
    select (r.asked_starts_at at time zone tz.name)::date, r.asked_starts_at
    from public.requests r cross join tz
    where r.company_id = p_company and r.intake_form_id = p_form and r.client_id = p_client
      and r.status = 'new' and r.asked_starts_at > now()
      and not exists (select 1 from public.visits v where v.request_id = r.id and v.kind = 'assessment')
  ) b
  order by b.scheduled_on, b.starts_at
  limit 1
$$;

-- ---------------------------------------------------------------------------------------------
-- A client picks a time
-- ---------------------------------------------------------------------------------------------

-- The request a booking form makes when the client picked a time, and with a form that books at
-- once, its visit: all of it or none of it. The API offers only real openings and checks the one
-- picked (working hours, the days the business works, the time step); this checks again what can
-- change between two people looking and one of them sending, with one booking at a time for the
-- person and for the company's day:
--
--   CBONE  they already have a booking coming up from this form (the detail says when, as JSON)
--   CBTKN  the time has been taken, or is no longer one the form offers
--   CBFUL  the day has the form's most bookings now
--
-- Raised, any of them undoes everything, so a lead isn't left behind without a request.
create function public.book_form_time(
  p_company uuid, p_form uuid, p_name text, p_email text, p_phone text, p_address jsonb, p_answers jsonb,
  p_starts_at timestamptz, p_promo text default null, p_web_visit jsonb default null
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  f public.intake_forms;
  v_tz text;
  v_today date;
  v_day date;
  v_lead integer;
  v_ends timestamptz;
  v_email text := (select k from private.email_key(p_email) k where k ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' and length(k) <= 254);
  v_phone text := private.phone_e164(p_phone);
  v_found jsonb;
  v_client uuid;
  v_property uuid;
  v_has record;
  v_request public.requests;
  v_visit uuid;
  v_count integer;
begin
  select * into f from public.intake_forms where company_id = p_company and id = p_form and active and pick_time;
  if not found then
    raise exception 'This form doesn''t take bookings.' using errcode = 'P0002';
  end if;
  if p_starts_at is null then
    raise exception 'Pick a time.' using errcode = '22023';
  end if;
  select coalesce(timezone, 'UTC') into v_tz from public.companies where id = p_company;
  -- As core's bookingLength and bookingLeadDays read the form.
  v_ends := p_starts_at + make_interval(mins => case when f.slot_minutes > 0 then least(greatest(f.slot_minutes, 15), 480) else 60 end);
  v_lead := least(greatest(coalesce(f.lead_time_days, 0), 0), 30);
  v_day := (p_starts_at at time zone v_tz)::date;
  v_today := (now() at time zone v_tz)::date;
  if p_starts_at <= now() or v_day < v_today + v_lead or v_day > v_today + v_lead + 59 then
    raise exception 'That time isn''t offered anymore.' using errcode = 'CBTKN';
  end if;

  -- One at a time: for the person (by email, then by phone, the way a client is matched), then for
  -- the company's day. Always in that order, so two bookings never wait on each other.
  if v_email is not null then
    perform pg_advisory_xact_lock(hashtextextended('online-booking-email:' || p_company::text || ':' || v_email, 0));
  end if;
  if v_phone is not null then
    perform pg_advisory_xact_lock(hashtextextended('online-booking-phone:' || p_company::text || ':' || v_phone, 0));
  end if;
  perform pg_advisory_xact_lock(hashtextextended('online-booking-day:' || p_company::text || ':' || v_day::text, 0));

  v_found := public.booking_form_client(p_company, p_name, p_email, p_phone, coalesce(p_address, '{}'::jsonb));
  v_client := (v_found ->> 'client_id')::uuid;
  v_property := (v_found ->> 'property_id')::uuid;

  select * into v_has from private.upcoming_booking(p_company, p_form, v_client);
  if found then
    raise exception 'You already have a booking from this form.'
      using errcode = 'CBONE', detail = jsonb_build_object('scheduled_on', v_has.scheduled_on, 'starts_at', v_has.starts_at)::text;
  end if;
  if exists (
    select 1 from public.booking_busy_times(p_company, f.crew_id, p_starts_at, v_ends) b
    where b.starts_at < v_ends and b.ends_at > p_starts_at
  ) then
    raise exception 'That time was just taken.' using errcode = 'CBTKN';
  end if;
  if f.max_per_day > 0 then
    select coalesce(sum(c.booked), 0) into v_count from public.booking_day_counts(p_company, p_form, v_day, v_day) c;
    if v_count >= f.max_per_day then
      raise exception 'That day is full now.' using errcode = 'CBFUL';
    end if;
  end if;

  -- A client already here keeps their details; what was typed goes on the request for the office.
  insert into public.requests (company_id, client_id, property_id, intake_form_id, source, title, answers, promo_code, created_by, web_visit, asked_starts_at, asked_ends_at)
  values (
    p_company, v_client, v_property, f.id, 'web_form', f.name,
    case when (v_found ->> 'matched')::boolean
         then jsonb_strip_nulls(jsonb_build_object('name', p_name, 'email', p_email, 'phone', p_phone)) else '{}'::jsonb end || coalesce(p_answers, '{}'::jsonb),
    p_promo, null, p_web_visit, p_starts_at, v_ends
  )
  returning * into v_request;

  if not f.requires_approval then
    insert into public.visits (company_id, request_id, property_id, kind, title, starts_at, ends_at, status, crew_id, time_fixed)
    values (
      p_company, v_request.id, v_property, 'assessment',
      left(case when f.kind = 'booking' then f.name else 'Assessment: ' || f.name end, 200),
      p_starts_at, v_ends, 'scheduled', f.crew_id, true
    )
    returning id into v_visit;
    -- With no crew to send, the request's salesperson goes out, as when the office schedules it.
    if f.crew_id is null and v_request.assigned_to is not null then
      insert into public.visit_assignees (company_id, visit_id, user_id) values (p_company, v_visit, v_request.assigned_to)
      on conflict do nothing;
    end if;
    update public.requests set status = 'assessment_scheduled' where id = v_request.id and status = 'new';
  end if;

  return v_found || jsonb_build_object(
    'request_id', v_request.id, 'number', v_request.number, 'visit_id', v_visit,
    'starts_at', p_starts_at, 'ends_at', v_ends, 'booked', v_visit is not null
  );
end $$;

revoke all on function private.crew_people(uuid), private.upcoming_booking(uuid, uuid, uuid) from public;
revoke execute on function public.booking_busy_times(uuid, uuid, timestamptz, timestamptz, uuid, uuid),
  public.booking_day_counts(uuid, uuid, date, date),
  public.book_form_time(uuid, uuid, text, text, text, jsonb, jsonb, timestamptz, text, jsonb) from public, anon, authenticated;
grant execute on function public.booking_busy_times(uuid, uuid, timestamptz, timestamptz, uuid, uuid),
  public.booking_day_counts(uuid, uuid, date, date),
  public.book_form_time(uuid, uuid, text, text, text, jsonb, jsonb, timestamptz, text, jsonb) to service_role;

notify pgrst, 'reload schema';
