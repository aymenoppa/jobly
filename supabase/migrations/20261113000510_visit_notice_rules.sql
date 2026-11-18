-- Starter rules that tell a client their visit is booked, moved or cancelled
-- (20261113000500_visit_notices.sql has the events), and who gets them switched on.
--
--   * A company made from now on has the three on, and the day-before reminder on too: a new
--     business tells its clients about their visits from the first one, as Jobber does.
--   * A company that exists already gets the three switched off, and nothing else of its rules is
--     touched: no client of a running business starts getting messages nobody chose to send. Its
--     owners and office see a note once, on Automations and Settings → Client notifications,
--     saying the messages exist and whether their reminder is on, with buttons to turn them on
--     (companies.settings.visit_notices, answered through public.set_visit_notices).
--   * The starters email. Where the company can text when it's created the server adds a text to
--     each and turns the on-my-way text on (public.texting_starters, called by the API, which is
--     what knows whether the server has a Twilio account). A company there already that has
--     connected its own Twilio account gets the text on its three too, still switched off.
--
-- supabase/tests/visit_notice_rules_test.sql covers it.

-- ---------------------------------------------------------------------------------------------
-- The three starters
-- ---------------------------------------------------------------------------------------------

-- Off as they're added. A new company's are turned on by private.company_defaults below, so
-- wherever else this is called (the existing companies, here) nothing starts sending.
create function private.install_visit_notice_rules(p_company uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.automation_rules (company_id, template_key, name, description, trigger, delay_minutes, conditions, actions, enabled)
  values
    (p_company, 'visit_scheduled', 'Tell clients when a visit is booked',
     'Sent ten minutes after a visit or assessment goes on the schedule, with the time it has by then. Not for the visits a recurring job makes.', 'visit.scheduled', 0, '[]',
     jsonb_build_array(jsonb_build_object('type', 'send_email',
       'subject', 'Your visit with {{company.name}} is booked for {{date}}',
       'body', E'Hi {{client.first_name}},\n\nYour {{title}} visit is booked for {{date}}{{time}}.\n\nYou can see your visits, and ask to move one, here:\n\n{{link}}\n\nQuestions? Reply to this email or call {{company.phone}}.\n\n{{company.name}}')), false),
    (p_company, 'visit_rescheduled', 'Tell clients when a visit is moved',
     'Sent ten minutes after a visit moves to another day, or its start time changes by an hour or more.', 'visit.rescheduled', 0, '[]',
     jsonb_build_array(jsonb_build_object('type', 'send_email',
       'subject', 'Your visit with {{company.name}} has moved to {{date}}',
       'body', E'Hi {{client.first_name}},\n\nYour {{title}} visit has moved. It was {{old.date}}{{old.time}} and is now {{date}}{{time}}.\n\nIf that doesn''t suit you, you can ask for another time here:\n\n{{link}}\n\nQuestions? Reply to this email or call {{company.phone}}.\n\n{{company.name}}')), false),
    (p_company, 'visit_cancelled', 'Tell clients when a visit is cancelled',
     'Sent ten minutes after a visit still to come is cancelled, deleted or taken off the schedule.', 'visit.cancelled', 0, '[]',
     jsonb_build_array(jsonb_build_object('type', 'send_email',
       'subject', 'Your visit with {{company.name}} on {{date}} is cancelled',
       'body', E'Hi {{client.first_name}},\n\nYour {{title}} visit on {{date}}{{time}} is cancelled.\n\nQuestions, or want another time? Reply to this email or call {{company.phone}}.\n\n{{company.name}}')), false)
  on conflict (company_id, template_key) do nothing;
end $$;

-- As in 20261017000200_automations.sql, and a new company starts with the three above and the
-- day-before reminder switched on.
create or replace function private.company_defaults() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform private.install_default_automations(new.id);
  perform private.install_visit_notice_rules(new.id);
  update public.automation_rules set enabled = true
   where company_id = new.id and template_key in ('visit_scheduled', 'visit_rescheduled', 'visit_cancelled', 'visit_reminder');
  return null;
end $$;

-- Each of the three texts as well as emails, for a company that can text. Only starters still as
-- they were made are changed: one the office reworded, or that has run, stays as it is. Returns
-- how many it added a text to.
create function private.add_visit_notice_texts(p_company uuid) returns integer
language plpgsql security definer set search_path = '' as $$
declare v_count integer;
begin
  update public.automation_rules r
     set actions = r.actions || jsonb_build_array(jsonb_build_object('type', 'send_sms', 'body', t.body))
    from (values
      ('visit_scheduled', 'Hi {{client.first_name}}, this is {{company.name}}. Your {{title}} visit is booked for {{date}}{{time}}.'),
      ('visit_rescheduled', 'Hi {{client.first_name}}, this is {{company.name}}. Your {{title}} visit has moved from {{old.date}}{{old.time}} to {{date}}{{time}}.'),
      ('visit_cancelled', 'Hi {{client.first_name}}, this is {{company.name}}. Your {{title}} visit on {{date}}{{time}} is cancelled.')
    ) as t(template_key, body)
   where r.company_id = p_company and r.template_key = t.template_key
     and jsonb_array_length(r.actions) = 1 and r.actions -> 0 ->> 'type' = 'send_email' and r.run_count = 0;
  get diagnostics v_count = row_count;
  return v_count;
end $$;

-- Where a new company can text: the texts above, and the on-my-way text is on (unless it has run
-- already, which is the office's to decide). The API calls this right after it creates a company,
-- when the server has a Twilio account. Returns how many rules it changed.
create function public.texting_starters(p_company uuid) returns integer
language plpgsql security definer set search_path = '' as $$
declare v_count integer; v_more integer;
begin
  v_count := private.add_visit_notice_texts(p_company);
  update public.automation_rules r set enabled = true
   where r.company_id = p_company and r.template_key = 'on_my_way' and not r.enabled and r.run_count = 0;
  get diagnostics v_more = row_count;
  return v_count + v_more;
end $$;
revoke execute on function public.texting_starters(uuid) from public, anon, authenticated;
grant execute on function public.texting_starters(uuid) to service_role;

-- ---------------------------------------------------------------------------------------------
-- The companies there are now: the three switched off, and a note to say so
-- ---------------------------------------------------------------------------------------------

select private.install_visit_notice_rules(id) from public.companies;

-- Those that text from their own Twilio account get the text on the three as well, for when they
-- turn them on. (Whether the server has an account for everyone isn't known here; such a company's
-- three email, and a text can be added to each rule.)
select private.add_visit_notice_texts(i.company_id)
  from public.integrations i
 where i.provider = 'twilio' and i.status <> 'disconnected' and i.external_account_id is not null;

update public.companies
   set settings = jsonb_set(coalesce(settings, '{}'), '{visit_notices}', '{"pending": true}')
 where jsonb_typeof(settings -> 'visit_notices') is distinct from 'object';

-- On while set_visit_notices writes, for the rest of that statement's transaction.
create function private.visit_notices_setting() returns boolean
language sql stable set search_path = '' as $$
  select coalesce(current_setting('jobly.visit_notices', true), '') = 'on'
$$;

-- Someone signed in saving settings keeps settings.visit_notices as it was, as
-- contact_messages_guard does for its switch: a page open since before this update, saving the
-- settings it read then, would otherwise take the note away unanswered.
create function private.visit_notices_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if private.visit_notices_setting() or (select auth.uid()) is null
     or new.settings -> 'visit_notices' is not distinct from old.settings -> 'visit_notices' then
    return new;
  end if;
  new.settings := case when old.settings -> 'visit_notices' is null then coalesce(new.settings, '{}') - 'visit_notices'
    else jsonb_set(coalesce(new.settings, '{}'), '{visit_notices}', old.settings -> 'visit_notices') end;
  return new;
end $$;
create trigger visit_notices_guard before update of settings on public.companies
  for each row execute function private.visit_notices_guard();

-- The note's answer, from anyone who may change the company's rules: turn the three on (and the
-- day-before reminder too, when asked), or leave everything as it is. Either way the note is
-- answered and doesn't come back. Returns how many rules it turned on.
create function public.set_visit_notices(p_company uuid, p_enabled boolean, p_reminder boolean default false) returns integer
language plpgsql security definer set search_path = '' as $$
declare v_count integer := 0;
begin
  if p_enabled is null then
    raise exception 'Say whether to turn the messages on.' using errcode = '22023';
  end if;
  if not (private.has_role(p_company, '{owner,admin,office}') and private.has_perm(p_company, 'automations')) then
    raise exception 'Only the office with the Automations area can change what clients are told.' using errcode = '42501';
  end if;
  if p_enabled then
    -- A starter that was deleted comes back, switched off, to be turned on with the others.
    perform private.install_visit_notice_rules(p_company);
    update public.automation_rules set enabled = true
     where company_id = p_company and not enabled
       and (template_key in ('visit_scheduled', 'visit_rescheduled', 'visit_cancelled') or (coalesce(p_reminder, false) and template_key = 'visit_reminder'));
    get diagnostics v_count = row_count;
  end if;
  perform set_config('jobly.visit_notices', 'on', true);
  update public.companies
     set settings = jsonb_set(coalesce(settings, '{}'), '{visit_notices}',
       jsonb_build_object('pending', false, 'answered_at', now(), 'answered_by', (select auth.uid())))
   where id = p_company;
  perform set_config('jobly.visit_notices', '', true);
  return v_count;
end $$;

revoke all on function private.install_visit_notice_rules(uuid), private.add_visit_notice_texts(uuid), private.visit_notices_setting(), private.visit_notices_guard() from public;
revoke execute on function public.set_visit_notices(uuid, boolean, boolean) from public, anon;
grant execute on function public.set_visit_notices(uuid, boolean, boolean) to authenticated;

notify pgrst, 'reload schema';
