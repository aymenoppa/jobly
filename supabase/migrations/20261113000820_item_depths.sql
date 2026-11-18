-- A price list item can carry its own depth. When a measurement fills a quote's quantities, every
-- formula that read depth_in got the same depth, so a quote with 2 inches of asphalt over 6 inches
-- of stone priced the stone at 2 inches. Each line that uses a depth now gets its own: the one
-- confirmed for it when the measurement is applied, starting from its item's default here
-- (apps/api/src/services/measurements.ts lineDepth).
--
--   services.default_depth_in   the depth, in inches, an item's formula starts with (6 for a stone
--                               base, 2 for a hot-mix surface). Null: the depth given for the whole
--                               quote, or the drawing's, as before.
-- supabase/tests/item_depths_test.sql covers it.

alter table public.services add column default_depth_in numeric(5, 2) check (default_depth_in > 0 and default_depth_in <= 48);
comment on column public.services.default_depth_in is 'The depth, in inches, this item''s formula starts with when a measurement fills a quote (depth_in). Null: the quote''s or the drawing''s.';

notify pgrst, 'reload schema';
