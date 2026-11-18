-- The clock at the property: which clocks the phone started or stopped by itself.
--
-- A company can have the field app start a person's clock when they get to a visit's property and
-- stop it when they leave (settings.clock.geofence.mode = 'clock'; Settings → Company → Time clock;
-- packages/core/src/geofence.ts). It's off for every company until the office turns it on: with
-- nothing saved it's off, so nothing changes for an existing company or a new one.
--
-- The phone makes those starts and stops through the same writes as a tap, so on Timesheets they'd
-- look like taps. Two marks on the time entry tell them apart for the office:
--
--   geofence_in    The clock started as the person arrived at the property (or, on the whole-day
--                  clock, travel started as they left it).
--   geofence_out   The clock stopped as they left the property (or, for travel, as they arrived
--                  at the next one).
--
-- Like where people clocked in and out (20261024000100_clock_places.sql), a mark is made with the
-- clock itself and can't be added later: geofence_in only as a running clock is added, geofence_out
-- only by the write that stops it. When someone changes that time afterwards (fixing it on
-- Timesheets), the mark comes off, since the time is theirs now. The server's own writes (the hourly
-- upkeep, a finished visit's clocks) never set them. An app from before this sends neither, and its
-- entries are taps, as they always were.
--
-- supabase/tests/clock_at_the_property_test.sql covers it.

alter table public.time_entries
  add column geofence_in boolean not null default false,
  add column geofence_out boolean not null default false;
comment on column public.time_entries.geofence_in is 'Started by the phone at the property (the clock at the property), not by a tap';
comment on column public.time_entries.geofence_out is 'Stopped by the phone at the property (the clock at the property), not by a tap';

-- Readable as every other column is (20261018000700_time_entry_pay_privacy.sql).
grant select (geofence_in, geofence_out) on public.time_entries to authenticated;

create function private.time_entry_geofence_guard() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    -- Only a clock added running, as the phone adds it.
    new.geofence_in := coalesce(new.geofence_in, false) and new.ended_at is null;
    new.geofence_out := false;
    return new;
  end if;
  -- Made with the clock, never later.
  if new.geofence_in and not old.geofence_in then
    new.geofence_in := false;
  end if;
  if new.geofence_out and not old.geofence_out and not (old.ended_at is null and new.ended_at is not null) then
    new.geofence_out := false;
  end if;
  -- A time changed afterwards is the person's own.
  if new.started_at is distinct from old.started_at then
    new.geofence_in := false;
  end if;
  if old.ended_at is not null and new.ended_at is distinct from old.ended_at then
    new.geofence_out := false;
  end if;
  return new;
end $$;
revoke all on function private.time_entry_geofence_guard() from public;
-- Named to run before place_guard and running_clock, which may end a clock that arrives late: the
-- mark goes by the clock as the phone sent it.
create trigger geofence_guard before insert or update on public.time_entries
  for each row execute function private.time_entry_geofence_guard();

notify pgrst, 'reload schema';
