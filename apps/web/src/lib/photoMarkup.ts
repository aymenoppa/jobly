/**
 * Photos drawn on (the photo editor, components/PhotoEditor.tsx), as they're stored: the photo as
 * taken stays where it is, and the drawing is a copy beside it in the same folder (so exactly the
 * people who can see the photo can see it), named on the photo's row (attachments.marked_path;
 * supabase/migrations/20261113001010_marked_up_photos.sql). Screens show the drawing, with a way to
 * see the original. Removing the photo removes both; the database sees to that.
 *
 * A photo drawn on as it's added to a visit goes through the phone's queue with its drawing
 * (lib/offlinePhotos.ts), so it works with no signal. Drawing on one that's already up needs signal.
 *
 * The marks themselves are kept on the row too (attachments.marks, named for the drawing they
 * made), so drawing again starts from the photo as taken with the earlier marks on it, rather
 * than from the flattened drawing (20261113001500_photo_marks.sql; core packMarks, unpackMarks).
 */
import { unpackMarks, type SavedMarks } from "@jobly/core/photoMarkup";
import { supabase, unwrap } from "./api";
import { signedUrls, uploadOnce } from "./files";
import { msg } from "./i18n";
import { t } from "@/lib/i18n";

/** A photo's row, as far as its drawing goes. */
export interface MarkablePhoto {
  id: string;
  path: string;
  marked_path?: string | null;
}

/** Where a photo's drawing is stored: in the photo's own folder, under a name of its own. */
export function markedPathFor(path: string): string {
  return `${path.slice(0, path.lastIndexOf("/") + 1)}${crypto.randomUUID()}.jpg`;
}

/** The file a photo shows: its drawing when it has one, else the photo as taken. */
export const shownPath = (photo: Pick<MarkablePhoto, "path" | "marked_path">) => photo.marked_path || photo.path;

/** Every file these photos show or can show (each one's original and drawing), for one round of signed links. */
export const photoPaths = (photos: ReadonlyArray<Pick<MarkablePhoto, "path" | "marked_path">>) => [...new Set(photos.flatMap((p) => (p.marked_path ? [p.path, p.marked_path] : [p.path])))];

/** Links to a set of photos: the one shown (the drawing, if any) and the original. Unavailable files are null. */
export async function photoLinks<P extends Pick<MarkablePhoto, "path" | "marked_path">>(photos: readonly P[]): Promise<Array<P & { url: string | null; originalUrl: string | null }>> {
  const urls = await signedUrls(photoPaths(photos)).catch(() => ({}) as Record<string, string>);
  return photos.map((p) => ({ ...p, url: urls[shownPath(p)] ?? urls[p.path] ?? null, originalUrl: urls[p.path] ?? null }));
}

/** A stored photo's picture, to draw on: read as the person, under the files bucket's rules. */
export async function photoPicture(path: string): Promise<Blob> {
  const { data, error } = await supabase().storage.from("files").download(path);
  if (error || !data) throw new Error(msg("This photo couldn't be opened. Check your signal and try again."));
  return data;
}

/**
 * What the editor opens for a stored photo. One drawn on with its marks kept (and still the marks
 * of the drawing it shows): the photo as taken, with those marks. Else what the photo shows: the
 * photo itself, or a drawing from before marks were kept (or drawn again by an older app), which
 * can only be added to.
 */
export async function photoToDrawOn(photo: MarkablePhoto): Promise<{ picture: Blob; original: boolean; marks?: { saved: unknown; path: string } }> {
  if (photo.marked_path) {
    // The row as it is now: the list on screen may be a moment old.
    const row = await supabase().from("attachments").select("path, marked_path, marks").eq("id", photo.id).limit(1).then((r) => (r.error ? null : r.data?.[0]), () => null);
    // Any size does to tell whether they can be used; the editor fits them to the picture it opens.
    if (row?.marked_path && unpackMarks(row.marks, row.marked_path, { width: 1, height: 1 })) {
      return { picture: await photoPicture(row.path), original: true, marks: { saved: row.marks, path: row.marked_path } };
    }
    return { picture: await photoPicture(row?.marked_path ?? photo.marked_path), original: false };
  }
  return { picture: await photoPicture(photo.path), original: true };
}

/**
 * Saves a drawing on a photo that's already up: the picture beside it, then the row pointing at
 * it (the old drawing, if any, goes to the Trash). A picture the row then can't take (someone else's
 * photo) is taken back off.
 */
export async function saveMarkup(photo: Pick<MarkablePhoto, "id" | "path">, picture: Blob, marksFor?: (path: string) => SavedMarks | null): Promise<string> {
  const path = markedPathFor(photo.path);
  await uploadOnce(path, picture);
  try {
    // With the marks that made it (or none, so marks from an earlier drawing never outlive it).
    const rows = unwrap(await supabase().from("attachments").update({ marked_path: path, marks: (marksFor?.(path) ?? null) as never }).eq("id", photo.id).select("id"));
    if (!rows.length) throw new Error(t("You can draw on photos you added. Ask the office to draw on this one."));
  } catch (error) {
    await supabase().storage.from("files").remove([path]).catch(() => undefined);
    throw error;
  }
  return path;
}

/** Takes the drawing off a photo: the original shows again, and the drawing goes to the Trash. */
export async function removeMarkup(photo: Pick<MarkablePhoto, "id">): Promise<void> {
  const rows = unwrap(await supabase().from("attachments").update({ marked_path: null, marks: null }).eq("id", photo.id).select("id"));
  if (!rows.length) throw new Error(t("You can change photos you added. Ask the office to change this one."));
}
