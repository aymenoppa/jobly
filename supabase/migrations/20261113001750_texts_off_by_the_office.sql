-- Texts off, set by the office. Until now only the person's own STOP (the keyword, by text) turned
-- texts off: someone who phoned, emailed, or texted "please stop texting me" kept getting them, and
-- the office had no way to stop that short of deleting their number. A person may ask any reasonable
-- way (47 CFR 64.1200(a)(10)), so the office can now turn texts off, and back on, for a client's or a
-- contact's number, and a text that plainly asks to stop without being the keyword counts too.
--
--   sms_stops.source     how the number came to be stopped: 'keyword' (they texted STOP), 'carrier'
--                        (Twilio refused a text because they had), 'phrase' (they texted words that
--                        plainly ask to stop), 'office' (someone in the office turned texts off).
--                        Null is a row from before this: a STOP, which is all there was.
--   sms_stops.how        for 'office': how the person asked (by phone, email, in person, by text).
--   sms_stops.note       what they texted, for 'phrase'; the office's own note, for 'office'.
--   sms_stops.set_by(_name)  who in the office set it.
--   sms_stop_changes     every time a number's texts went off or back on, and who or what did it.
--                        A stop that's lifted leaves sms_stops, so this is what's kept of it.
--
-- Only the server writes either (services/textsOff.ts). The office turns texts back on by hand only
-- for a stop Jobly alone knows about ('phrase', 'office'): after the keyword Twilio itself
-- refuses the number until the person texts START, so the server refuses too.
--
-- supabase/tests/texts_off_by_the_office_test.sql covers it.

alter table public.sms_stops
  add column source text check (source in ('keyword', 'carrier', 'phrase', 'office')),
  add column how text check (how in ('phone', 'email', 'in_person', 'text', 'other')),
  add column note text check (char_length(note) <= 500),
  add column set_by uuid references auth.users (id) on delete set null,
  add column set_by_name text check (char_length(set_by_name) <= 200);
comment on column public.sms_stops.source is
  'How the number came to be stopped: keyword (texted STOP), carrier (Twilio said it had), phrase (texted words that plainly ask to stop), office (turned off by the office). Null: a STOP from before this was recorded';
comment on column public.sms_stops.how is 'For a stop the office set: how the person asked (phone, email, in_person, text, other)';
comment on column public.sms_stops.note is 'What the person texted, for a phrase; the office''s note, for a stop it set';

create table public.sms_stop_changes (
  id bigint generated always as identity primary key,
  company_id uuid not null references public.companies (id) on delete cascade,
  phone_key text not null check (phone_key ~ '^[0-9]{7,10}$'),
  phone text not null check (char_length(phone) <= 40),
  -- False: texts went off. True: they came back on.
  texts_on boolean not null,
  -- As sms_stops.source, and 'keyword' for START turning them back on.
  source text not null check (source in ('keyword', 'carrier', 'phrase', 'office')),
  how text check (how in ('phone', 'email', 'in_person', 'text', 'other')),
  note text check (char_length(note) <= 500),
  set_by uuid references auth.users (id) on delete set null,
  set_by_name text check (char_length(set_by_name) <= 200),
  created_at timestamptz not null default now()
);
create index sms_stop_changes_number_idx on public.sms_stop_changes (company_id, phone_key, created_at desc);
comment on table public.sms_stop_changes is
  'Each time a number''s texts were turned off or back on for a company: by the person (STOP, START, words that ask to stop), by Twilio saying they had, or by the office, with who and how. The server writes it; nothing changes or deletes a row.';

-- Read by whoever reads the stop list itself. Only the server writes it.
alter table public.sms_stop_changes enable row level security;
revoke insert, update, delete on public.sms_stop_changes from authenticated;
create policy sms_stop_changes_read on public.sms_stop_changes for select to authenticated
  using (private.has_role(company_id, '{owner,admin,office,estimator}'));
select private.fold_member_checks('public.sms_stop_changes');

notify pgrst, 'reload schema';
