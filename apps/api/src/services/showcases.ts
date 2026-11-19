/**
 * Job showcases, the parts that run without anyone asking (routes/showcases.ts is the rest).
 *
 * A showcase's photos are served from copies made for its page. When a showcase is taken down,
 * unpublished or deleted, or its job or client is, the database gives the copies up and lists them
 * in stale_public_files (20261113001580_showcases_come_down.sql); here their stored files are
 * deleted, daily, by the plans task. They were never served once given up.
 */
import type { Db } from "../lib/supabase";

/** Deletes the stored copies the database has listed as no longer shown. Says how many. */
export async function tidyShowcaseCopies(admin: Db): Promise<number> {
  let removed = 0;
  for (let round = 0; round < 20; round++) {
    const { data, error } = await admin.from("stale_public_files").select("id, path").order("id").limit(100);
    if (error) throw new Error(error.message);
    if (!data?.length) break;
    // Every copy has its own random name, so a listed one isn't in use; checked all the same, so a
    // photo on a page is never deleted from under it.
    const { data: shown } = await admin.from("showcase_photos").select("public_path").in("public_path", data.map((r) => r.path));
    const inUse = new Set((shown ?? []).map((r) => r.public_path));
    const paths = data.map((r) => r.path).filter((path) => !inUse.has(path));
    if (paths.length) {
      const { error: gone } = await admin.storage.from("files").remove(paths);
      if (gone) throw new Error(gone.message);
    }
    const { error: cleared } = await admin.from("stale_public_files").delete().in("id", data.map((r) => r.id));
    if (cleared) throw new Error(cleared.message);
    removed += paths.length;
    if (data.length < 100) break;
  }
  return removed;
}
