-- The language each person uses Jobly in (Settings → Profile → Language, or My day's question
-- when their phone speaks Spanish): 'en', 'es', or null for not chosen, which follows the choice
-- made on the device they're using and else English. Notifications to them (the bell, push, email
-- and texts) go out in it. An app cached from before this column ignores it.
alter table public.profiles add column if not exists locale text;

alter table public.profiles drop constraint if exists profiles_locale_check;
alter table public.profiles add constraint profiles_locale_check check (locale in ('en', 'es'));

comment on column public.profiles.locale is
  'The language this person uses the app in: en or es (packages/core/src/i18n LOCALES); null follows their device.';

-- Each person sets their own, as with their name and phone (profiles_update lets only their own row).
grant update (locale) on public.profiles to authenticated;
