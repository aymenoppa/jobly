/**
 * Plans and files: plan sets, specs, permits and addenda on quotes, jobs and properties, and the
 * company's own files in Drive's folders (public.plan_files; supabase/migrations/
 * 20261019001700_plan_files.sql and 20261028000300_drive.sql explain the rules). Files go to the
 * private files bucket at <company>/plans/<uuid>.<ext>, as they are, since a plan sheet has to stay
 * readable: only a camera's big photo is made smaller first (pictures.ts, which a company can turn
 * off). A picture added from the browser also gets a small preview copy next to it
 * (<uuid>.preview.webp, plan_files.preview_path; 20261118000100_plan_previews.sql) for the lists to
 * show. Deleting one moves it to the Trash (features/drive/trash.ts); only the server deletes stored
 * files, 30 days later, a file's copy with it.
 */
import type { Database } from "@jobly/core/database";
import { extensionFor } from "@jobly/core/drive";
import { keepPreviousData, useQuery } from "@tanstack/react-query";
import { ApiError, loadConfig, supabase } from "@/lib/api";
import { friendlyDbError } from "@/lib/errors";
import { formatDate } from "@/lib/format";
import { resumableUpload, sendWhole, TooLargeError, type Upload } from "@/lib/resumable";

export { isAbort, TooLargeError, type Upload } from "@/lib/resumable";

export interface PlanFile {
  id: string;
  company_id: string;
  property_id: string | null;
  request_id: string | null;
  quote_id: string | null;
  job_id: string | null;
  /** The company folder it's in (Drive), if any: the company's root folder is "Company files". */
  folder_id: string | null;
  title: string;
  revision: string | null;
  notes: string | null;
  path: string;
  /** A picture's small copy for the lists, stored next to it; null for any other file, and pictures from before or added by the server. */
  preview_path: string | null;
  file_name: string;
  content_type: string | null;
  size_bytes: number | null;
  crew_visible: boolean;
  archived: boolean;
  replaces_id: string | null;
  superseded_at: string | null;
  created_by: string | null;
  created_at: string;
  /** Always null here: files in the Trash are hidden from every list (drive_trash lists them). */
  deleted_at: string | null;
}
export const PLAN_FIELDS =
  "id, company_id, property_id, request_id, quote_id, job_id, folder_id, title, revision, notes, path, preview_path, file_name, content_type, size_bytes, crew_visible, archived, replaces_id, superseded_at, created_by, created_at, deleted_at";

/** Plan sets run big. The server's own limit (FILE_SIZE_LIMIT on the storage service) may be lower. */
export const PLAN_MAX_BYTES = 200 * 1024 * 1024;
export const PLAN_LIMIT_DOCS = "https://jobly.com/docs/jobs/plans-and-files/#large-files";

export const isPdf = (f: Pick<PlanFile, "content_type" | "file_name">) => f.content_type === "application/pdf" || /\.pdf$/i.test(f.file_name);
export const isImage = (f: Pick<PlanFile, "content_type" | "file_name">) => Boolean(f.content_type?.startsWith("image/")) || /\.(png|jpe?g|webp|gif)$/i.test(f.file_name);
/** PDFs and pictures can go on the Measure map. */
export const canMap = (f: Pick<PlanFile, "content_type" | "file_name">) => isPdf(f) || (isImage(f) && !/\.(heic|heif|tiff?)$/i.test(f.file_name));

/**
 * A picture with no small copy (from before copies, or added by the server) loads whole for its
 * preview: bigger ones keep the icon on the list.
 */
export const PREVIEW_MAX_BYTES = 10 * 1024 * 1024;
/** Kinds of picture every browser shows (not HEIC, TIFF, Photoshop or a camera's raw files), by type and by name. */
const SHOWN_TYPE = /^image\/(jpeg|pjpeg|png|gif|webp|avif|bmp|svg\+xml)$/i;
const SHOWN_NAME = /\.(jpe?g|png|gif|webp|avif|bmp|svg)$/i;
/** A picture with no copy to show small on the list: one any browser can show, and not so big it slows the list down. */
export const canPreview = (f: Pick<PlanFile, "content_type" | "file_name" | "size_bytes">) =>
  (f.content_type && f.content_type !== "application/octet-stream" ? SHOWN_TYPE.test(f.content_type) : SHOWN_NAME.test(f.file_name)) && (f.size_bytes ?? 0) <= PREVIEW_MAX_BYTES;
/** The device asks sites to use less data (Android's Data Saver, say): previews don't load then. */
export const savesData = () => typeof navigator !== "undefined" && (navigator as Navigator & { connection?: { saveData?: boolean } }).connection?.saveData === true;

/** "C-101 Site Plan rev B.pdf" -> "C-101 Site Plan rev B". */
export function titleFromFileName(name: string): string {
  const base = name.replace(/\.[a-z0-9]{1,8}$/i, "").replace(/[_]+/g, " ").replace(/\s+/g, " ").trim();
  return (base || "Plan").slice(0, 200);
}

export function fileSize(bytes: number | null | undefined): string {
  if (bytes == null) return "";
  if (bytes < 1024 * 1024) return `${Math.max(1, Math.round(bytes / 1024))} KB`;
  const mb = bytes / (1024 * 1024);
  return `${mb < 10 ? mb.toFixed(1) : Math.round(mb)} MB`;
}

/** What kind of file, in a word or two. */
export function fileKind(f: Pick<PlanFile, "content_type" | "file_name">): string {
  if (isPdf(f)) return "PDF";
  if (isImage(f)) return "Picture";
  const ext = f.file_name.match(/\.([a-z0-9]{1,8})$/i)?.[1];
  return ext ? ext.toUpperCase() : "File";
}

// ---------------------------------------------------------------------------------------------
// Versions
// ---------------------------------------------------------------------------------------------

export interface PlanEntry {
  /** The current version. */
  file: PlanFile;
  /** Older versions, newest first (only the office can see them). */
  older: PlanFile[];
  /** 1 for a file with no earlier versions. */
  version: number;
  /** It has older versions this person can't see (crews only get the current one). */
  hiddenHistory: boolean;
}

/** Each current file with its history, newest first. */
export function planEntries(rows: PlanFile[]): PlanEntry[] {
  const byId = new Map(rows.map((r) => [r.id, r]));
  return rows
    .filter((r) => !r.superseded_at)
    .map((file) => {
      const older: PlanFile[] = [];
      const seen = new Set([file.id]);
      for (let prev = file.replaces_id ? byId.get(file.replaces_id) : undefined; prev && !seen.has(prev.id); prev = prev.replaces_id ? byId.get(prev.replaces_id) : undefined) {
        older.push(prev);
        seen.add(prev.id);
      }
      return { file, older, version: older.length + 1, hiddenHistory: Boolean(file.replaces_id) && !older.length };
    })
    .sort((a, b) => b.file.created_at.localeCompare(a.file.created_at));
}

/** "Version 2 · Rev B · 12 MB · PDF · Oct 19", or "Rev B · 12 MB · PDF · updated Oct 19" for a crew. */
export function planMeta(entry: PlanEntry): string {
  const f = entry.file;
  const when = entry.hiddenHistory || entry.version > 1 ? `updated ${formatDate(f.created_at)}` : formatDate(f.created_at);
  return [entry.version > 1 && `Version ${entry.version}`, f.revision?.trim(), fileSize(f.size_bytes), fileKind(f), when].filter(Boolean).join(" · ");
}

// ---------------------------------------------------------------------------------------------
// Links
// ---------------------------------------------------------------------------------------------

/** How long a link works, and how long one is used again: for 50 of its 60 minutes. */
const LINK_SECONDS = 3600;
const LINK_REUSE_MS = 50 * 60_000;

type SignedLink = { open: string; save: string; until: number };
/** Links made already, by storage path (each has its company's id in it). */
const signed = new Map<string, SignedLink>();

/**
 * Links that open each file in the browser for an hour, and links that save it with its own name.
 * A file keeps the link it was given while that has ten minutes or more left, wherever it's listed
 * next: a new link is a new address, so a picture shown from it (a preview) would download again,
 * and a list changes often (each file of an upload, each search). `sign` makes the links for the
 * paths that need new ones; `now` is for tests.
 */
export async function planLinks(
  files: Array<Pick<PlanFile, "path" | "file_name">>,
  sign: (paths: string[]) => Promise<Array<{ path: string | null; signedUrl: string | null }>>,
  now = Date.now(),
): Promise<{ open: Record<string, string>; save: Record<string, string>; until: number }> {
  const valid = (path: string) => {
    const link = signed.get(path);
    return link && link.until > now ? link : null;
  };
  const names = new Map(files.map((f) => [f.path, f.file_name]));
  const missing = [...names.keys()].filter((path) => !valid(path));
  if (missing.length) {
    for (const d of await sign(missing)) {
      if (!d.signedUrl || !d.path) continue;
      const save = `${d.signedUrl}${d.signedUrl.includes("?") ? "&" : "?"}download=${encodeURIComponent(names.get(d.path) ?? "plan")}`;
      signed.set(d.path, { open: d.signedUrl, save, until: now + LINK_REUSE_MS });
    }
  }
  const open: Record<string, string> = {};
  const save: Record<string, string> = {};
  // Good while the oldest link here is: a list can hold links made earlier for another list.
  let until = now + LINK_REUSE_MS;
  for (const path of names.keys()) {
    const link = valid(path);
    if (!link) continue;
    open[path] = link.open;
    save[path] = link.save;
    until = Math.min(until, link.until);
  }
  return { open, save, until };
}

export function usePlanLinks(files: Array<Pick<PlanFile, "path" | "file_name">>) {
  const list = [...new Map(files.map((f) => [f.path, f])).values()].sort((a, b) => a.path.localeCompare(b.path));
  return useQuery({
    queryKey: ["plan-links", list.map((f) => f.path)],
    enabled: list.length > 0,
    // Made again once the oldest link here is down to its last ten minutes, on the screen or not:
    // a link can be older than the list (made for another one), so a set time from now won't do.
    staleTime: (query) => Math.max(0, (query.state.data?.until ?? 0) - Date.now()),
    refetchInterval: (query) => (query.state.data ? Math.max(1_000, query.state.data.until - Date.now()) : false),
    // The links it had while the list's new ones come, so previews don't blink back to icons.
    placeholderData: keepPreviousData,
    meta: { silent: true },
    queryFn: () =>
      planLinks(list, async (paths) => {
        const { data, error } = await supabase().storage.from("files").createSignedUrls(paths, LINK_SECONDS);
        if (error) throw new Error(error.message);
        return data ?? [];
      }),
  });
}

export async function planLink(path: string, seconds = 3600): Promise<string> {
  const { data, error } = await supabase().storage.from("files").createSignedUrl(path, seconds);
  if (error || !data?.signedUrl) throw new Error(error?.message ?? "Couldn't open that file.");
  return data.signedUrl;
}

// ---------------------------------------------------------------------------------------------
// Uploading
// ---------------------------------------------------------------------------------------------

/** A file's type from its name, for one made here without a type (an edited PDF or Word document). */
const typeFromName = (name: string) =>
  /\.pdf$/i.test(name) ? "application/pdf" : /\.docx$/i.test(name) ? "application/vnd.openxmlformats-officedocument.wordprocessingml.document" : null;

const refused = (error: unknown): Upload => {
  const promise = Promise.reject(error);
  promise.catch(() => undefined); // the caller hears of it when it waits for the upload
  return { promise, abort: () => undefined };
};

/** Over 200 MB, or empty: never sent. */
function unsendable(size: number, name: string): Error | null {
  if (size > PLAN_MAX_BYTES) return new TooLargeError(`${name} is larger than ${fileSize(PLAN_MAX_BYTES)}.`);
  if (size === 0) return new Error(`${name} is empty.`);
  return null;
}

/**
 * Sends a file to <company>/plans/ as it is, reporting progress (0 to 1). Resolves with its storage
 * path. In 6 MB pieces that carry on after a dropped connection (lib/resumable.ts), so plan sets
 * bigger than a proxy takes in one request get through. Storage's own limit (FILE_SIZE_LIMIT) still
 * applies.
 */
export function uploadPlanFile(companyId: string, file: File, onProgress: (fraction: number) => void): Upload {
  const problem = unsendable(file.size, file.name);
  if (problem) return refused(problem);
  const path = `${companyId}/plans/${crypto.randomUUID()}.${extensionFor(file.name, file.type)}`;
  return resumableUpload({ path, file, contentType: file.type || "application/octet-stream", onProgress });
}

/**
 * Where a picture's preview copy goes: next to its file, <company>/plans/<uuid>.preview.webp (or .jpg),
 * the only name the database lets its row give it (plan_files_preview_path).
 */
export const previewPathFor = (path: string, type: string) => path.replace(/\.[a-z0-9]{1,8}$/, type === "image/webp" ? ".preview.webp" : ".preview.jpg");

/** How long the copy may take to go up once its file has: the file's row waits for it. */
const PREVIEW_UPLOAD_MS = 20_000;

/**
 * Stores a picture's preview copy (pictures.ts makes it) next to the file now stored at `path`, and
 * says where, for the file's row. Null when there's no copy or it didn't go up in time: the file is
 * added without one and its list shows it as before. A copy that goes up late, with no row naming
 * it, is tidied away by the server a day later.
 */
export async function storePreview(path: string, copy: Promise<Blob | null>): Promise<string | null> {
  try {
    const blob = await copy;
    if (!blob || (blob.type !== "image/webp" && blob.type !== "image/jpeg")) return null;
    const previewPath = previewPathFor(path, blob.type);
    const sent = supabase().storage.from("files").upload(previewPath, blob, { contentType: blob.type, upsert: false }).then(({ error }) => !error);
    const late = new Promise<boolean>((resolve) => setTimeout(() => resolve(false), PREVIEW_UPLOAD_MS));
    return (await Promise.race([sent, late])) ? previewPath : null;
  } catch {
    return null;
  }
}

type PlanRow = Database["public"]["Tables"]["plan_files"]["Insert"];

/**
 * Adds a stored file's row, with its preview copy when it has one. A copy the database turns away
 * never keeps the file out: it's added again without it.
 */
export async function recordPlanFile(row: Omit<PlanRow, "preview_path">, previewPath: string | null) {
  // Without the copy, the column isn't sent at all: a server that doesn't know it yet takes the row.
  const insert = (preview: string | null) => {
    const body: PlanRow = preview ? { ...row, preview_path: preview } : row;
    return supabase().from("plan_files").insert(body).select(PLAN_FIELDS).single();
  };
  const first = await insert(previewPath);
  if (first.error && previewPath && /preview/.test(first.error.message)) return insert(null);
  return first;
}

/**
 * The file a new version replaces: a whole row, or what Drive's list has of one. Where it is that
 * isn't given, the new version takes from the old one in the database (private.plan_files_fill).
 */
export type VersionOf = Pick<PlanFile, "id" | "title" | "crew_visible"> &
  Partial<Pick<PlanFile, "content_type" | "property_id" | "request_id" | "quote_id" | "job_id" | "folder_id">>;

/**
 * Saves an edited file (a marked-up PDF, a Word document) as the newest version of `previous`: a
 * new stored file and a new row that replaces the old one, which stays in the file's history.
 * Nothing is overwritten. It keeps the file's name, who sees it, and where it is (its property,
 * request, quote or job, and its folder); the revision label starts empty.
 */
export async function addVersion(companyId: string, previous: VersionOf, blob: Blob, fileName: string, onProgress: (fraction: number) => void = () => undefined): Promise<PlanFile> {
  const problem = unsendable(blob.size, fileName);
  if (problem) throw problem;
  const contentType = blob.type || typeFromName(fileName) || previous.content_type || "application/octet-stream";
  const path = await resumableUpload({
    path: `${companyId}/plans/${crypto.randomUUID()}.${extensionFor(fileName, contentType)}`,
    file: blob,
    contentType,
    name: fileName,
    onProgress,
  }).promise;
  const { data, error } = await supabase()
    .from("plan_files")
    .insert({
      company_id: companyId,
      property_id: previous.property_id,
      request_id: previous.request_id,
      quote_id: previous.quote_id,
      job_id: previous.job_id,
      folder_id: previous.folder_id,
      replaces_id: previous.id,
      title: previous.title,
      revision: null,
      path,
      file_name: fileName.slice(0, 255),
      content_type: contentType.slice(0, 150),
      size_bytes: blob.size,
      crew_visible: previous.crew_visible,
    })
    .select(PLAN_FIELDS)
    .single();
  // The stored file stays behind on a refusal; the nightly tidy-up takes it away after a day.
  if (error) throw versionRefused(error);
  return data as unknown as PlanFile;
}

/** The database's own sentences ("A newer version of Site plan was already added…") as they are. */
function versionRefused(error: { message: string; code?: string; details?: string | null; hint?: string | null }): Error {
  if (/newer version|in the Trash/i.test(error.message)) return new ApiError(error.message, 409, error.code);
  return friendlyDbError(error);
}

/**
 * Sends a file on a one-time upload link (a booking form's files: the visitor isn't signed in).
 * Resolves with the path the link is for.
 */
export function uploadToLink(link: { path: string; token: string }, file: File, onProgress: (fraction: number) => void): Upload {
  const problem = unsendable(file.size, file.name);
  if (problem) return refused(problem);
  return sendWhole(file, file.type || "application/octet-stream", file.name, onProgress, async () => {
    const config = await loadConfig();
    const url = `${config.supabaseUrl}/storage/v1/object/upload/sign/files/${link.path}?token=${encodeURIComponent(link.token)}`;
    return { method: "PUT", url, headers: { apikey: config.supabaseKey }, path: link.path };
  });
}
