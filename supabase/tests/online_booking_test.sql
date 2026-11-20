-- Database tests for 20261113000700_online_booking_books.sql: a booking form's new settings, whose
-- time a form books (public.booking_busy_times, public.booking_day_counts), and a client booking a
-- time (public.book_form_time): the request and its visit together or neither, one booking for an
-- opening, the most a day and one upcoming booking a person, alone and with two people at once.
-- Run with scripts/test-db.sh (plain Postgres + prelude.sql). Any failed check stops with an error.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema tob;
grant usage on schema tob to anon, authenticated, service_role;
create function tob.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_what; end if;
  raise notice 'ok - %', p_what;
end $$;
create function tob.error_of(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'none';
exception when others then
  return sqlstate || ': ' || sqlerrm;
end $$;
-- Whether a session is waiting for a lock another holds (checked for up to 10 seconds).
create function tob.waits(p_pid integer) returns boolean language plpgsql as $$
begin
  for i in 1 .. 200 loop
    if cardinality(pg_blocking_pids(p_pid)) > 0 then return true; end if;
    perform pg_sleep(0.05);
  end loop;
  return false;
end $$;
create table tob.ctx (co uuid);
-- A day counted from the company's today, and a time on it where the company is.
create function tob.day(p_days integer) returns date language sql security definer as $$
  select private.company_today(co) + p_days from tob.ctx
$$;
create function tob.at(p_days integer, p_time time) returns timestamptz language sql security definer as $$
  select (tob.day(p_days) + p_time) at time zone 'America/Chicago'
$$;
-- A person books a time on a form, as the API does for them.
create function tob.book(p_form uuid, p_email text, p_days integer, p_time time, p_phone text default null) returns jsonb language sql security definer as $$
  select public.book_form_time(co, p_form, 'Pat Person', p_email, p_phone, '{"line1": "1 Main St", "city": "Oakridge", "postal_code": "78701"}', '{"notes": "Gate code 1234"}', tob.at(p_days, p_time))
  from tob.ctx
$$;
-- The same, answering 'booked', 'asked', or the code it was turned away with.
create function tob.try(p_form uuid, p_email text, p_days integer, p_time time, p_phone text default null) returns text language plpgsql security definer as $$
declare made jsonb;
begin
  made := tob.book(p_form, p_email, p_days, p_time, p_phone);
  return case when (made ->> 'booked')::boolean then 'booked' else 'asked' end;
exception when others then
  return sqlstate;
end $$;
-- Whether a time is busy for whoever a form with this crew books.
create function tob.busy(p_crew uuid, p_days integer, p_time time, p_except_request uuid default null, p_except_visit uuid default null) returns boolean language sql security definer as $$
  select exists (
    select 1 from tob.ctx, public.booking_busy_times(co, p_crew, tob.at(p_days, p_time), tob.at(p_days, p_time) + interval '1 hour', p_except_request, p_except_visit) b
    where b.starts_at < tob.at(p_days, p_time) + interval '1 hour' and b.ends_at > tob.at(p_days, p_time)
  )
$$;
create function tob.count_on(p_form uuid, p_days integer) returns integer language sql security definer as $$
  select coalesce((select booked from tob.ctx, public.booking_day_counts(co, p_form, tob.day(p_days), tob.day(p_days))), 0)
$$;
grant execute on all functions in schema tob to anon, authenticated, service_role;
grant select on tob.ctx to anon, authenticated, service_role;
-- A second connection, to book at the same time as this one (dblink may already be installed).
set client_min_messages = warning;
create extension if not exists dblink schema tob;
reset client_min_messages;
select extnamespace::regnamespace as dbl from pg_extension where extname = 'dblink' \gset

insert into auth.users (id, email, raw_user_meta_data) values
  ('0b000000-0000-0000-0000-000000000001', 'owner@oscar.test', '{"full_name": "Olive Owner"}'),
  ('0b000000-0000-0000-0000-000000000002', 'ray@oscar.test', '{"full_name": "Ray Crew"}');
\set owner '0b000000-0000-0000-0000-000000000001'
\set ray '0b000000-0000-0000-0000-000000000002'

begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "0b000000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select public.create_company('Oscar Roofing', 'general', 'America/Chicago') as co \gset
insert into public.memberships (company_id, user_id, role) values (:'co', :'ray', 'field_crew');
commit;
insert into tob.ctx values (:'co');
insert into public.crews (company_id, name) values (:'co', 'Crew A') returning id as crew_a \gset
insert into public.crews (company_id, name) values (:'co', 'Crew B') returning id as crew_b \gset
insert into public.crew_members (company_id, crew_id, user_id) values (:'co', :'crew_a', :'ray');
-- A form as every form was before: its booking settings kept, and no times offered.
insert into public.intake_forms (company_id, slug, name, kind, slot_minutes, max_per_day) values (:'co', 'old-form', 'Old estimate form', 'assessment', 60, 4) returning id as f_old \gset
-- Books at once, no crew, an hour a visit, two a day.
insert into public.intake_forms (company_id, slug, name, kind, pick_time, slot_minutes, lead_time_days, max_per_day)
values (:'co', 'inspection', 'Free roof inspection', 'assessment', true, 60, 1, 2) returning id as f_now \gset
-- Waits for the office's OK, for Crew A.
insert into public.intake_forms (company_id, slug, name, kind, pick_time, requires_approval, crew_id, slot_minutes, lead_time_days)
values (:'co', 'consult', 'Roof consultation', 'assessment', true, true, :'crew_a', 60, 1) returning id as f_ok \gset
-- "Book a service", for Crew A, at once, with no most-a-day and a 90-minute visit.
insert into public.intake_forms (company_id, slug, name, kind, pick_time, crew_id, slot_minutes, lead_time_days)
values (:'co', 'gutters', 'Gutter cleaning', 'booking', true, :'crew_a', 90, 0) returning id as f_crew \gset
-- A rule on a visit being booked, so the booking's own notice has something to call off.
delete from public.automation_rules where company_id = :'co' and trigger = 'visit.scheduled';
insert into public.automation_rules (company_id, name, trigger, actions) values (:'co', 'Booked', 'visit.scheduled', '[{"type": "add_note", "body": "Booked"}]');

\o
\echo 'A form''s booking settings'
\o /dev/null
select tob.check((select not pick_time and crew_id is null and slot_minutes = 60 and max_per_day = 4 from public.intake_forms where id = :'f_old'),
  'a form that was there before offers no times, and keeps the settings it had');
insert into public.clients (company_id, display_name) values (:'co', 'Walk-in Client') returning id as walk_in \gset
insert into public.requests (company_id, client_id, title) values (:'co', :'walk_in', 'Phoned in') returning id as r0 \gset
select tob.check((select asked_starts_at is null and asked_ends_at is null from public.requests where id = :'r0'), 'a request has no time asked for unless a client picked one');
select tob.check(tob.error_of(format('update public.requests set asked_starts_at = now() where id = %L', :'r0')) like '23514:%'
  and tob.error_of(format('update public.requests set asked_starts_at = now(), asked_ends_at = now() - interval %L where id = %L', '1 hour', :'r0')) like '23514:%',
  'a time asked for has a start and a later end, or neither');
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "0b000000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
update public.intake_forms set pick_time = true, crew_id = :'crew_b', requires_approval = true where id = :'f_old';
select tob.check((select pick_time and crew_id = :'crew_b' from public.intake_forms where id = :'f_old'), 'the office turns times on for a form and picks its crew');
select tob.check(tob.error_of(format('select public.book_form_time(%L, %L, %L, %L, null, %L, %L, now() + interval %L)', :'co', :'f_now', 'Pat', 'pat@example.com', '{}', '{}', '3 days')) like '42501:%',
  'someone signed in can''t book through the form''s own function');
select tob.check(tob.error_of(format('select * from public.booking_busy_times(%L, null, now(), now() + interval %L)', :'co', '7 days')) like '42501:%', 'or read when a company is busy');
select tob.check(tob.error_of(format('select * from public.booking_day_counts(%L, %L, current_date, current_date + 7)', :'co', :'f_now')) like '42501:%', 'or how many bookings its days have');
rollback;
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "0b000000-0000-0000-0000-000000000002", "role": "authenticated"}', true);
with changed as (update public.intake_forms set pick_time = true where id = :'f_old' returning 1)
select tob.check((select count(*) = 0 from changed), 'field crew can''t turn times on');
rollback;
begin;
set local role anon;
select tob.check(tob.error_of(format('select public.book_form_time(%L, %L, %L, %L, null, %L, %L, now() + interval %L)', :'co', :'f_now', 'Pat', 'pat@example.com', '{}', '{}', '3 days')) like '42501:%',
  'and nobody without a sign-in can call any of it');
rollback;
-- A crew that's deleted leaves its form booking the whole schedule.
begin;
delete from public.crews where id = :'crew_a';
select tob.check((select crew_id is null and pick_time from public.intake_forms where id = :'f_ok'), 'a form whose crew is deleted keeps offering times, against the whole schedule');
rollback;

\o
\echo 'A client books a time on a form that books at once'
\o /dev/null
set role service_role;
select tob.book(:'f_now', 'ana@example.com', 3, '09:00') as made \gset
reset role;
select (:'made'::jsonb ->> 'request_id')::uuid as r1, (:'made'::jsonb ->> 'visit_id')::uuid as v1, (:'made'::jsonb ->> 'client_id')::uuid as ana \gset
select tob.check((:'made'::jsonb ->> 'booked')::boolean and (:'made'::jsonb ->> 'new_property')::boolean and not (:'made'::jsonb ->> 'matched')::boolean and :'made'::jsonb ->> 'number' is not null,
  'the server books it, and hears what was made: a new lead, their property, the request''s number and the visit');
select tob.check((select status = 'assessment_scheduled' and source = 'web_form' and intake_form_id = :'f_now' and title = 'Free roof inspection' and created_by is null
    and asked_starts_at = tob.at(3, '09:00') and asked_ends_at = tob.at(3, '10:00') and answers = '{"notes": "Gate code 1234"}'
  from public.requests where id = :'r1'), 'the request keeps the time picked and is Assessment booked, as when the office schedules one');
select tob.check((select kind = 'assessment' and request_id = :'r1' and job_id is null and status = 'scheduled' and time_fixed and crew_id is null
    and title = 'Assessment: Free roof inspection' and starts_at = tob.at(3, '09:00') and ends_at = tob.at(3, '10:00') and scheduled_on = tob.day(3)
    and property_id = (:'made'::jsonb ->> 'property_id')::uuid
  from public.visits where id = :'v1'), 'its visit is an assessment on the request, at a fixed time, as long as the form says');
select tob.check((select status = 'lead' and display_name = 'Pat Person' and email = 'ana@example.com' from public.clients where id = :'ana'), 'the person is a new lead');
select tob.check((select count(*) = 1 from public.activity where company_id = :'co' and verb = 'request.created' and subject_id = :'r1'), 'the office hears of the request as of any other');
select tob.check((select count(*) = 1 from public.automation_runs r join public.activity a on a.id = r.activity_id where a.subject_id = :'v1' and a.verb = 'visit.scheduled' and r.status = 'pending'),
  'the visit is a visit booked, like one the office books');
set role service_role;
select tob.check(public.call_off_visit_notice(:'v1') = 1, 'whose message the server calls off once it has told the client itself');
reset role;

-- The same opening, and ones that run into it.
select count(*) as clients_before from public.clients where company_id = :'co' \gset
select tob.check(tob.try(:'f_now', 'bo@example.com', 3, '09:00') = 'CBTKN', 'a second person can''t take the same opening');
select tob.check(tob.try(:'f_now', 'bo@example.com', 3, '09:30') = 'CBTKN' and tob.try(:'f_now', 'bo@example.com', 3, '08:30') = 'CBTKN', 'or one that runs into it');
select tob.check((select count(*) from public.clients where company_id = :'co') = :clients_before and not exists (select 1 from public.clients where email = 'bo@example.com')
  and (select count(*) = 1 from public.requests where company_id = :'co' and intake_form_id is not null), 'and being turned away leaves nothing behind: no lead, no request');
select tob.check(tob.try(:'f_now', 'bo@example.com', 3, '10:00') = 'booked', 'the hour that follows on is open');
select tob.check(tob.count_on(:'f_now', 3) = 2 and tob.count_on(:'f_now', 4) = 0, 'the day has two of the form''s bookings now');
select tob.check(tob.try(:'f_now', 'cy@example.com', 3, '14:00') = 'CBFUL', 'which is the form''s most a day: a third is turned away, though the time is free');
select tob.check(tob.try(:'f_now', 'cy@example.com', 4, '14:00') = 'booked', 'the next day has room');

-- One upcoming booking a person, from a form.
select tob.check(tob.try(:'f_now', 'ana@example.com', 5, '09:00') = 'CBONE', 'someone with a booking coming up can''t make a second from the same form');
select tob.check(tob.error_of(format('select tob.book(%L, %L, 5, %L)', :'f_now', 'ANA@Example.com ', '09:00')) like 'CBONE:%', 'however they spell their email');
do $$
declare said text; detail text;
begin
  begin
    perform tob.book((select id from public.intake_forms where slug = 'inspection' and company_id = (select co from tob.ctx)), 'ana@example.com', 5, '09:00');
  exception when others then
    get stacked diagnostics said = message_text, detail = pg_exception_detail;
  end;
  perform tob.check(detail::jsonb ->> 'scheduled_on' = tob.day(3)::text and (detail::jsonb ->> 'starts_at')::timestamptz = tob.at(3, '09:00'), 'and they''re told when the one they have is');
end $$;
select tob.check(tob.try(:'f_crew', 'ana@example.com', 6, '09:00') = 'booked', 'another form is another booking');
select tob.check((select v.title = 'Gutter cleaning' and v.crew_id = :'crew_a' and v.time_fixed and v.ends_at - v.starts_at = interval '90 minutes'
    and not exists (select 1 from public.visit_assignees a where a.visit_id = v.id)
  from public.visits v join public.requests r on r.id = v.request_id where r.intake_form_id = :'f_crew' and r.client_id = :'ana'),
  'a "Book a service" form''s visit has the form''s own name, its crew (whose members are on it) and its length');
select tob.check((select r.answers = '{"name": "Pat Person", "email": "ana@example.com", "notes": "Gate code 1234"}' from public.requests r where r.intake_form_id = :'f_crew' and r.client_id = :'ana'),
  'a client already here keeps their details: what was typed goes on the request');
-- Their visit is cancelled (they asked from their Hub, say): they can book again, and the day has its place back.
update public.visits set status = 'cancelled' where id = :'v1';
select tob.check(tob.count_on(:'f_now', 3) = 1, 'a cancelled booking gives the day its place back');
select tob.check(tob.try(:'f_now', 'ana@example.com', 3, '09:00') = 'booked', 'and the person can book again, the same opening even');
select tob.check((select count(*) = 1 from public.clients where company_id = :'co' and email = 'ana@example.com'), 'as the same client, not a second one');
-- The office moves a booking to another day: it counts there.
update public.visits set starts_at = tob.at(8, '09:00'), ends_at = tob.at(8, '10:00') where request_id = (select id from public.requests where client_id = (select id from public.clients where email = 'cy@example.com'));
select tob.check(tob.count_on(:'f_now', 4) = 0 and tob.count_on(:'f_now', 8) = 1, 'a booking the office moves counts on the day it''s on now');
select tob.check(tob.try(:'f_now', 'cy@example.com', 9, '09:00') = 'CBONE', 'and is still the person''s one booking');

\o
\echo 'Times a form doesn''t offer'
\o /dev/null
select tob.check(tob.try(:'f_now', 'di@example.com', 0, '23:59') = 'CBTKN', 'not before the form''s lead time');
select tob.check(tob.try(:'f_now', 'di@example.com', -1, '09:00') = 'CBTKN', 'not in the past');
select tob.check(tob.try(:'f_now', 'di@example.com', 61, '09:00') = 'CBTKN' and tob.try(:'f_now', 'di@example.com', 60, '09:00') = 'booked', 'not past the 60 days it books ahead');
select tob.check(tob.error_of(format('select tob.book(%L, %L, 3, %L)', :'f_old', 'di2@example.com', '09:00')) like 'P0002:%', 'not on a form with times off');
update public.intake_forms set active = false where id = :'f_crew';
select tob.check(tob.try(:'f_crew', 'di2@example.com', 7, '09:00') = 'P0002', 'not on a form that''s turned off');
update public.intake_forms set active = true where id = :'f_crew';
select tob.check(tob.error_of(format('select public.book_form_time(%L, %L, %L, %L, null, %L, %L, null)', :'co', :'f_now', 'Pat', 'di2@example.com', '{}', '{}')) like '22023:%', 'and not without a time');

\o
\echo 'A form that needs the office''s OK'
\o /dev/null
set role service_role;
select tob.book(:'f_ok', 'eve@example.com', 10, '09:00', '(512) 555-0101') as asked \gset
reset role;
select (:'asked'::jsonb ->> 'request_id')::uuid as r2 \gset
select tob.check(not (:'asked'::jsonb ->> 'booked')::boolean and :'asked'::jsonb ->> 'visit_id' is null, 'nothing is booked yet');
select tob.check((select status = 'new' and asked_starts_at = tob.at(10, '09:00') and asked_ends_at = tob.at(10, '10:00') from public.requests where id = :'r2')
  and not exists (select 1 from public.visits where request_id = :'r2'), 'the request is new, with the time asked for, and has no visit');
select tob.check(tob.busy(:'crew_a', 10, '09:00') and tob.busy(null, 10, '09:30') and not tob.busy(:'crew_b', 10, '09:00'), 'the time is held: for its crew and for a form with no crew, not for another crew''s form');
select tob.check(not tob.busy(:'crew_a', 10, '09:00', :'r2'), 'but not against itself, when the office books it');
select tob.check(tob.try(:'f_ok', 'fay@example.com', 10, '09:00') = 'CBTKN', 'so nobody else can ask for it');
select tob.check(tob.try(:'f_ok', 'eve2@example.com', 11, '09:00', '512-555-0101') = 'CBONE', 'and the person, known by their phone this time, has their one booking coming up');
select tob.check(tob.count_on(:'f_ok', 10) = 1, 'it counts toward the day');
-- The office books it (the API, as the person): the visit holds the time and the request stops holding it.
insert into public.visits (company_id, request_id, kind, title, starts_at, ends_at, crew_id, time_fixed)
values (:'co', :'r2', 'assessment', 'Assessment: Roof consultation', tob.at(10, '09:00'), tob.at(10, '10:00'), :'crew_a', true) returning id as v2 \gset
update public.requests set status = 'assessment_scheduled' where id = :'r2';
select tob.check(tob.count_on(:'f_ok', 10) = 1 and tob.busy(:'crew_a', 10, '09:00') and not tob.busy(:'crew_a', 10, '09:00', null, :'v2'), 'booked, it''s one booking that day, held by its visit (not against itself when the client moves it)');
-- The office archives a request that waited instead: the time is free again.
set role service_role;
select (tob.book(:'f_ok', 'gil@example.com', 12, '09:00') ->> 'request_id')::uuid as r3 \gset
reset role;
update public.requests set status = 'archived' where id = :'r3';
select tob.check(not tob.busy(:'crew_a', 12, '09:00') and tob.count_on(:'f_ok', 12) = 0 and tob.try(:'f_ok', 'gil@example.com', 12, '09:00') = 'asked', 'a waiting request the office archives gives the time back');

\o
\echo 'Whose time a form books'
\o /dev/null
insert into public.clients (company_id, display_name) values (:'co', 'Job Client') returning id as jc \gset
insert into public.jobs (company_id, client_id, title) values (:'co', :'jc', 'Reroof') returning id as job \gset
-- Crew B is on a job on day 20 at 10; Ray (of Crew A) is listed on a visit with no crew on day 21 at 10.
insert into public.visits (company_id, job_id, title, starts_at, ends_at, crew_id) values (:'co', :'job', 'Reroof day 1', tob.at(20, '10:00'), tob.at(20, '12:00'), :'crew_b');
insert into public.visits (company_id, job_id, title, starts_at, ends_at) values (:'co', :'job', 'Punch list', tob.at(21, '10:00'), tob.at(21, '11:00')) returning id as v_ray \gset
insert into public.visit_assignees (company_id, visit_id, user_id) values (:'co', :'v_ray', :'ray');
insert into public.visits (company_id, job_id, title, scheduled_on) values (:'co', :'job', 'Anytime that day', tob.day(22));
insert into public.visits (company_id, job_id, title, starts_at, ends_at, crew_id, status) values (:'co', :'job', 'Called off', tob.at(23, '10:00'), tob.at(23, '11:00'), :'crew_a', 'cancelled');
select tob.check(tob.busy(null, 20, '10:30') and not tob.busy(:'crew_a', 20, '10:30') and tob.busy(:'crew_b', 20, '10:30'),
  'another crew''s visit is in the way of a form with no crew (the whole schedule) and of that crew''s form, not of a different crew''s');
select tob.check(tob.try(:'f_now', 'hal@example.com', 20, '10:30') = 'CBTKN' and tob.try(:'f_crew', 'hal@example.com', 20, '10:30') = 'booked', 'so a form with no crew can''t double-book a company whatever crews it has');
select tob.check(tob.busy(:'crew_a', 21, '10:00') and not tob.busy(:'crew_b', 21, '10:00') and tob.busy(null, 21, '10:00'), 'a visit one of the crew''s people is listed on is in that crew''s way');
select tob.check(not tob.busy(null, 22, '10:00') and not tob.busy(:'crew_a', 23, '10:00'), 'an anytime visit and a cancelled one take no time, as in Find a time');
-- Calendars: a holiday on the whole team's, and a crew's own.
insert into public.calendar_sources (company_id, kind, app, name, url_sealed, host) values (:'co', 'ics', 'ics_calendar', 'Holidays', 'sealed', 'example.com') returning id as cal_team \gset
insert into public.calendar_sources (company_id, kind, app, name, url_sealed, host, crew_id) values (:'co', 'ics', 'ics_calendar', 'Crew B time off', 'sealed', 'example.com', :'crew_b') returning id as cal_b \gset
insert into public.calendar_events (company_id, source_id, key, title, all_day, starts_on, ends_on) values (:'co', :'cal_team', 'hol', 'Holiday', true, tob.day(24), tob.day(24));
insert into public.calendar_events (company_id, source_id, key, title, starts_at, ends_at, starts_on, ends_on) values (:'co', :'cal_b', 'off', 'Dentist', tob.at(25, '10:00'), tob.at(25, '11:00'), tob.day(25), tob.day(25));
select tob.check(tob.busy(null, 24, '09:00') and tob.busy(:'crew_a', 24, '16:00') and not tob.busy(:'crew_a', 25, '09:00'), 'a busy day on the whole team''s calendar is everyone''s, where the company is');
select tob.check(tob.busy(:'crew_b', 25, '10:00') and not tob.busy(:'crew_a', 25, '10:00') and tob.busy(null, 25, '10:00'), 'a crew''s own calendar is that crew''s, and the whole schedule''s');
update public.calendar_sources set blocks_time = false where id = :'cal_team';
select tob.check(not tob.busy(null, 24, '09:00'), 'a calendar that doesn''t block time doesn''t');

\o
\echo 'Two people at once'
\o /dev/null
select :"dbl".dblink_connect('other', 'dbname=' || current_database());
select :"dbl".dblink_exec('other', 'set role service_role');
select pid as other_pid from :"dbl".dblink('other', 'select pg_backend_pid()') as t(pid integer) \gset
-- The same opening: this connection has booked it and not finished; the other sends for it too.
begin;
set local role service_role;
select tob.book(:'f_now', 'ian@example.com', 30, '09:00') as first \gset
select :"dbl".dblink_send_query('other', format('select tob.book(%L, %L, 30, %L)', :'f_now', 'jo@example.com', '09:00'));
select tob.check(tob.waits(:other_pid), 'a second booking for the company''s day waits for the first to finish');
commit;
select tob.check(tob.error_of(format('select * from %s.dblink_get_result(%L) as t(made jsonb)', :'dbl', 'other')) like '%That time was just taken%', 'then is told the time was just taken');
select * from :"dbl".dblink_get_result('other') as t(made jsonb);
select tob.check((select count(*) = 1 from public.visits where company_id = :'co' and starts_at = tob.at(30, '09:00') and status <> 'cancelled')
  and not exists (select 1 from public.clients where email = 'jo@example.com'), 'one visit has the opening, and the second person left nothing behind');
-- The most a day: one place left on the day, two people sending for different times.
select tob.check(tob.count_on(:'f_now', 30) = 1, 'the day has one of its two');
begin;
set local role service_role;
select tob.book(:'f_now', 'kim@example.com', 30, '11:00') as second \gset
select :"dbl".dblink_send_query('other', format('select tob.book(%L, %L, 30, %L)', :'f_now', 'lee@example.com', '14:00'));
select tob.check(tob.waits(:other_pid), 'with one place left on the day, a second booking waits for the first');
commit;
select tob.check(tob.error_of(format('select * from %s.dblink_get_result(%L) as t(made jsonb)', :'dbl', 'other')) like '%That day is full now%', 'then is told the day is full: the most a day holds');
select * from :"dbl".dblink_get_result('other') as t(made jsonb);
select tob.check(tob.count_on(:'f_now', 30) = 2, 'the day has its two, not three');
-- One person, two days at once (two tabs): only one booking.
begin;
set local role service_role;
select tob.book(:'f_now', 'max@example.com', 31, '09:00') as third \gset
select :"dbl".dblink_send_query('other', format('select tob.book(%L, %L, 32, %L)', :'f_now', 'max@example.com', '09:00'));
select tob.check(tob.waits(:other_pid), 'the same person booking two days at once waits on themselves');
commit;
select tob.check(tob.error_of(format('select * from %s.dblink_get_result(%L) as t(made jsonb)', :'dbl', 'other')) like '%already have a booking%', 'then is told they already have one');
select * from :"dbl".dblink_get_result('other') as t(made jsonb);
select tob.check((select count(*) = 1 from public.requests r join public.clients c on c.id = r.client_id where c.email = 'max@example.com')
  and (select count(*) = 1 from public.clients where email = 'max@example.com'), 'one booking, one client');
-- Two people, two days: both are booked.
begin;
set local role service_role;
select tob.book(:'f_now', 'ned@example.com', 33, '09:00') as fourth \gset
select :"dbl".dblink_send_query('other', format('select tob.book(%L, %L, 34, %L)', :'f_now', 'oz@example.com', '09:00'));
commit;
select tob.check((select made ->> 'booked' = 'true' from :"dbl".dblink_get_result('other') as t(made jsonb)), 'two people booking different days at once are both booked');
select * from :"dbl".dblink_get_result('other') as t(made jsonb);
select tob.check(tob.count_on(:'f_now', 33) = 1 and tob.count_on(:'f_now', 34) = 1, 'each on their own day');
select :"dbl".dblink_disconnect('other');

delete from public.companies where id = :'co';
set client_min_messages = warning;
drop schema tob cascade;
reset client_min_messages;

\o
\echo 'All online booking tests passed (69 checks).'
