-- The marks drawn on a photo, kept beside it so drawing again starts from the photo as taken.
--
-- A photo that's drawn on keeps the original and a flattened copy (attachments.marked_path;
-- 20261113001010_marked_up_photos.sql). Drawing on it again used to open that copy and save a new
-- JPEG of it, so the earlier marks could no longer be undone and the picture lost a little each
-- time. Now the marks themselves are kept on the photo's row:
--
--   attachments.marks   { "v": 1, "for": <the drawing's path>, "width", "height", "marks": [...] }
--                       What was drawn (pen strokes, arrows, circles, boxes, words), in the pixels
--                       of the picture they were drawn on, and which drawing they made. Null when
--                       nobody has drawn on the photo, or the drawing is from before this.
--
-- The app draws again from the original plus these marks only when "for" names the drawing the
-- photo shows now (marked_path). So nothing has to keep the two in step: an app from before this
-- that draws on the photo again, or takes the drawing off, changes marked_path and leaves marks
-- as they were, and those stale marks are simply not used (the app then opens the drawing itself,
-- as before). Who can write the column is who can change the photo's row, as with marked_path.

alter table public.attachments add column marks jsonb;
comment on column public.attachments.marks is
  'The marks drawn on the photo and the drawing they made ("for" = marked_path); used to draw again from the original';

-- An object, and not a file's worth of it: the app keeps no marks at all past about 200 KB.
alter table public.attachments add constraint attachments_marks_check
  check (marks is null or (jsonb_typeof(marks) = 'object' and octet_length(marks::text) <= 400000));
