-- A stack of receipts larger than the hour's reading allowance waits and carries on.
--
-- Reading receipts shared the hourly allowance of every other AI feature (60 asks a person, 300 a
-- company). A bookkeeper dropping 80 receipts had the 61st and on marked "Couldn't be read", and
-- nobody at the company could have a reply rewritten or a quote drafted for the rest of the hour.
-- Reading now has an allowance of its own (apps/api/src/services/ai.ts allowReceiptRead), and a
-- draft past it isn't failed:
--
--   expense_drafts.status = 'waiting'   its turn hasn't come: the hour's readings are used up. The
--                                       page asks again every few minutes while it's open, and
--                                       reads it when there's room. It can be filled in by hand
--                                       meanwhile, like any draft.
--
-- An app from before this lists such a draft with nothing under its name, and opens it to fill in.
-- supabase/tests/receipt_reading_test.sql covers it.

alter table public.expense_drafts drop constraint expense_drafts_status_check;
alter table public.expense_drafts add constraint expense_drafts_status_check check (status in ('reading', 'read', 'failed', 'to_fill', 'waiting'));
comment on column public.expense_drafts.status is 'reading: sent to be read. read: read, with what was found in `read`. failed: it couldn''t be (`error` says why). to_fill: not read because reading is off; to fill in by hand. waiting: the hour''s reading allowance is used up; read when there''s room.';
