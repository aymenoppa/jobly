import { describe, expect, it } from "vitest";
import {
  BUCKET_DEFAULTS,
  companyStorageFull,
  defaultStorageLimit,
  FILE_DEFAULTS,
  FILE_RULE_FOLDERS,
  fileSettings,
  formatBytes,
  GB,
  isVideo,
  isVideoRefusal,
  storageCap,
  storageCapKnown,
  storageLimitFromDollars,
  videoRefusal,
  PERSON_LIMITED_FOLDERS,
  personStorageFull,
  STORAGE_FIELD_FOLDERS,
  STORAGE_WARN_AT,
  storageFolderRule,
  storageMonthlyCost,
  storagePricePerGb,
} from "../src/storage";

describe("sizes for people", () => {
  it("counts in decimal units, like Railway and Settings → Hosting", () => {
    expect(formatBytes(45 * GB)).toBe("45 GB");
    expect(formatBytes(812_000_000)).toBe("812 MB");
    expect(formatBytes(12_400_000_000)).toBe("12.4 GB");
    expect(formatBytes(3_400)).toBe("3.4 KB");
    expect(formatBytes(1000 * GB)).toBe("1 TB");
    expect(formatBytes(900 * GB)).toBe("900 GB");
  });

  it("shows one decimal under 100 and none above", () => {
    expect(formatBytes(3_141_592_653)).toBe("3.1 GB");
    expect(formatBytes(45_050_000_000)).toBe("45.1 GB");
    expect(formatBytes(123_456_789)).toBe("123 MB");
    expect(formatBytes(99_960_000)).toBe("100 MB");
  });

  it("moves up a unit rather than say 1000 of one", () => {
    expect(formatBytes(999_960_000)).toBe("1 GB");
    expect(formatBytes(999_960)).toBe("1 MB");
  });

  it("says bytes for tiny files, and nothing for nothing", () => {
    expect(formatBytes(1)).toBe("1 byte");
    expect(formatBytes(512)).toBe("512 bytes");
    expect(formatBytes(0)).toBe("0 bytes");
    expect(formatBytes(-5)).toBe("0 bytes");
    expect(formatBytes(Number.NaN)).toBe("0 bytes");
  });
});

describe("which limits refuse an upload", () => {
  it("never refuses what crews need to finish a job, or what the server stores", () => {
    for (const folder of ["visit", "quote", "subs", "tickets", "receipts", "measurements", "avatars", "logo", "letterhead", "packages", "services"]) {
      expect(storageFolderRule(folder), folder).toEqual({ company: false, person: false });
    }
    expect([...STORAGE_FIELD_FOLDERS].sort()).toEqual(["avatars", "letterhead", "logo", "measurements", "packages", "quote", "receipts", "services", "subs", "tickets", "visit"]);
  });

  it("refuses Drive and plan files and guides by the company's limit and a person's", () => {
    expect(storageFolderRule("plans")).toEqual({ company: true, person: true });
    expect(storageFolderRule("kb")).toEqual({ company: true, person: true });
    expect([...PERSON_LIMITED_FOLDERS]).toEqual(["plans", "kb"]);
  });

  it("refuses résumés, chat, equipment and anything new by the company's limit only", () => {
    for (const folder of ["applicants", "chat", "equipment", "something-new", ""]) {
      expect(storageFolderRule(folder), folder).toEqual({ company: true, person: false });
    }
  });
});

describe("the default company limit", () => {
  it("is 90% of the storage service's volume", () => {
    expect(defaultStorageLimit({ backend: "volume", volumeBytes: 50 * GB, plan: "hobby" })).toEqual({ bytes: 45 * GB, basis: "90% of your 50 GB volume" });
    expect(defaultStorageLimit({ backend: "volume", volumeBytes: 5 * GB, plan: "pro" })).toEqual({ bytes: 4.5 * GB, basis: "90% of your 5 GB volume" });
  });

  it("follows Railway's plan for a bucket", () => {
    expect(defaultStorageLimit({ backend: "bucket", volumeBytes: 50 * GB, plan: "hobby" })).toEqual({ bytes: 900 * GB, basis: "Railway Hobby bucket" });
    expect(defaultStorageLimit({ backend: "bucket", volumeBytes: null, plan: "pro" })).toEqual({ bytes: 1000 * GB, basis: "Railway Pro bucket" });
    expect(BUCKET_DEFAULTS.trial.bytes).toBeLessThan(BUCKET_DEFAULTS.hobby.bytes);
  });

  it("is none when where files live isn't known", () => {
    const none = { bytes: null, basis: null };
    expect(defaultStorageLimit({ backend: null, volumeBytes: 50 * GB, plan: "hobby" })).toEqual(none);
    expect(defaultStorageLimit({ backend: "volume", volumeBytes: null, plan: "hobby" })).toEqual(none);
    expect(defaultStorageLimit({ backend: "volume", volumeBytes: 0, plan: "hobby" })).toEqual(none);
    expect(defaultStorageLimit({ backend: "bucket", volumeBytes: 50 * GB, plan: null })).toEqual(none);
  });
});

describe("what a limit costs", () => {
  it("prices a GB-month at Railway's rates", () => {
    expect(storagePricePerGb("bucket")).toBe(0.015);
    expect(storagePricePerGb("volume")).toBe(0.15);
    expect(storagePricePerGb(null)).toBeNull();
    expect(storageMonthlyCost(1000 * GB, 0.015)).toBeCloseTo(15);
  });
});

describe("refusals and warnings", () => {
  it("says the file doesn't fit, how full it is, and who can fix it", () => {
    expect(companyStorageFull(44.9 * GB, 45 * GB, 240_000_000)).toBe(
      "This 240 MB file doesn't fit: 44.9 GB of the 45 GB storage limit is used. An owner or admin can raise it in Settings → Storage, or empty the Trash.",
    );
    expect(companyStorageFull(812_000_000, 1 * GB, 2_400_000)).toContain("812 MB of the 1 GB storage limit is used");
    expect(personStorageFull(9.9 * GB, 10 * GB, 300_000_000)).toBe(
      "This 300 MB file doesn't fit in your storage: you've used 9.9 GB of your 10 GB. Ask an owner to raise it, or move old files to the Trash.",
    );
  });

  it("leaves the file's size out when it isn't known", () => {
    expect(companyStorageFull(45 * GB, 45 * GB)).toBe("45 GB of the 45 GB storage limit is used. An owner or admin can raise it in Settings → Storage, or empty the Trash.");
    expect(companyStorageFull(45 * GB, 45 * GB, null)).toBe(companyStorageFull(45 * GB, 45 * GB));
    expect(personStorageFull(10 * GB, 10 * GB, 0)).toBe("You've used 10 GB of your 10 GB. Ask an owner to raise it, or move old files to the Trash.");
  });

  it("says a tiny file's size in bytes", () => {
    expect(companyStorageFull(45 * GB, 45 * GB, 512)).toMatch(/^This 512-byte file doesn't fit: /);
    expect(personStorageFull(10 * GB, 10 * GB, 1)).toMatch(/^This 1-byte file doesn't fit in your storage: /);
  });

  it("warns at 80% and 95%", () => {
    expect([...STORAGE_WARN_AT]).toEqual([0.8, 0.95]);
  });
});

describe("a limit in dollars", () => {
  it("is the size a monthly amount buys at the price of where files are now", () => {
    expect(storageLimitFromDollars(10, 0.015)).toBe(666_666_666_666);
    expect(storageLimitFromDollars(10, 0.15)).toBe(66_666_666_666);
    expect(storageLimitFromDollars(0.01, 0.15)).toBe(66_666_666);
  });

  it("never runs past what the place holds", () => {
    // On Hobby's 5 GB volume, no more than the default's 90%.
    const cap = storageCap({ backend: "volume", volumeBytes: 5 * GB, plan: "hobby" });
    expect(cap).toBe(4.5 * GB);
    expect(storageLimitFromDollars(10, 0.15, cap)).toBe(4.5 * GB);
    expect(storageLimitFromDollars(0.5, 0.15, cap)).toBe(3_333_333_333);
    // In a bucket, what the plan lets a bucket hold; Pro has no cap.
    expect(storageCap({ backend: "bucket", volumeBytes: null, plan: "hobby" })).toBe(900 * GB);
    expect(storageCap({ backend: "bucket", volumeBytes: null, plan: "pro" })).toBeNull();
    expect(storageCap({ backend: null, volumeBytes: null, plan: null })).toBeNull();
  });

  it("knows when the cap is known, so a lookup that failed doesn't lift it", () => {
    expect(storageCapKnown({ backend: "volume", volumeBytes: 5 * GB, plan: "hobby" })).toBe(true);
    expect(storageCapKnown({ backend: "volume", volumeBytes: null, plan: "hobby" })).toBe(false);
    expect(storageCapKnown({ backend: "bucket", volumeBytes: null, plan: "hobby" })).toBe(true);
    // Pro: known to have no cap.
    expect(storageCapKnown({ backend: "bucket", volumeBytes: null, plan: "pro" })).toBe(true);
    expect(storageCapKnown({ backend: "bucket", volumeBytes: null, plan: null })).toBe(false);
    expect(storageCapKnown({ backend: null, volumeBytes: 5 * GB, plan: "hobby" })).toBe(false);
  });
});

describe("photos and videos added to Drive and plan files", () => {
  it("shrinks photos and takes videos from everyone up to 100 MB until a company says otherwise", () => {
    expect(fileSettings({})).toEqual(FILE_DEFAULTS);
    expect(fileSettings(null)).toEqual({ shrinkPhotos: true, videos: "everyone", videoMaxBytes: 100_000_000 });
    expect(fileSettings({ files: { shrink_photos: false, videos: "office", video_max_bytes: 50_000_000 } })).toEqual({ shrinkPhotos: false, videos: "office", videoMaxBytes: 50_000_000 });
    // settings.files itself reads the same, and nonsense is the default.
    expect(fileSettings({ shrink_photos: "no", videos: "nobody", video_max_bytes: 9e12 })).toEqual({ shrinkPhotos: true, videos: "everyone", videoMaxBytes: 200_000_000 });
  });

  it("tells a video by its type, or by its name when the type says nothing", () => {
    expect(isVideo({ contentType: "video/mp4" })).toBe(true);
    expect(isVideo({ contentType: "VIDEO/QuickTime; codecs=hvc1" })).toBe(true);
    expect(isVideo({ contentType: "application/octet-stream", name: "co/plans/clip.MOV" })).toBe(true);
    expect(isVideo({ name: "walkthrough.webm" })).toBe(true);
    expect(isVideo({ contentType: "application/pdf", name: "plan.pdf" })).toBe(false);
    expect(isVideo({ contentType: "image/jpeg", name: "photo.jpg" })).toBe(false);
  });

  it("says why a video can't go in: only the office, or over the size", () => {
    const office = { videos: "office" as const, videoMaxBytes: 100_000_000 };
    expect(videoRefusal(office, "field_crew", 5_000_000)).toBe("Only the office can add videos to Drive and plan files here. Add photos instead, or ask the office to add the video.");
    expect(videoRefusal(office, "crew_lead", 5_000_000)).not.toBeNull();
    for (const role of ["owner", "admin", "office", "estimator"]) expect(videoRefusal(office, role, 5_000_000), role).toBeNull();
    expect(videoRefusal(FILE_DEFAULTS, "field_crew", 240_000_000)).toBe(
      "This 240 MB video is over the 100 MB limit for videos in Drive and plan files. Trim it or send a shorter clip. An owner or admin can change the limit in Settings → Storage.",
    );
    expect(videoRefusal(FILE_DEFAULTS, "owner", 100_000_000)).toBeNull();
    expect(FILE_RULE_FOLDERS).toEqual(["plans"]);
  });

  it("tells its sentences from a full storage's, since both come as a 507", () => {
    expect(isVideoRefusal(videoRefusal(FILE_DEFAULTS, "owner", 240_000_000)!)).toBe(true);
    expect(isVideoRefusal(videoRefusal({ ...FILE_DEFAULTS, videos: "office" }, null, 1)!)).toBe(true);
    expect(isVideoRefusal(companyStorageFull(44.9 * GB, 45 * GB, 240_000_000))).toBe(false);
    expect(isVideoRefusal(personStorageFull(9.9 * GB, 10 * GB, 240_000_000))).toBe(false);
  });
});
