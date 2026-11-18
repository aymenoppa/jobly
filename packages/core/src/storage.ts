/**
 * Settings → Storage: how much room this Jobly's photos and files may take, and who's using it
 * (supabase/migrations/20261028000400_storage_limits.sql, GET /api/storage).
 *
 * A company limit, set by owners and admins, defaults to a bit under what Railway allows
 * (defaultStorageLimit); owners can also give a person, or everyone with a role, their own limit.
 * The server checks each upload before anything is stored (apps/api/src/lib/storageLimits.ts):
 *  - the company limit refuses uploads into Drive and plan files, guides, résumés, chat and
 *    equipment photos (and any folder not listed below);
 *  - a person's limit refuses only Drive and plan files and guides (PERSON_LIMITED_FOLDERS);
 *  - nothing a crew needs to finish a job is ever refused (STORAGE_FIELD_FOLDERS), though it counts;
 *  - owners are never limited by a personal limit, and server work, public forms and one-time
 *    upload links never are.
 * On Railway an owner can set the company limit as what files may cost a month instead
 * (storageLimitFromDollars). Videos added to Drive and plan files have their own rules (who may add
 * them, and how big each may be: videoRefusal), checked at the same place, on Railway or not.
 * Sizes are in decimal units throughout (1 GB is 1,000,000,000 bytes), as Railway counts them and
 * as Settings → Hosting shows them.
 */
import { STORAGE_PRICES, type RailwayPlan, type StorageBackend } from "./hosting";
import type { Role } from "./roles";

/**
 * Folders (a stored path's second part, <company>/<folder>/...) whose uploads no limit ever
 * refuses, so crews can always finish a job: visit and quote photos, sub paperwork, ticket photos,
 * receipts, measurement pictures, and what the server stores itself (profile photos, the logo,
 * letterheads, package and price-list pictures). They still count toward the totals.
 */
export const STORAGE_FIELD_FOLDERS = ["visit", "quote", "subs", "tickets", "receipts", "measurements", "avatars", "logo", "letterhead", "packages", "services"] as const;

/** Folders a person's own limit (or their role's) refuses: Drive and plan files, and guides. */
export const PERSON_LIMITED_FOLDERS = ["plans", "kb"] as const;

/** Which limits can refuse an upload into a folder. */
export interface StorageFolderRule {
  /** The company limit. */
  company: boolean;
  /** A person's own limit, or their role's. */
  person: boolean;
}

/** Which limits can refuse an upload into `folder` (a stored path's second part). */
export function storageFolderRule(folder: string): StorageFolderRule {
  if ((STORAGE_FIELD_FOLDERS as readonly string[]).includes(folder)) return { company: false, person: false };
  return { company: true, person: (PERSON_LIMITED_FOLDERS as readonly string[]).includes(folder) };
}

/** Warn owners and admins when the company's files reach these shares of its limit. */
export const STORAGE_WARN_AT = [0.8, 0.95] as const;

/** What the server answers an upload a limit refuses: HTTP 507, with one of the sentences below as `message`. */
export const STORAGE_FULL = { status: 507, error: "Storage full" } as const;

const UNITS = ["KB", "MB", "GB", "TB", "PB"] as const;

/**
 * A size for people: "45 GB", "812 MB", "12.4 GB", "3.4 KB", "1 TB". Decimal units, like Railway
 * and Settings → Hosting: a GB is 1,000,000,000 bytes. One decimal under 100, none above.
 */
export function formatBytes(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes <= 0) return "0 bytes";
  if (bytes < 1000) return `${Math.round(bytes)} byte${Math.round(bytes) === 1 ? "" : "s"}`;
  let value = bytes / 1000;
  let unit = 0;
  for (;;) {
    const shown = value < 100 ? Math.round(value * 10) / 10 : Math.round(value);
    // 999.96 MB rounds to 1000 MB: say 1 GB instead.
    if (shown >= 1000 && unit < UNITS.length - 1) {
      value /= 1000;
      unit++;
      continue;
    }
    return `${shown} ${UNITS[unit]}`;
  }
}

/** A GB in bytes. */
export const GB = 1_000_000_000;

/**
 * What a Railway bucket may hold before the limit stops uploads, by plan: Hobby's 1 TB is shared by
 * the whole Railway workspace, so the default leaves room for the rest of it; Pro has no cap, so 1 TB
 * is a safety net (about $15 a month if it filled). The trial and Free plans hold far less.
 */
export const BUCKET_DEFAULTS: Record<RailwayPlan, { bytes: number; basis: string }> = {
  trial: { bytes: 45 * GB, basis: "Railway trial bucket" },
  free: { bytes: 9 * GB, basis: "Railway Free bucket" },
  hobby: { bytes: 900 * GB, basis: "Railway Hobby bucket" },
  pro: { bytes: 1000 * GB, basis: "Railway Pro bucket" },
};

/** On a volume, the default limit is this share of its size, so it never quite fills. */
export const VOLUME_SHARE = 0.9;

/**
 * The company limit when the owner hasn't set one, from where files live: 90% of the storage
 * service's volume, or what the Railway plan allows a bucket. Null (no default limit) when that's
 * not known: not on Railway, Railway not connected, or not read yet.
 */
export function defaultStorageLimit({ backend, volumeBytes, plan }: { backend: StorageBackend | null; volumeBytes: number | null; plan: RailwayPlan | null }): { bytes: number | null; basis: string | null } {
  if (backend === "volume" && volumeBytes && volumeBytes > 0) {
    return { bytes: Math.floor(volumeBytes * VOLUME_SHARE), basis: `${Math.round(VOLUME_SHARE * 100)}% of your ${formatBytes(volumeBytes)} volume` };
  }
  if (backend === "bucket" && plan) return { ...BUCKET_DEFAULTS[plan] };
  return { bytes: null, basis: null };
}

/** What Railway charges a month to keep a GB where files live (for the cost of a limit). */
export const storagePricePerGb = (backend: StorageBackend | null): number | null => (backend ? STORAGE_PRICES[backend] : null);

/** What keeping `bytes` costs a month at `pricePerGbMonth`, in dollars. */
export const storageMonthlyCost = (bytes: number, pricePerGbMonth: number) => (bytes / GB) * pricePerGbMonth;

/** An upload's size as said before "file": "This 2.4 MB file", "This 512-byte file". Null when it isn't known. */
const fileSize = (bytes: number | null | undefined): string | null => {
  if (bytes === null || bytes === undefined || !Number.isFinite(bytes) || bytes <= 0) return null;
  return bytes < 1000 ? `${Math.round(bytes)}-byte` : formatBytes(bytes);
};

const sentence = (text: string) => text.charAt(0).toUpperCase() + text.slice(1);

/**
 * The upload refused because it would take the company's files past its limit: `bytes` is the
 * upload's size (left out of the sentence when it isn't known), `used` and `limit` the company's.
 * Only ever said to someone on the company's team.
 */
export function companyStorageFull(used: number, limit: number, bytes?: number | null): string {
  const why = `${formatBytes(used)} of the ${formatBytes(limit)} storage limit is used. An owner or admin can raise it in Settings → Storage, or empty the Trash.`;
  const size = fileSize(bytes);
  return size ? `This ${size} file doesn't fit: ${why}` : sentence(why);
}

/** The upload refused because it would take the person past their own limit (or their role's): `used` of `limit`. */
export function personStorageFull(used: number, limit: number, bytes?: number | null): string {
  const why = `you've used ${formatBytes(used)} of your ${formatBytes(limit)}. Ask an owner to raise it, or move old files to the Trash.`;
  const size = fileSize(bytes);
  return size ? `This ${size} file doesn't fit in your storage: ${why}` : sentence(why);
}

/**
 * How a company limit is set: Railway's default (settings.storage.limit_bytes left out), none (null),
 * a size of its own (a number), or on Railway what files may cost a month (limit_dollars, which the
 * database turns into bytes at the price of where files are now: storageLimitFromDollars).
 */
export type StorageLimitMode = "default" | "none" | "custom" | "dollars";

// ---------------------------------------------------------------------------------------------
// A limit in dollars (Railway)
// ---------------------------------------------------------------------------------------------

/**
 * The most a monthly amount can buy where files are now, so a limit in dollars never runs past what
 * the place holds: on a volume, the same share of it as the default (VOLUME_SHARE), since a full
 * volume stops every upload, crews' photos too; in a Railway bucket, what the plan lets a bucket
 * hold (BUCKET_DEFAULTS), except on Pro, where buckets have no cap. Null for no cap, or when it
 * isn't known. Kept in settings.storage.cap_bytes by the server (storage_set_rate).
 */
export function storageCap({ backend, volumeBytes, plan }: { backend: StorageBackend | null; volumeBytes: number | null; plan: RailwayPlan | null }): number | null {
  if (backend === "volume") return volumeBytes && volumeBytes > 0 ? Math.floor(volumeBytes * VOLUME_SHARE) : null;
  if (backend === "bucket" && plan && plan !== "pro") return BUCKET_DEFAULTS[plan].bytes;
  return null;
}

/**
 * Whether storageCap's answer is known: the volume's size was read, or the plan a bucket is on (on
 * Pro, known to be no cap). When it isn't (one of Railway's answers didn't come), saving null as the
 * cap would lift a limit in dollars past the volume's room until the next good reading.
 */
export function storageCapKnown({ backend, volumeBytes, plan }: { backend: StorageBackend | null; volumeBytes: number | null; plan: RailwayPlan | null }): boolean {
  if (backend === "volume") return Boolean(volumeBytes && volumeBytes > 0);
  if (backend === "bucket") return plan !== null;
  return false;
}

/**
 * What a limit of `dollars` a month allows at `pricePerGbMonth`, no more than `cap`: the same
 * sum as private.storage_company_limit (supabase/migrations/20261118000200_storage_cost_limits.sql),
 * so the page says the size the server holds uploads to. When files move between the volume and a
 * bucket the dollars stay and the size follows.
 */
export function storageLimitFromDollars(dollars: number, pricePerGbMonth: number, cap: number | null = null): number {
  const bytes = Math.max(1, Math.floor((dollars / pricePerGbMonth) * GB));
  return cap !== null && cap > 0 ? Math.min(bytes, cap) : bytes;
}

/** The most a limit in dollars can be: far past anything Jobly stores ($1.5M a year in a bucket). */
export const MOST_DOLLARS = 100_000;

// ---------------------------------------------------------------------------------------------
// Photos and videos added to Drive and plan files (companies.settings.files)
// ---------------------------------------------------------------------------------------------

/** Folders the video rules apply to: Drive and plan files (Plans and files on clients' work, and Drive). */
export const FILE_RULE_FOLDERS = ["plans"] as const;

/** Who may add videos there: everyone on the team, or only the office (not crew leads or field crew). */
export type VideoUploaders = "everyone" | "office";

/** The levels that count as the office for videos: owners, admins, office staff and estimators. */
export const VIDEO_OFFICE_ROLES: readonly Role[] = ["owner", "admin", "office", "estimator"];

/** The sizes a video may be offered as (other files go up to the 200 MB every upload is held to). */
export const VIDEO_SIZE_CHOICES = [25, 50, 100, 200].map((mb) => mb * 1_000_000);

/**
 * companies.settings.files, as the app and the server read it:
 *  - shrink_photos: camera photos added to Drive and plan files are made smaller as they're added
 *    (2560 px on the long side); on unless an owner or admin turned it off. Plan sheets, PDFs and
 *    screenshots are never changed.
 *  - videos: who may add videos there; video_max_bytes: how big each may be.
 */
export interface FileSettings {
  shrinkPhotos: boolean;
  videos: VideoUploaders;
  videoMaxBytes: number;
}

export const FILE_DEFAULTS: FileSettings = { shrinkPhotos: true, videos: "everyone", videoMaxBytes: 100_000_000 };

/** The biggest a video can be set to: the most any upload can be. */
const VIDEO_MOST_BYTES = 200_000_000;

/** A company's file settings from companies.settings (or settings.files itself), with the defaults for anything unset. */
export function fileSettings(settings: unknown): FileSettings {
  const all = settings && typeof settings === "object" && !Array.isArray(settings) ? (settings as Record<string, unknown>) : {};
  const own = all.files && typeof all.files === "object" && !Array.isArray(all.files) ? (all.files as Record<string, unknown>) : all;
  const max = Number(own.video_max_bytes);
  return {
    shrinkPhotos: own.shrink_photos !== false,
    videos: own.videos === "office" ? "office" : "everyone",
    videoMaxBytes: Number.isFinite(max) && max >= 1_000_000 ? Math.min(Math.floor(max), VIDEO_MOST_BYTES) : FILE_DEFAULTS.videoMaxBytes,
  };
}

/** Kinds of video phones and cameras save, by the name's ending, for a file whose type isn't said. */
const VIDEO_ENDINGS = /\.(mp4|m4v|mov|qt|webm|mkv|avi|wmv|mpe?g|3gp|3g2|mts|m2ts|hevc|ogv|flv)$/i;

/** A video, by its type or, when that's missing or generic, by its name's ending. */
export function isVideo({ contentType, name }: { contentType?: string | null; name?: string | null }): boolean {
  const type = (contentType ?? "").toLowerCase().split(";")[0]!.trim();
  if (type.startsWith("video/")) return true;
  return Boolean(name && VIDEO_ENDINGS.test(name.trim()));
}

/**
 * Why a video can't go into Drive and plan files for this person, or null when it can: `role` is
 * their access level, `bytes` the video's size (null when it doesn't say). The size applies to the
 * office too.
 */
export function videoRefusal(rules: Pick<FileSettings, "videos" | "videoMaxBytes">, role: string | null, bytes: number | null): string | null {
  if (rules.videos === "office" && !(VIDEO_OFFICE_ROLES as readonly string[]).includes(role ?? "")) {
    return "Only the office can add videos to Drive and plan files here. Add photos instead, or ask the office to add the video.";
  }
  if (bytes !== null && bytes > rules.videoMaxBytes) {
    return `This ${formatBytes(bytes)} video is over the ${formatBytes(rules.videoMaxBytes)} limit for videos in Drive and plan files. Trim it or send a shorter clip. An owner or admin can change the limit in Settings → Storage.`;
  }
  return null;
}

/** Whether a refusal's sentence is one of videoRefusal's (said as a 507, like a full storage, so the app shows it as it is). */
export const isVideoRefusal = (message: string) => /^(Only the office can add videos|This .+ video is over the .+ limit for videos)/.test(message);
