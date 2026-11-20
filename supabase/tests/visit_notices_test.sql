-- Database tests for 20261113000500_visit_notices.sql: a visit being booked, moved or cancelled
-- starts rules (visit.scheduled, visit.rescheduled, visit.cancelled) once for what the client
-- needs to hear, ten minutes after the change, and never for the changes that aren't news to them.
-- Run with scripts/test-db.sh (plain Postgres + prelude.sql). Any failed check stops with an error.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema tvn;
grant usage on schema tvn to authenticated, service_role;
create function tvn.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_what; end if;
  raise notice 'ok - %', p_what;
end $$;
create function tvn.expect_error(p_sql text, p_what text) returns void language plpgsql as $$
begin
  begin execute p_sql; exception when others then raise notice 'ok - % (%)', p_what, sqlerrm; return; end;
  raise exception 'FAIL (expected an error): %', p_what;
end $$;
-- The company, client, property and job the visits below are booked on.
create table tvn.ctx (co uuid, client uuid, place uuid, job uuid);
-- A day counted from the company's today, and a time on it where the company is.
create function tvn.day(p_days integer) returns date language sql security definer as $$
  select private.company_today(co) + p_days from tvn.ctx
$$;
create function tvn.at(p_days integer, p_time time) returns timestamptz language sql security definer as $$
  select (tvn.day(p_days) + p_time) at time zone 'America/Chicago'
$$;
-- Book a visit on the job: on a day, or at a time on it.
create function tvn.book(p_title text, p_days integer, p_time time default null) returns uuid language sql security definer as $$
  insert into public.visits (company_id, job_id, property_id, title, scheduled_on, starts_at, ends_at)
  select co, job, place, p_title, tvn.day(p_days), tvn.at(p_days, p_time), tvn.at(p_days, p_time) + interval '1 hour' from tvn.ctx
  returning id
$$;
-- The booked, moved and cancelled events about a visit, oldest first.
create function tvn.events(p_visit uuid) returns text[] language sql security definer as $$
  select coalesce(array_agg(a.verb order by a.id), '{}') from public.activity a
  where a.subject_type = 'visit' and a.subject_id = p_visit and a.verb in ('visit.scheduled', 'visit.rescheduled', 'visit.cancelled')
$$;
-- The events about a visit whose rule is still waiting to run, oldest first.
create function tvn.waiting(p_visit uuid) returns text[] language sql security definer as $$
  select coalesce(array_agg(a.verb order by r.id), '{}') from public.automation_runs r join public.activity a on a.id = r.activity_id
  where a.subject_type = 'visit' and a.subject_id = p_visit and r.status = 'pending' and a.verb in ('visit.scheduled', 'visit.rescheduled', 'visit.cancelled')
$$;
-- What the latest of those events says.
create function tvn.said(p_visit uuid) returns jsonb language sql security definer as $$
  select a.data from public.activity a
  where a.subject_type = 'visit' and a.subject_id = p_visit and a.verb in ('visit.scheduled', 'visit.rescheduled', 'visit.cancelled')
  order by a.id desc limit 1
$$;
-- The ten minutes pass: everything waiting has gone out.
create function tvn.sent() returns void language sql security definer as $$
  update public.automation_runs r set status = 'done', finished_at = now() from tvn.ctx c where r.company_id = c.co and r.status = 'pending'
$$;
grant execute on all functions in schema tvn to authenticated, service_role;
grant select on tvn.ctx to authenticated, service_role;

insert into auth.users (id, email, raw_user_meta_data) values
  ('fd500000-0000-0000-0000-000000000001', 'owner@uniform.test', '{"full_name": "Una Owner"}');
\set owner '''fd500000-0000-0000-0000-000000000001'''

begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "fd500000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select public.create_company('Uniform Gutters', 'general', 'America/Chicago') as co \gset
commit;
-- One rule on each event, whatever starters the company came with.
delete from public.automation_rules where company_id = :'co' and trigger in ('visit.scheduled', 'visit.rescheduled', 'visit.cancelled');
insert into public.automation_rules (company_id, name, trigger, actions) values
  (:'co', 'Booked', 'visit.scheduled', '[{"type": "add_note", "body": "Booked"}]'),
  (:'co', 'Moved', 'visit.rescheduled', '[{"type": "add_note", "body": "Moved"}]'),
  (:'co', 'Cancelled', 'visit.cancelled', '[{"type": "add_note", "body": "Cancelled"}]');
insert into public.automation_rules (company_id, name, trigger, actions) values (:'co', 'Paid', 'invoice.paid', '[{"type": "add_note", "body": "Paid"}]') returning id as paid_rule \gset
insert into public.clients (company_id, display_name, email) values (:'co', 'Gus Gutter', 'gus@uniform.test') returning id as client \gset
insert into public.clients (company_id, display_name, status) values (:'co', 'Old Client', 'archived') returning id as archived \gset
insert into public.properties (company_id, client_id, line1) values (:'co', :'client', '1 Eave St') returning id as place \gset
insert into public.properties (company_id, client_id, line1) values (:'co', :'archived', '9 Past Rd') returning id as old_place \gset
insert into public.jobs (company_id, client_id, property_id, title) values (:'co', :'client', :'place', 'Clean the gutters') returning id as job \gset
insert into public.jobs (company_id, client_id, property_id, title) values (:'co', :'archived', :'old_place', 'Old work') returning id as old_job \gset
insert into public.requests (company_id, client_id, property_id, title) values (:'co', :'client', :'place', 'Look at the downspouts') returning id as request \gset
insert into tvn.ctx values (:'co', :'client', :'place', :'job');
-- Nothing above is a visit, so nothing is waiting.
select tvn.sent();

\o
\echo 'A visit is booked'
\o /dev/null
select tvn.book('Gutters', 3, '09:00') as v \gset
select tvn.check(tvn.events(:'v') = '{visit.scheduled}', 'a visit the server books for a client, with nobody signed in, is a visit booked');
select tvn.check((select count(*) = 1 and bool_and(r.run_after between now() + interval '9 minutes' and now() + interval '11 minutes' and r.subject_type = 'visit' and r.subject_id = :'v')
  from public.automation_runs r join public.activity a on a.id = r.activity_id where a.subject_id = :'v'), 'its rule runs once, ten minutes later');
select tvn.check(tvn.said(:'v') ->> 'client_id' = :'client' and tvn.said(:'v') ->> 'kind' = 'job', 'the event names the client');
select tvn.check((select summary = 'Visit booked: Gutters (Gus Gutter)' from public.activity where subject_id = :'v' and verb = 'visit.scheduled'), 'and reads as a visit booked');

begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "fd500000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
insert into public.visits (company_id, request_id, property_id, kind, title, scheduled_on) values (:'co', :'request', :'place', 'assessment', 'Look at the downspouts', tvn.day(2)) returning id as assess \gset
commit;
select tvn.check(tvn.events(:'assess') = '{visit.scheduled}' and (select actor_id = :owner from public.activity where subject_id = :'assess'), 'an assessment someone in the office books is one too, in their name');

insert into public.visits (company_id, job_id, property_id, title, status) values (:'co', :'job', :'place', 'Later', 'unscheduled') returning id as later \gset
select tvn.check(tvn.events(:'later') = '{}', 'a visit with no day yet isn''t booked');
update public.visits set status = 'scheduled', scheduled_on = tvn.day(5) where id = :'later';
select tvn.check(tvn.events(:'later') = '{visit.scheduled}', 'giving it its first day is');

-- Never.
insert into public.visits (company_id, job_id, property_id, title, scheduled_on, recurrence_key) values (:'co', :'job', :'place', 'Made by the schedule', tvn.day(7), tvn.day(7)::text) returning id as made \gset
select tvn.check(tvn.events(:'made') = '{}', 'not a visit a recurring job''s schedule makes');
select tvn.book('Yesterday', -1) as past \gset
select tvn.check(tvn.events(:'past') = '{}', 'not a visit on a day that''s gone');
insert into public.visits (company_id, job_id, property_id, title, starts_at, ends_at) values (:'co', :'job', :'place', 'Earlier today', now() - interval '2 hours', now() - interval '1 hour') returning id as earlier \gset
select tvn.check(tvn.events(:'earlier') = '{}', 'not a visit written down after it began');
insert into public.visits (company_id, job_id, property_id, title, scheduled_on, status) values (:'co', :'job', :'place', 'Done already', tvn.day(0), 'completed') returning id as done \gset
select tvn.check(tvn.events(:'done') = '{}', 'not a visit created already completed');
insert into public.visits (company_id, kind, title, scheduled_on) values (:'co', 'task', 'Order hangers', tvn.day(1)) returning id as task \gset
select tvn.check(tvn.events(:'task') = '{}', 'not a task');
insert into public.visits (company_id, job_id, property_id, title, scheduled_on) values (:'co', :'old_job', :'old_place', 'For an archived client', tvn.day(1)) returning id as old_visit \gset
select tvn.check(tvn.events(:'old_visit') = '{}', 'not a visit for an archived client');
begin;
select set_config('jobly.quiet', 'on', true);
select tvn.book('Imported', 4) as imported \gset
commit;
select tvn.check(tvn.events(:'imported') = '{}', 'not a visit an import brings in');
begin;
select set_config('jobly.schedule_quiet', 'on', true);
select tvn.book('Quietly', 4) as quietly \gset
commit;
select tvn.check(tvn.events(:'quietly') = '{}', 'not while a recurring job''s schedule is being changed');
update public.automation_rules set enabled = false where company_id = :'co' and trigger = 'visit.scheduled';
select tvn.book('Nobody asked', 4) as unasked \gset
select tvn.check(tvn.events(:'unasked') = '{}', 'and not for a company with no rule on it turned on');
update public.automation_rules set enabled = true where company_id = :'co' and trigger = 'visit.scheduled';

\o
\echo 'A visit is moved'
\o /dev/null
select tvn.sent();
update public.visits set starts_at = tvn.at(4, '09:00'), ends_at = tvn.at(4, '10:00') where id = :'v';
select tvn.check(tvn.events(:'v') = '{visit.scheduled,visit.rescheduled}' and tvn.waiting(:'v') = '{visit.rescheduled}', 'a visit moved to another day is a visit moved');
select tvn.check(tvn.said(:'v') ->> 'was_scheduled_on' = tvn.day(3)::text and (tvn.said(:'v') ->> 'was_starts_at')::timestamptz = tvn.at(3, '09:00'), 'the event says when it was');
select tvn.sent();

-- The same day: an hour or more is a move, less isn't.
update public.visits set starts_at = tvn.at(4, '09:30'), ends_at = tvn.at(4, '10:30') where id = :'v';
select tvn.check(tvn.waiting(:'v') = '{}', 'a start half an hour later the same day isn''t');
update public.visits set starts_at = tvn.at(4, '09:00'), ends_at = tvn.at(4, '10:00') where id = :'v';
update public.visits set starts_at = tvn.at(4, '10:00'), ends_at = tvn.at(4, '11:00') where id = :'v';
select tvn.check(tvn.waiting(:'v') = '{visit.rescheduled}', 'a start an hour later is');
select tvn.sent();
update public.visits set starts_at = tvn.at(4, '09:00'), ends_at = tvn.at(4, '10:00') where id = :'v';
select tvn.check(tvn.waiting(:'v') = '{visit.rescheduled}', 'and so is one an hour earlier');
select tvn.sent();

-- With an arrival window, a later start inside it is where the client was told.
update public.companies set settings = jsonb_set(coalesce(settings, '{}'), '{arrival_window_min}', '120') where id = :'co';
update public.visits set starts_at = tvn.at(4, '10:30'), ends_at = tvn.at(4, '11:30') where id = :'v';
select tvn.check(tvn.waiting(:'v') = '{}', 'with a two-hour arrival window, a start 90 minutes later is still when the client was told');
update public.visits set starts_at = tvn.at(4, '13:00'), ends_at = tvn.at(4, '14:00') where id = :'v';
select tvn.check(tvn.waiting(:'v') = '{visit.rescheduled}', 'a start past the window is a move');
select tvn.sent();
update public.visits set starts_at = tvn.at(4, '12:00'), ends_at = tvn.at(4, '13:00') where id = :'v';
select tvn.check(tvn.waiting(:'v') = '{visit.rescheduled}', 'and so is one an hour before it');
select tvn.sent();
update public.companies set settings = settings - 'arrival_window_min' where id = :'co';
select tvn.check(private.arrival_window('{"arrival_window_min": 120}') = interval '2 hours' and private.arrival_window('{"arrival_window_min": "90"}') = interval '90 minutes'
  and private.arrival_window('{"arrival_window_min": "soon"}') = interval '0' and private.arrival_window('{}') = interval '0' and private.arrival_window(null) = interval '0'
  and private.arrival_window('{"arrival_window_min": 99999}') = interval '12 hours' and private.arrival_window('{"arrival_window_min": -30}') = interval '0',
  'the arrival window is read as the app reads it: minutes, at most 12 hours, none when it isn''t a number');

-- A route being organized gives an anytime visit a time, or takes one away: the day is the same.
select tvn.book('Anytime', 6) as anytime \gset
select tvn.sent();
update public.visits set starts_at = tvn.at(6, '08:15'), ends_at = tvn.at(6, '09:15'), route_order = 1 where id = :'anytime';
select tvn.check(tvn.waiting(:'anytime') = '{}', 'an anytime visit given a time on its day by the route isn''t moved');
update public.visits set starts_at = tvn.at(6, '08:55'), ends_at = tvn.at(6, '09:55'), route_order = 2 where id = :'anytime';
select tvn.check(tvn.waiting(:'anytime') = '{}', 'nor is one the route re-times by less than an hour');
update public.visits set starts_at = null, ends_at = null, route_order = null where id = :'anytime';
select tvn.check(tvn.waiting(:'anytime') = '{}' and tvn.events(:'anytime') = '{visit.scheduled}', 'nor one that goes back to any time that day');

-- Not still to come.
update public.visits set scheduled_on = tvn.day(-2) where id = :'anytime';
select tvn.check(tvn.waiting(:'anytime') = '{}', 'a visit moved into the past isn''t a move to tell anyone about');
update public.visits set scheduled_on = tvn.day(2) where id = :'anytime';
select tvn.check(tvn.waiting(:'anytime') = '{visit.rescheduled}' and tvn.said(:'anytime') ->> 'was_scheduled_on' = tvn.day(-2)::text, 'a visit that was missed and moved to a day to come is');
select tvn.sent();
update public.visits set status = 'in_progress' where id = :'anytime';
update public.visits set scheduled_on = tvn.day(3) where id = :'anytime';
select tvn.check(tvn.waiting(:'anytime') = '{}', 'a visit already under way isn''t');
update public.visits set status = 'scheduled' where id = :'anytime';
select tvn.check(tvn.waiting(:'anytime') = '{}' and tvn.events(:'anytime') = '{visit.scheduled,visit.rescheduled}', 'and stepping it back to scheduled isn''t booking it again');
update public.visits set scheduled_on = tvn.day(8) where id = :'old_visit';
select tvn.check(tvn.events(:'old_visit') = '{}', 'an archived client''s visit moving is nothing');

-- A recurring job's whole run changing is quiet; one of its visits moved by hand is not.
insert into public.jobs (company_id, client_id, property_id, title, kind, recurrence_rule, starts_on, visit_start_time, visit_duration_min)
values (:'co', :'client', :'place', 'Monthly gutters', 'recurring', 'FREQ=MONTHLY', current_date, '09:00', 60) returning id as rec \gset
insert into public.visits (company_id, job_id, property_id, title, starts_at, ends_at, recurrence_key)
select :'co', :'rec', :'place', 'Monthly gutters', tvn.at(d, '09:00'), tvn.at(d, '10:00'), tvn.day(d)::text from unnest(array[10, 40, 70]) d;
select id as rec1 from public.visits where job_id = :'rec' and scheduled_on = tvn.day(10) \gset
select id as rec2 from public.visits where job_id = :'rec' and scheduled_on = tvn.day(40) \gset
update public.jobs set visit_start_time = '14:00' where id = :'rec';
select tvn.check(public.refresh_upcoming_visits(:'rec') = 3, 'a recurring job''s new time moves its upcoming visits');
select tvn.check((select starts_at = tvn.at(10, '14:00') from public.visits where id = :'rec1'), 'by five hours');
select tvn.check(tvn.events(:'rec1') = '{}' and tvn.events(:'rec2') = '{}', 'and none of them is a visit moved: the whole schedule changed');
update public.visits set starts_at = tvn.at(11, '14:00'), ends_at = tvn.at(11, '15:00') where id = :'rec1';
select tvn.check(tvn.events(:'rec1') = '{visit.rescheduled}', 'one of its visits moved by hand is');
select tvn.sent();

\o
\echo 'A visit is cancelled'
\o /dev/null
update public.visits set status = 'cancelled' where id = :'v';
select tvn.check(tvn.waiting(:'v') = '{visit.cancelled}', 'a visit to come that''s cancelled is a visit cancelled');
select tvn.check(tvn.said(:'v') ->> 'was_scheduled_on' = tvn.day(4)::text and (tvn.said(:'v') ->> 'was_starts_at')::timestamptz = tvn.at(4, '12:00')
  and tvn.said(:'v') ->> 'title' = 'Gutters' and tvn.said(:'v') ->> 'property_id' = :'place' and tvn.said(:'v') ->> 'job_id' = :'job' and tvn.said(:'v') ->> 'deleted' = 'false',
  'the event keeps when and where it was');
select tvn.sent();
delete from public.visits where id = :'v';
select tvn.check(tvn.events(:'v') = '{visit.scheduled,visit.rescheduled,visit.rescheduled,visit.rescheduled,visit.rescheduled,visit.rescheduled,visit.cancelled}', 'deleting a cancelled visit says nothing more');

delete from public.visits where id = :'later';
select tvn.check(tvn.waiting(:'later') = '{visit.cancelled}' and tvn.said(:'later') ->> 'deleted' = 'true' and tvn.said(:'later') ->> 'was_scheduled_on' = tvn.day(5)::text and tvn.said(:'later') ->> 'title' = 'Later',
  'a visit to come that''s deleted is one too, and the event still says what it was');
update public.visits set status = 'unscheduled', scheduled_on = null where id = :'assess';
select tvn.check(tvn.waiting(:'assess') = '{visit.cancelled}', 'and so is one taken off the schedule');
select tvn.sent();
update public.visits set status = 'scheduled', scheduled_on = tvn.day(9) where id = :'assess';
select tvn.check(tvn.waiting(:'assess') = '{visit.scheduled}', 'put back on later, it''s booked again');
select tvn.sent();

-- Never.
update public.visits set status = 'cancelled' where id = :'past';
delete from public.visits where id = :'done';
select tvn.check(tvn.events(:'past') = '{}' and tvn.events(:'done') = '{}', 'not a past visit cancelled, or a finished one deleted');
delete from public.visits where id = :'old_visit';
select tvn.check(tvn.events(:'old_visit') = '{}', 'not an archived client''s');
select tvn.check(public.remove_recurring_visits(:'rec', array[:'rec2']::uuid[]) = 1, 'the server takes a visit off when a recurring job''s schedule no longer has it');
select tvn.check(tvn.events(:'rec2') = '{}', 'which isn''t a visit cancelled');
update public.jobs set status = 'archived' where id = :'rec';
select tvn.check((select count(*) = 0 from public.visits where job_id = :'rec') and tvn.events(:'rec1') = '{visit.rescheduled}', 'not a closed job''s visits coming off the schedule');
-- A deleted recurring job takes its visits with it quietly; a deleted one-off job's booked visit is cancelled for its client.
insert into public.jobs (company_id, client_id, property_id, title, kind, recurrence_rule, starts_on) values (:'co', :'client', :'place', 'Weekly sweep', 'recurring', 'FREQ=WEEKLY', current_date) returning id as rec_gone \gset
insert into public.visits (company_id, job_id, property_id, title, scheduled_on, recurrence_key) values (:'co', :'rec_gone', :'place', 'Weekly sweep', tvn.day(7), tvn.day(7)::text) returning id as sweep \gset
delete from public.jobs where id = :'rec_gone';
select tvn.check(tvn.events(:'sweep') = '{}', 'not a deleted recurring job''s visits');
insert into public.jobs (company_id, client_id, property_id, title) values (:'co', :'client', :'place', 'One-off repair') returning id as one_off \gset
insert into public.visits (company_id, job_id, property_id, title, scheduled_on) values (:'co', :'one_off', :'place', 'Repair', tvn.day(3)) returning id as repair \gset
select tvn.sent();
delete from public.jobs where id = :'one_off';
select tvn.check(tvn.waiting(:'repair') = '{visit.cancelled}' and tvn.said(:'repair') ->> 'client_id' = :'client', 'a deleted one-off job''s booked visit is a visit cancelled for its client');
select tvn.sent();

\o
\echo 'The client''s own request from the Hub'
\o /dev/null
select tvn.book('Hub visit', 5, '09:00') as hub \gset
select tvn.book('Hub cancel', 5, '13:00') as hub2 \gset
select tvn.book('Hub words', 5, '15:00') as hub3 \gset
select tvn.sent();
insert into public.visit_change_requests (company_id, visit_id, client_id, kind, scheduled_on, starts_at, ends_at)
values (:'co', :'hub', :'client', 'reschedule', tvn.day(6), tvn.at(6, '11:00'), tvn.at(6, '12:00')) returning id as ask \gset
update public.visit_change_requests set status = 'approved' where id = :'ask';
update public.visits set starts_at = tvn.at(6, '11:00'), ends_at = tvn.at(6, '12:00') where id = :'hub';
select tvn.check(tvn.events(:'hub') = '{visit.scheduled}', 'the move that answers a client''s own request isn''t told twice: the approval tells them');
update public.visits set starts_at = tvn.at(8, '11:00'), ends_at = tvn.at(8, '12:00') where id = :'hub';
select tvn.check(tvn.waiting(:'hub') = '{visit.rescheduled}', 'a move to some other day right after is the office''s own, and is told');
select tvn.sent();
insert into public.visit_change_requests (company_id, visit_id, client_id, kind, reason) values (:'co', :'hub2', :'client', 'cancel', 'Away') returning id as ask2 \gset
update public.visit_change_requests set status = 'approved' where id = :'ask2';
update public.visits set status = 'cancelled' where id = :'hub2';
select tvn.check(tvn.events(:'hub2') = '{visit.scheduled}', 'nor is the cancelling they asked for');
-- They named no time, so the office moved it and then approved: the approval says where it is now.
insert into public.visit_change_requests (company_id, visit_id, client_id, kind, message) values (:'co', :'hub3', :'client', 'reschedule', 'Any afternoon next week') returning id as ask3 \gset
update public.visits set starts_at = tvn.at(9, '15:00'), ends_at = tvn.at(9, '16:00') where id = :'hub3';
select tvn.check(tvn.waiting(:'hub3') = '{visit.rescheduled}', 'a visit the office moves for a client who named no time waits to be told');
update public.visit_change_requests set status = 'approved' where id = :'ask3';
select tvn.check(tvn.waiting(:'hub3') = '{}' and (select r.status = 'cancelled' and r.error = 'The client was told when their request was approved'
  from public.automation_runs r join public.activity a on a.id = r.activity_id where a.subject_id = :'hub3' and a.verb = 'visit.rescheduled'), 'and approving their request calls that off: the approval tells them');
-- A request declined changes nothing about what the office does next.
insert into public.visit_change_requests (company_id, visit_id, client_id, kind, scheduled_on) values (:'co', :'hub', :'client', 'reschedule', tvn.day(12)) returning id as ask4 \gset
update public.visit_change_requests set status = 'declined' where id = :'ask4';
update public.visits set starts_at = tvn.at(12, '11:00'), ends_at = tvn.at(12, '12:00') where id = :'hub';
select tvn.check(tvn.waiting(:'hub') = '{visit.rescheduled}', 'a move after a request was declined is told as any other');
select tvn.sent();

\o
\echo 'Changes fold while the message waits'
\o /dev/null
select tvn.book('Folds', 3, '09:00') as f1 \gset
update public.visits set starts_at = tvn.at(5, '13:00'), ends_at = tvn.at(5, '14:00') where id = :'f1';
select tvn.check(tvn.events(:'f1') = '{visit.scheduled}' and tvn.waiting(:'f1') = '{visit.scheduled}', 'booked and then moved before the message went is one booked, which says where it is by then');
update public.visits set status = 'cancelled' where id = :'f1';
select tvn.check(tvn.events(:'f1') = '{visit.scheduled}' and tvn.waiting(:'f1') = '{}'
  and (select r.status = 'cancelled' and r.error = 'The visit came off the schedule before this went out' from public.automation_runs r join public.activity a on a.id = r.activity_id where a.subject_id = :'f1'),
  'booked and then cancelled before it went is nothing at all');
select tvn.book('Booked and deleted', 3) as f2 \gset
delete from public.visits where id = :'f2';
select tvn.check(tvn.events(:'f2') = '{visit.scheduled}' and tvn.waiting(:'f2') = '{}', 'and so is booked and then deleted');

select tvn.book('Dragged', 3, '09:00') as f3 \gset
select tvn.sent();
update public.visits set starts_at = tvn.at(4, '09:00'), ends_at = tvn.at(4, '10:00') where id = :'f3';
update public.visits set starts_at = tvn.at(5, '11:00'), ends_at = tvn.at(5, '12:00') where id = :'f3';
select tvn.check(tvn.events(:'f3') = '{visit.scheduled,visit.rescheduled}' and tvn.waiting(:'f3') = '{visit.rescheduled}' and tvn.said(:'f3') ->> 'was_scheduled_on' = tvn.day(3)::text,
  'a visit dragged twice is one move, from where the client knew it');
update public.visits set starts_at = tvn.at(3, '09:30'), ends_at = tvn.at(3, '10:30') where id = :'f3';
select tvn.check(tvn.events(:'f3') = '{visit.scheduled,visit.rescheduled}' and tvn.waiting(:'f3') = '{}'
  and (select r.error = 'The visit went back to where it was' from public.automation_runs r join public.activity a on a.id = r.activity_id where a.subject_id = :'f3' and a.verb = 'visit.rescheduled'),
  'dragged back to where it was (near enough) is no message');
update public.visits set starts_at = tvn.at(6, '09:00'), ends_at = tvn.at(6, '10:00') where id = :'f3';
update public.visits set status = 'cancelled' where id = :'f3';
select tvn.check(tvn.waiting(:'f3') = '{visit.cancelled}' and tvn.said(:'f3') ->> 'was_scheduled_on' = tvn.day(3)::text and (tvn.said(:'f3') ->> 'was_starts_at')::timestamptz = tvn.at(3, '09:30'),
  'moved and then cancelled before the move was told is one cancelled, for the day the client knew');
update public.visits set status = 'scheduled' where id = :'f3';
select tvn.check(tvn.waiting(:'f3') = '{visit.rescheduled}' and tvn.said(:'f3') ->> 'was_scheduled_on' = tvn.day(3)::text,
  'cancelled and put back on another day before the client heard is a move from the day they knew');
update public.visits set status = 'cancelled' where id = :'f3';
update public.visits set status = 'scheduled', starts_at = tvn.at(3, '09:30'), ends_at = tvn.at(3, '10:30') where id = :'f3';
select tvn.check(tvn.waiting(:'f3') = '{}', 'cancelled and put back where it was before they heard is nothing');
select tvn.check((select count(*) = 0 from public.automation_runs r join public.activity a on a.id = r.activity_id where a.subject_id = :'f3' and r.status = 'done' and a.verb <> 'visit.scheduled'),
  'all that back and forth sent the client nothing');

-- Each event's rule waits by itself: a rule turned off calls its own off.
select tvn.book('Rule off', 3) as f4 \gset
update public.automation_rules set enabled = false where company_id = :'co' and trigger = 'visit.scheduled';
select tvn.check(tvn.waiting(:'f4') = '{}', 'turning the rule off calls off what it had waiting');
update public.visits set scheduled_on = tvn.day(4) where id = :'f4';
select tvn.check(tvn.waiting(:'f4') = '{visit.rescheduled}', 'and the next move is told as a move');
update public.automation_rules set enabled = true where company_id = :'co' and trigger = 'visit.scheduled';
select tvn.sent();

\o
\echo 'A rain day, and multi-day work'
\o /dev/null
insert into public.visits (company_id, job_id, property_id, title, starts_at, ends_at)
select :'co', :'job', :'place', 'Rain ' || n, tvn.at(20, '08:00') + make_interval(mins => 10 * n), tvn.at(20, '09:00') + make_interval(mins => 10 * n) from generate_series(1, 30) n;
select tvn.sent();
update public.visits set starts_at = starts_at + interval '1 day', ends_at = ends_at + interval '1 day', hold_reason = null where company_id = :'co' and title like 'Rain %';
select tvn.check((select count(*) = 30 and count(distinct a.subject_id) = 30 from public.activity a join public.visits v on v.id = a.subject_id where v.company_id = :'co' and v.title like 'Rain %' and a.verb = 'visit.rescheduled'),
  'a rain day that moves 30 visits is 30 moves, one for each visit');
select tvn.check((select count(*) = 30 and bool_and(r.run_after > now() + interval '9 minutes') from public.automation_runs r join public.activity a on a.id = r.activity_id join public.visits v on v.id = a.subject_id
  where v.company_id = :'co' and v.title like 'Rain %' and r.status = 'pending'), 'each waiting its ten minutes, none sent while the day is being moved');
select tvn.sent();

insert into public.visits (company_id, job_id, property_id, title, scheduled_on, series_id, series_day, series_total)
select :'co', :'job', :'place', 'Three days', tvn.day(13 + n), 'fd500000-0000-0000-0000-0000000000a1', n, 3 from generate_series(1, 3) n;
select id as s1 from public.visits where series_id = 'fd500000-0000-0000-0000-0000000000a1' and series_day = 1 \gset
select id as s2 from public.visits where series_id = 'fd500000-0000-0000-0000-0000000000a1' and series_day = 2 \gset
select id as s3 from public.visits where series_id = 'fd500000-0000-0000-0000-0000000000a1' and series_day = 3 \gset
select r.id as run1 from public.automation_runs r join public.activity a on a.id = r.activity_id where a.subject_id = :'s1' and r.status = 'pending' \gset
select r.id as run2 from public.automation_runs r join public.activity a on a.id = r.activity_id where a.subject_id = :'s2' and r.status = 'pending' \gset
select r.id as run3 from public.automation_runs r join public.activity a on a.id = r.activity_id where a.subject_id = :'s3' and r.status = 'pending' \gset
select tvn.check(tvn.events(:'s1') = '{visit.scheduled}' and tvn.events(:'s2') = '{visit.scheduled}' and tvn.events(:'s3') = '{visit.scheduled}', 'each day of multi-day work has its event');
set role service_role;
select tvn.check(not public.visit_notice_is_repeat(:'run1') and public.visit_notice_is_repeat(:'run2') and public.visit_notice_is_repeat(:'run3'), 'and only the first day''s is the one to send');
reset role;
update public.automation_runs set status = 'done', finished_at = now() where id = :'run1';
set role service_role;
select tvn.check(public.visit_notice_is_repeat(:'run2') and public.visit_notice_is_repeat(:'run3'), 'the others stay repeats once it has gone');
reset role;
select tvn.sent();
-- The whole job moves a week: three moves, one message.
update public.visits set scheduled_on = scheduled_on + 7 where series_id = 'fd500000-0000-0000-0000-0000000000a1';
select r.id as move1 from public.automation_runs r join public.activity a on a.id = r.activity_id where a.subject_id = :'s1' and r.status = 'pending' \gset
select r.id as move2 from public.automation_runs r join public.activity a on a.id = r.activity_id where a.subject_id = :'s2' and r.status = 'pending' \gset
select r.id as move3 from public.automation_runs r join public.activity a on a.id = r.activity_id where a.subject_id = :'s3' and r.status = 'pending' \gset
set role service_role;
select tvn.check(not public.visit_notice_is_repeat(:'move1') and public.visit_notice_is_repeat(:'move2') and public.visit_notice_is_repeat(:'move3'), 'multi-day work moved together is one message too');
reset role;
-- Its first day goes back: the second day's move is now the one to send.
update public.visits set scheduled_on = scheduled_on - 7 where id = :'s1';
set role service_role;
select tvn.check(not public.visit_notice_is_repeat(:'move2') and public.visit_notice_is_repeat(:'move3'), 'when the first day goes back where it was, the next day''s move is the one that goes');
reset role;
select tvn.sent();
select r.id as plain from public.automation_runs r join public.activity a on a.id = r.activity_id join public.visits v on v.id = a.subject_id where v.company_id = :'co' and v.title = 'Rain 2' and a.verb = 'visit.rescheduled' \gset
set role service_role;
select tvn.check(not public.visit_notice_is_repeat(:'plain'), 'a run about a visit that isn''t multi-day work is never a repeat, however many moved with it');
reset role;

\o
\echo 'For the server'
\o /dev/null
select tvn.book('Booked online', 4, '10:00') as online \gset
select tvn.book('Confirmed by the booking page', 4, '11:00') as confirmed \gset
set role service_role;
select tvn.check(public.send_visit_notice_now(:'online') = 1, 'the server can have a booking''s message go now');
select tvn.check(public.call_off_visit_notice(:'confirmed') = 1, 'or call it off when it told the client itself');
reset role;
select tvn.check((select r.status = 'pending' and r.run_after <= now() from public.automation_runs r join public.activity a on a.id = r.activity_id where a.subject_id = :'online'), 'the first is due');
select tvn.check((select r.status = 'cancelled' and r.error = 'The client was told another way' from public.automation_runs r join public.activity a on a.id = r.activity_id where a.subject_id = :'confirmed'), 'the second won''t go');
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "fd500000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select tvn.expect_error(format('select public.call_off_visit_notice(%L)', :'online'), 'someone signed in can''t call a message off');
select tvn.expect_error(format('select public.send_visit_notice_now(%L)', :'online'), 'or hurry one');
select tvn.expect_error('select public.visit_notice_is_repeat(1)', 'or ask about runs');
commit;

-- Other rules run when they always did.
insert into public.activity (company_id, verb, subject_type, subject_id, summary) values (:'co', 'invoice.paid', 'invoice', gen_random_uuid(), 'Paid');
select tvn.check((select count(*) = 1 and bool_and(run_after <= now() + interval '1 second') from public.automation_runs where rule_id = :'paid_rule'), 'a rule on anything else still runs at once');

-- The whole company going takes its visits with it, and says nothing.
delete from public.companies where id = :'co';
set client_min_messages = warning;
drop schema tvn cascade;
reset client_min_messages;

\o
\echo 'All visit notice tests passed (83 checks).'
