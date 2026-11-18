-- A receipt dropped in while reading is off waits to be filled in. It isn't a failure.
--
-- The several-at-once drop zone is there for every company, reading on or not. Off, each dropped
-- file was sent to be read anyway, refused, and listed as "Couldn't be read" with "Read again", as
-- if something had gone wrong.
--
--   expense_drafts.status = 'to_fill'   not read, because reading is off: to fill in by hand. The
--                                       web app adds it that way without asking the server, and the
--                                       server marks one that way if it's asked while reading is off.
--
-- An app from before this lists such a draft with nothing under its name, and opens it to fill in.
-- supabase/tests/receipt_reading_test.sql covers it.

alter table public.expense_drafts drop constraint expense_drafts_status_check;
alter table public.expense_drafts add constraint expense_drafts_status_check check (status in ('reading', 'read', 'failed', 'to_fill'));
comment on column public.expense_drafts.status is 'reading: sent to be read. read: read, with what was found in `read`. failed: it couldn''t be (`error` says why). to_fill: not read because reading is off; to fill in by hand.';
