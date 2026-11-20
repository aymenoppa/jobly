/**
 * Pictures added to Plans and files and Drive (features/plans/pictures.ts, exif.ts): which photos
 * are made smaller (only a camera's, and only big ones), that they come out the right way up with
 * their EXIF carried over, and which files get a preview copy, and where it's stored. The bytes here
 * are built by hand, laid out as a camera lays them out.
 */
import { describe, expect, it } from "vitest";
import { exifFor, findExif, readJpeg, readTiff, unturned, uprightSize, uprightTransform, withExif } from "../src/features/plans/exif";
import { previewCopies, previewable, previewLink } from "../src/features/plans/PlanPreview";
import { cameraPhoto, fitWithin, keepsShrunk, opens, OPEN_MAX_PIXELS, pictureKind, pixelSize, PREVIEW_MIN_BYTES, shrinkSize, shrinksPhotos, wantsPreview } from "../src/features/plans/pictures";
import { previewPathFor } from "../src/features/plans/plans";

interface Camera {
  make?: string;
  model?: string;
  orientation?: number;
  /** A shutter speed in the Exif IFD (a camera's); false for a scanner's. */
  exposure?: boolean;
  /** PixelXDimension and PixelYDimension, as SHORTs. */
  pixels?: [number, number];
}

const text = (s: string) => new TextEncoder().encode(s);

/** A TIFF block as a camera writes it: IFD0 (make, model, orientation, the Exif IFD), the Exif IFD, and IFD1 (the thumbnail). */
function tiff(le: boolean, c: Camera): Uint8Array {
  const strings = [c.make, c.model].filter((s): s is string => Boolean(s)).map((s) => text(`${s}\0`));
  const ifd0 = [c.make, c.model, c.orientation].filter((v) => v !== undefined).length + 1;
  const exif = (c.exposure === false ? 0 : 1) + (c.pixels ? 2 : 0);
  const at0 = 8;
  const atExif = at0 + 2 + ifd0 * 12 + 4;
  const at1 = atExif + 2 + exif * 12 + 4;
  let data = at1 + 2 + 12 + 4;
  const size = data + strings.reduce((n, s) => n + s.length, 0) + 8;
  const buf = new Uint8Array(size);
  const v = new DataView(buf.buffer);
  buf.set(le ? [0x49, 0x49, 0x2a, 0] : [0x4d, 0x4d, 0, 0x2a]);
  v.setUint32(4, at0, le);
  const entry = (at: number, tag: number, type: number, count: number, value: (at: number) => void) => {
    v.setUint16(at, tag, le);
    v.setUint16(at + 2, type, le);
    v.setUint32(at + 4, count, le);
    value(at + 8);
  };
  let e = at0 + 2;
  v.setUint16(at0, ifd0, le);
  let s = 0;
  for (const [tag, value] of [[0x010f, c.make], [0x0110, c.model]] as const) {
    if (!value) continue;
    const bytes = strings[s++]!;
    const where = data;
    entry(e, tag, 2, bytes.length, (at) => v.setUint32(at, where, le));
    buf.set(bytes, data);
    data += bytes.length;
    e += 12;
  }
  if (c.orientation !== undefined) {
    entry(e, 0x0112, 3, 1, (at) => v.setUint16(at, c.orientation!, le));
    e += 12;
  }
  entry(e, 0x8769, 4, 1, (at) => v.setUint32(at, atExif, le));
  e += 12;
  v.setUint32(e, at1, le); // IFD1, the thumbnail
  v.setUint16(atExif, exif, le);
  e = atExif + 2;
  if (c.exposure !== false) {
    const where = data;
    entry(e, 0x829a, 5, 1, (at) => v.setUint32(at, where, le));
    v.setUint32(data, 1, le);
    v.setUint32(data + 4, 120, le);
    data += 8;
    e += 12;
  }
  if (c.pixels) {
    entry(e, 0xa002, 3, 1, (at) => v.setUint16(at, c.pixels![0], le));
    entry(e + 12, 0xa003, 3, 1, (at) => v.setUint16(at, c.pixels![1], le));
    e += 24;
  }
  v.setUint32(e, 0, le);
  v.setUint16(at1, 1, le);
  entry(at1 + 2, 0x0103, 3, 1, (at) => v.setUint16(at, 6, le)); // compression: JPEG
  v.setUint32(at1 + 14, 0, le);
  return buf;
}

const be16 = (n: number) => [(n >> 8) & 0xff, n & 0xff];
const JFIF = [0xff, 0xe0, ...be16(16), ...text("JFIF\0"), 1, 1, 0, 0, 1, 0, 1, 0, 0];
const segment = (marker: number, body: Uint8Array | number[]) => [0xff, marker, ...be16(body.length + 2), ...body];
/** A frame header: 8 bits, `height` by `width`, three components. */
const sof = (width: number, height: number) => segment(0xc0, [8, ...be16(height), ...be16(width), 3, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1]);
const SCAN = [...segment(0xda, [3, 1, 0, 2, 0x11, 3, 0x11, 0, 0x3f, 0]), 0x12, 0x34, 0xff, 0xd9];

/** A JPEG as a phone saves it: JFIF, EXIF, the frame header, then the picture. */
function jpeg(width: number, height: number, camera: Camera | null, le = false): Uint8Array {
  const exif = camera ? segment(0xe1, [...text("Exif\0\0"), ...tiff(le, camera)]) : [];
  return new Uint8Array([0xff, 0xd8, ...JFIF, ...exif, ...sof(width, height), ...SCAN]);
}

const PHONE: Camera = { make: "Apple", model: "iPhone 15", orientation: 6, pixels: [4032, 3024] };

describe("reading a photo's EXIF", () => {
  it("reads a phone's photo, either byte order", () => {
    for (const le of [false, true]) {
      const info = readJpeg(jpeg(4032, 3024, PHONE, le))!;
      expect(info.width).toBe(4032);
      expect(info.height).toBe(3024);
      expect(info.exif).toMatchObject({ make: "Apple", model: "iPhone 15", orientation: 6, exposure: true, littleEndian: le });
      expect(cameraPhoto(info.exif)).toBe(true);
    }
  });

  it("tells a camera's photo from a scan, a screenshot or a drawing", () => {
    // A scanner names itself, but took no exposure.
    expect(cameraPhoto(readJpeg(jpeg(5100, 6600, { make: "EPSON", model: "Perfection V600", exposure: false }))!.exif)).toBe(false);
    expect(cameraPhoto(readJpeg(jpeg(2048, 1536, { orientation: 1 }))!.exif)).toBe(false);
    expect(cameraPhoto(readJpeg(jpeg(1170, 2532, null))!.exif)).toBe(false);
    expect(cameraPhoto(readJpeg(jpeg(4000, 3000, { model: "SM-S918B" }))!.exif)).toBe(true);
    expect(cameraPhoto(null)).toBe(false);
  });

  it("gives up quietly on what isn't a JPEG or a TIFF block", () => {
    expect(readJpeg(text("%PDF-1.7 not a picture"))).toBeNull();
    expect(readJpeg(new Uint8Array([0xff, 0xd8]))).toBeNull();
    // Cut off in the middle of its EXIF: the size is unknown, and it's not a camera's photo.
    const cut = jpeg(4032, 3024, PHONE).slice(0, 60);
    expect(() => readJpeg(cut)).not.toThrow();
    expect(cameraPhoto(readJpeg(cut)?.exif ?? null)).toBe(false);
    // IFD0 said to be past the end.
    const bad = tiff(true, PHONE);
    new DataView(bad.buffer).setUint32(4, 1_000_000, true);
    expect(readTiff(bad, 0)).toBeNull();
  });

  it("finds EXIF in a HEIC or a WebP", () => {
    const block = tiff(false, PHONE);
    const heic = new Uint8Array([...text("\0\0\0\x18ftypheic"), ...new Array(500).fill(7), 0, 0, 0, 6, ...text("Exif\0\0"), ...block, ...new Array(100).fill(9)]);
    expect(findExif(heic)).toMatchObject({ make: "Apple", orientation: 6, exposure: true });
    const chunk = tiff(true, { make: "Google", model: "Pixel 8", orientation: 1 });
    const le32 = (n: number) => [n & 0xff, (n >> 8) & 0xff, (n >> 16) & 0xff, (n >> 24) & 0xff];
    const vp8 = [...text("VP8 "), ...le32(4), 1, 2, 3, 4];
    const webp = new Uint8Array([...text("RIFF"), ...le32(4 + vp8.length + 8 + chunk.length), ...text("WEBP"), ...vp8, ...text("EXIF"), ...le32(chunk.length), ...chunk]);
    expect(findExif(webp)).toMatchObject({ make: "Google", model: "Pixel 8", orientation: 1 });
    expect(findExif(text("RIFF\0\0\0\0WEBPVP8 \x04\0\0\0abcd"))).toBeNull();
  });
});

describe("turning a photo the right way up", () => {
  // Where the stored picture's first pixel (top-left) and the end of its first row (top-right) show,
  // for each EXIF orientation: a 4 × 3 picture.
  const corners: Record<number, [[number, number], [number, number]]> = {
    1: [[0, 0], [4, 0]],
    2: [[4, 0], [0, 0]],
    3: [[4, 3], [0, 3]],
    4: [[0, 3], [4, 3]],
    5: [[0, 0], [0, 4]],
    6: [[3, 0], [3, 4]],
    7: [[3, 4], [3, 0]],
    8: [[0, 4], [0, 0]],
  };
  it("draws each orientation as EXIF means it", () => {
    for (const [o, [first, rowEnd]] of Object.entries(corners)) {
      const [a, b, c, d, e, f] = uprightTransform(Number(o), 4, 3);
      const at = (x: number, y: number) => [a * x + c * y + e, b * x + d * y + f];
      expect(at(0, 0), `orientation ${o}`).toEqual(first);
      expect(at(4, 0), `orientation ${o}`).toEqual(rowEnd);
    }
    expect(uprightSize(6, 4032, 3024)).toEqual([3024, 4032]);
    expect(uprightSize(3, 4032, 3024)).toEqual([4032, 3024]);
  });

  it("opens a JPEG as stored, then carries its EXIF over upright, at its new size, without the thumbnail", () => {
    const original = jpeg(4032, 3024, PHONE, true);
    const info = readJpeg(original)!;
    // The browser opens a copy that says it's upright: the turn is drawn here, the same in every browser.
    const flat = unturned(original, info.exif!);
    expect(readJpeg(flat)!.exif!.orientation).toBe(1);
    expect([...flat].filter((byte, i) => byte !== original[i]).length).toBe(1);

    const segment = exifFor(original, info.exif!, 1920, 2560)!;
    // A canvas's JPEG starts with its JFIF header; the EXIF goes right after it.
    const made = withExif(new Uint8Array([0xff, 0xd8, ...JFIF, ...sof(1920, 2560), ...SCAN]), segment);
    expect([...made.slice(2, 4)]).toEqual([0xff, 0xe0]);
    expect([...made.slice(2 + JFIF.length, 4 + JFIF.length)]).toEqual([0xff, 0xe1]);
    const shrunk = readJpeg(made)!;
    expect(shrunk).toMatchObject({ width: 1920, height: 2560 });
    expect(shrunk.exif).toMatchObject({ make: "Apple", model: "iPhone 15", orientation: 1, exposure: true });
    const v = new DataView(made.buffer);
    expect(v.getUint16(shrunk.exif!.pixelX!.at, true)).toBe(1920);
    expect(v.getUint16(shrunk.exif!.pixelY!.at, true)).toBe(2560);
    expect(v.getUint32(shrunk.exif!.nextIfdAt!, true)).toBe(0);
    // The original is as it was.
    expect(readJpeg(original)!.exif!.orientation).toBe(6);
  });
});

describe("making camera photos smaller", () => {
  const photo = readJpeg(jpeg(4032, 3024, PHONE))!.exif;

  it("makes a camera's big photo 2560 pixels on its long side", () => {
    expect(shrinkSize("jpeg", photo, 3024, 4032)).toEqual([1920, 2560]);
    expect(shrinkSize("jpeg", photo, 2560, 1920)).toBeNull();
    expect(shrinkSize("jpeg", photo, 0, 0)).toBeNull();
  });

  it("never touches a scan, a screenshot, a drawing, a PNG, or a HEIC, AVIF or WebP photo (their EXIF wouldn't carry over)", () => {
    expect(shrinkSize("jpeg", readJpeg(jpeg(5100, 6600, { make: "EPSON", exposure: false }))!.exif, 5100, 6600)).toBeNull();
    expect(shrinkSize("jpeg", null, 6000, 4000)).toBeNull();
    expect(shrinkSize("other", photo, 6000, 4000)).toBeNull();
    expect(shrinkSize(null, photo, 6000, 4000)).toBeNull();
    expect(shrinkSize("webp", photo, 6000, 4000)).toBeNull();
    expect(shrinkSize("webp", { ...photo!, orientation: 1 }, 6000, 4000)).toBeNull();
    expect(shrinkSize("heif", photo, 4032, 3024)).toBeNull();
  });

  it("keeps the smaller photo only when it saves at least 30%", () => {
    expect(keepsShrunk(10_000_000, 3_000_000)).toBe(true);
    expect(keepsShrunk(10_000_000, 7_000_000)).toBe(true);
    expect(keepsShrunk(10_000_000, 7_000_001)).toBe(false);
    expect(keepsShrunk(10_000_000, 0)).toBe(false);
  });

  it("reads a picture's size from its first bytes, and won't open a huge one or one it can't size", () => {
    const be = (n: number) => [(n >>> 24) & 255, (n >>> 16) & 255, (n >>> 8) & 255, n & 255];
    const le = (n: number, bytes = 4) => Array.from({ length: bytes }, (_, i) => (n >>> (8 * i)) & 255);
    const ascii = (t: string) => [...t].map((c) => c.charCodeAt(0));
    const png = new Uint8Array([0x89, ...ascii("PNG"), 13, 10, 26, 10, ...be(13), ...ascii("IHDR"), ...be(16_800), ...be(10_800), 8, 6, 0, 0, 0]);
    expect(pixelSize(png)).toEqual([16_800, 10_800]);
    expect(opens(pixelSize(png))).toBe(false); // a 181 MP CAD export, 2 MB on disk
    expect(pixelSize(new Uint8Array([...ascii("GIF89a"), ...le(640, 2), ...le(480, 2)]))).toEqual([640, 480]);
    const bmp = new Uint8Array(26);
    bmp.set(ascii("BM"));
    bmp.set(le(1024), 18);
    bmp.set(le(-768 >>> 0), 22); // stored top down
    expect(pixelSize(bmp)).toEqual([1024, 768]);
    const webp = (chunk: string, body: number[]) => new Uint8Array([...ascii("RIFF"), ...le(100), ...ascii("WEBP"), ...ascii(chunk), ...le(10), ...body]);
    expect(pixelSize(webp("VP8X", [0, 0, 0, 0, ...le(3999, 3), ...le(2999, 3)]))).toEqual([4000, 3000]);
    expect(pixelSize(webp("VP8 ", [0, 0, 0, 0x9d, 0x01, 0x2a, ...le(1920, 2), ...le(1080, 2)]))).toEqual([1920, 1080]);
    expect(pixelSize(webp("VP8L", [0x2f, ...le((1199) | (799 << 14)), 0, 0, 0, 0, 0]))).toEqual([1200, 800]);
    // HEIC: the whole picture's 'ispe', not its tiles' or thumbnail's.
    const ispe = (w: number, h: number) => [...be(20), ...ascii("ispe"), 0, 0, 0, 0, ...be(w), ...be(h)];
    const heic = new Uint8Array([...be(24), ...ascii("ftypheic"), 0, 0, 0, 0, ...ascii("mif1heic"), ...ispe(512, 512), ...ispe(4032, 3024), ...ispe(320, 240)]);
    expect(pixelSize(heic)).toEqual([4032, 3024]);
    expect(opens(pixelSize(heic))).toBe(true);
    // A TIFF (a plan scan) can't be sized here, so it isn't opened.
    expect(pixelSize(new Uint8Array([...ascii("II"), 42, 0, 8, 0, 0, 0]))).toBeNull();
    expect(opens(null)).toBe(false);
    expect(opens([8000, 6000])).toBe(true); // a 48 MP phone photo
    expect(opens([OPEN_MAX_PIXELS / 5000 + 1, 5000])).toBe(false);
  });

  it("tells pictures apart by type, or by name when the type says nothing", () => {
    expect(pictureKind({ type: "image/jpeg", name: "a.jpg" })).toBe("jpeg");
    expect(pictureKind({ type: "", name: "IMG_1.JPEG" })).toBe("jpeg");
    expect(pictureKind({ type: "application/octet-stream", name: "IMG_1.heic" })).toBe("heif");
    expect(pictureKind({ type: "image/heic", name: "IMG_1.HEIC" })).toBe("heif");
    expect(pictureKind({ type: "image/webp", name: "a.webp" })).toBe("webp");
    expect(pictureKind({ type: "image/png", name: "Screenshot.png" })).toBe("other");
    expect(pictureKind({ type: "image/tiff", name: "scan.tif" })).toBe("other");
    expect(pictureKind({ type: "image/svg+xml", name: "logo.svg" })).toBeNull();
    expect(pictureKind({ type: "application/pdf", name: "C-101.pdf" })).toBeNull();
    expect(pictureKind({ type: "", name: "notes.txt" })).toBeNull();
  });

  it("follows the company's setting: on unless it's turned off", () => {
    expect(shrinksPhotos({})).toBe(true);
    expect(shrinksPhotos({ files: {} })).toBe(true);
    expect(shrinksPhotos({ files: { shrink_photos: true } })).toBe(true);
    expect(shrinksPhotos({ files: { shrink_photos: false } })).toBe(false);
    expect(shrinksPhotos(undefined)).toBe(true);
  });

  it("fits a picture inside a size, never making it bigger", () => {
    expect(fitWithin(4032, 3024, 320)).toEqual([320, 240]);
    expect(fitWithin(100, 4000, 320)).toEqual([8, 320]);
    expect(fitWithin(200, 100, 320)).toEqual([200, 100]);
  });
});

describe("preview copies", () => {
  it("are made for pictures a browser may open, not tiny ones or anything else", () => {
    expect(wantsPreview("jpeg", 3_000_000)).toBe(true);
    expect(wantsPreview("other", 900_000)).toBe(true);
    expect(wantsPreview("jpeg", PREVIEW_MIN_BYTES)).toBe(false);
    expect(wantsPreview(null, 3_000_000)).toBe(false);
    expect(wantsPreview("jpeg", 80 * 1024 * 1024)).toBe(false);
  });

  it("are stored next to their file, as the database requires", () => {
    expect(previewPathFor("c9/plans/0f1e.jpg", "image/webp")).toBe("c9/plans/0f1e.preview.webp");
    expect(previewPathFor("c9/plans/0f1e.heic", "image/jpeg")).toBe("c9/plans/0f1e.preview.jpg");
  });

  it("show in place of the whole picture, which only loads for a file with none", () => {
    const open = { "c9/plans/a.jpg": "https://x/a", "c9/plans/a.preview.webp": "https://x/a-copy", "c9/plans/b.jpg": "https://x/b" };
    const withCopy = { path: "c9/plans/a.jpg", preview_path: "c9/plans/a.preview.webp", file_name: "a.jpg", content_type: "image/jpeg", size_bytes: 14_000_000 };
    const without = { path: "c9/plans/b.jpg", preview_path: null, file_name: "b.jpg", content_type: "image/jpeg", size_bytes: 900_000 };
    // Over 10 MB, a picture with no copy keeps its icon; with one, it shows the copy.
    expect(previewLink(withCopy, open)).toBe("https://x/a-copy");
    expect(previewLink(without, open)).toBe("https://x/b");
    // A copy whose link hasn't come yet: the icon, never the whole picture.
    expect(previewLink(withCopy, { "c9/plans/a.jpg": "https://x/a" })).toBeUndefined();
    // A list read before copies, with no preview_path at all.
    expect(previewLink({ path: "c9/plans/b.jpg", file_name: "b.jpg", content_type: "image/jpeg", size_bytes: 900_000 }, open)).toBe("https://x/b");
    const pdf = { path: "c9/plans/c.pdf", preview_path: null, file_name: "c.pdf", content_type: "application/pdf", size_bytes: 900_000 };
    expect(previewCopies([withCopy, without, pdf])).toEqual([{ path: "c9/plans/a.preview.webp", file_name: "a.jpg" }]);
    expect(previewable([withCopy, without, pdf]).map((f) => f.path)).toEqual(["c9/plans/a.preview.webp", "c9/plans/b.jpg"]);
    // On a crew's visit (mobile data): copies only, never a whole photo.
    expect(previewLink(withCopy, open, false)).toBe("https://x/a-copy");
    expect(previewLink(without, open, false)).toBeUndefined();
  });
});
