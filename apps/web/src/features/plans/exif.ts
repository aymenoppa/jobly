/**
 * What a camera writes into a photo (EXIF), read straight from the file's bytes: whether a camera
 * took it, which way up it goes, and where those values are, so a smaller copy can be drawn the
 * right way up and keep the rest (when and where it was taken). No browser parts, so the tests run
 * it as it is.
 *
 * A JPEG keeps EXIF in its APP1 segment; HEIC, AVIF and WebP keep the same block elsewhere in the
 * file. The block is TIFF: a header saying the byte order, then lists of tagged values (IFDs).
 */

export interface Exif {
  make: string | null;
  model: string | null;
  /** 1 to 8, as EXIF numbers them: 1 is upright as stored; 5 to 8 are turned a quarter. */
  orientation: number;
  /** Where in the file the orientation's value is (to set it to 1), or null when there's none. */
  orientationAt: number | null;
  littleEndian: boolean;
  /** A shutter speed, f-number or ISO: a camera took it, not a scanner or an app. */
  exposure: boolean;
  /** Where in the file the link from the main IFD to the thumbnail's is (0 cuts the thumbnail off). */
  nextIfdAt: number | null;
  /** The picture's width and height the camera recorded (stale once it's made smaller). */
  pixelX: Value | null;
  pixelY: Value | null;
  /** JPEG only: the whole APP1 segment, from its marker to its end. */
  segment: { start: number; end: number } | null;
}

/** A number stored in place: where, and as a SHORT (3) or a LONG (4). */
export interface Value {
  at: number;
  type: number;
}

export interface JpegInfo {
  /** As stored, before any turn the orientation asks for; 0 when the frame header wasn't found. */
  width: number;
  height: number;
  exif: Exif | null;
}

const MAKE = 0x010f;
const MODEL = 0x0110;
const ORIENTATION = 0x0112;
const EXIF_IFD = 0x8769;
const EXPOSURE_TIME = 0x829a;
const F_NUMBER = 0x829d;
const ISO = 0x8827;
const PIXEL_X = 0xa002;
const PIXEL_Y = 0xa003;
const SHORT = 3;
const LONG = 4;

const u16 = (b: Uint8Array, at: number, le: boolean) => (le ? b[at]! | (b[at + 1]! << 8) : (b[at]! << 8) | b[at + 1]!);
const u32 = (b: Uint8Array, at: number, le: boolean) =>
  (le ? b[at]! | (b[at + 1]! << 8) | (b[at + 2]! << 16) | (b[at + 3]! << 24) : (b[at]! << 24) | (b[at + 1]! << 16) | (b[at + 2]! << 8) | b[at + 3]!) >>> 0;

function put16(b: Uint8Array, at: number, value: number, le: boolean) {
  b[at] = le ? value & 0xff : (value >> 8) & 0xff;
  b[at + 1] = le ? (value >> 8) & 0xff : value & 0xff;
}

function put32(b: Uint8Array, at: number, value: number, le: boolean) {
  for (let i = 0; i < 4; i++) b[at + (le ? i : 3 - i)] = (value >>> (8 * i)) & 0xff;
}

/** "II*\0" or "MM\0*": where a TIFF block starts. */
const tiffAt = (b: Uint8Array, at: number) =>
  at + 4 <= b.length && ((b[at] === 0x49 && b[at + 1] === 0x49 && b[at + 2] === 0x2a && b[at + 3] === 0) || (b[at] === 0x4d && b[at + 1] === 0x4d && b[at + 2] === 0 && b[at + 3] === 0x2a));

/** "Exif\0\0", which comes before the TIFF block in a JPEG and usually in HEIC. */
const exifHeaderAt = (b: Uint8Array, at: number) =>
  at + 6 <= b.length && b[at] === 0x45 && b[at + 1] === 0x78 && b[at + 2] === 0x69 && b[at + 3] === 0x66 && b[at + 4] === 0 && b[at + 5] === 0;

/** An IFD's entries: tag, type, count, and where its value (or the offset to it) is. */
function* entries(b: Uint8Array, at: number, end: number, le: boolean) {
  if (at + 2 > end) return;
  const n = u16(b, at, le);
  if (n > 1000 || at + 2 + n * 12 > end) return;
  for (let i = 0; i < n; i++) {
    const e = at + 2 + i * 12;
    yield { tag: u16(b, e, le), type: u16(b, e + 2, le), count: u32(b, e + 4, le), value: e + 8 };
  }
}

function ascii(b: Uint8Array, tiff: number, end: number, type: number, count: number, value: number, le: boolean): string | null {
  if (type !== 2 || count === 0 || count > 256) return null;
  const at = count <= 4 ? value : tiff + u32(b, value, le);
  if (at < tiff || at + count > end) return null;
  let text = "";
  for (let i = 0; i < count && b[at + i] !== 0; i++) text += String.fromCharCode(b[at + i]!);
  return text.trim() || null;
}

/** The TIFF block from `tiff` to `end`, or null when it isn't one. Every position it gives is in `b`. */
export function readTiff(b: Uint8Array, tiff: number, end = b.length): Exif | null {
  end = Math.min(end, b.length);
  if (!tiffAt(b, tiff) || tiff + 8 > end) return null;
  const le = b[tiff] === 0x49;
  const ifd0 = tiff + u32(b, tiff + 4, le);
  if (ifd0 < tiff + 8 || ifd0 + 2 > end) return null;
  const exif: Exif = {
    make: null, model: null, orientation: 1, orientationAt: null, littleEndian: le, exposure: false, nextIfdAt: null, pixelX: null, pixelY: null, segment: null,
  };
  let exifIfd: number | null = null;
  for (const e of entries(b, ifd0, end, le)) {
    if (e.tag === MAKE) exif.make = ascii(b, tiff, end, e.type, e.count, e.value, le);
    else if (e.tag === MODEL) exif.model = ascii(b, tiff, end, e.type, e.count, e.value, le);
    else if (e.tag === ORIENTATION && e.type === SHORT && e.count === 1) {
      const o = u16(b, e.value, le);
      if (o >= 1 && o <= 8) {
        exif.orientation = o;
        exif.orientationAt = e.value;
      }
    } else if (e.tag === EXIF_IFD && (e.type === LONG || e.type === 13) && e.count === 1) exifIfd = tiff + u32(b, e.value, le);
  }
  const n = u16(b, ifd0, le);
  if (ifd0 + 2 + n * 12 + 4 <= end) exif.nextIfdAt = ifd0 + 2 + n * 12;
  if (exifIfd !== null && exifIfd >= tiff + 8 && exifIfd + 2 <= end) {
    for (const e of entries(b, exifIfd, end, le)) {
      if (e.tag === EXPOSURE_TIME || e.tag === F_NUMBER || e.tag === ISO) exif.exposure = true;
      else if ((e.tag === PIXEL_X || e.tag === PIXEL_Y) && (e.type === SHORT || e.type === LONG) && e.count === 1) {
        exif[e.tag === PIXEL_X ? "pixelX" : "pixelY"] = { at: e.value, type: e.type };
      }
    }
  }
  return exif;
}

/** A JPEG's size as stored and its EXIF, or null when it isn't a JPEG. */
export function readJpeg(b: Uint8Array): JpegInfo | null {
  if (b.length < 4 || b[0] !== 0xff || b[1] !== 0xd8) return null;
  const info: JpegInfo = { width: 0, height: 0, exif: null };
  let i = 2;
  while (i + 4 <= b.length) {
    if (b[i] !== 0xff) break;
    const marker = b[i + 1]!;
    // Padding, and markers with no length.
    if (marker === 0xff) {
      i++;
      continue;
    }
    if (marker === 0x01 || (marker >= 0xd0 && marker <= 0xd8)) {
      i += 2;
      continue;
    }
    // The image data starts (or it ends): nothing more to read.
    if (marker === 0xda || marker === 0xd9) break;
    const length = (b[i + 2]! << 8) | b[i + 3]!;
    const start = i + 4;
    const end = i + 2 + length;
    if (length < 2 || end > b.length) break;
    if (marker === 0xe1 && !info.exif && exifHeaderAt(b, start)) {
      const exif = readTiff(b, start + 6, end);
      if (exif) info.exif = { ...exif, segment: { start: i, end } };
    }
    // A frame header (SOF0 to SOF15, but not DHT, JPG or DAC): the picture's size.
    if (marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc && length >= 7) {
      info.height = (b[start + 1]! << 8) | b[start + 2]!;
      info.width = (b[start + 3]! << 8) | b[start + 4]!;
    }
    i = end;
  }
  return info;
}

/** EXIF in a HEIC, AVIF or WebP file, wherever it is, or null when there's none. */
export function findExif(b: Uint8Array): Exif | null {
  // WebP: an EXIF chunk, whose data is the TIFF block (some writers put "Exif\0\0" first).
  const ascii4 = (at: number) => String.fromCharCode(b[at]!, b[at + 1]!, b[at + 2]!, b[at + 3]!);
  if (b.length >= 12 && ascii4(0) === "RIFF" && ascii4(8) === "WEBP") {
    for (let at = 12; at + 8 <= b.length; ) {
      const size = u32(b, at + 4, true);
      if (ascii4(at) === "EXIF") {
        const start = exifHeaderAt(b, at + 8) ? at + 14 : at + 8;
        return readTiff(b, start, at + 8 + size);
      }
      at += 8 + size + (size % 2);
    }
    return null;
  }
  // HEIC and AVIF: the block, after "Exif\0\0", in the file's data.
  for (let at = 0; at + 14 <= b.length; at++) {
    if (b[at] === 0x45 && exifHeaderAt(b, at) && tiffAt(b, at + 6)) {
      const exif = readTiff(b, at + 6);
      if (exif) return exif;
    }
  }
  return null;
}

/** A copy of the file with its orientation set to 1, for a browser to open as stored, not turned. */
export function unturned(b: Uint8Array, exif: Exif): Uint8Array {
  const copy = b.slice();
  if (exif.orientationAt !== null) put16(copy, exif.orientationAt, 1, exif.littleEndian);
  return copy;
}

/**
 * A JPEG's EXIF segment for a smaller copy drawn upright, `width` by `height`: the orientation set to
 * 1, the size it records made the new one, and the thumbnail cut off (it would still be turned).
 * Null when the photo had none.
 */
export function exifFor(b: Uint8Array, exif: Exif, width: number, height: number): Uint8Array | null {
  if (!exif.segment) return null;
  const { start } = exif.segment;
  const seg = b.slice(start, exif.segment.end);
  const le = exif.littleEndian;
  if (exif.orientationAt !== null) put16(seg, exif.orientationAt - start, 1, le);
  if (exif.nextIfdAt !== null) put32(seg, exif.nextIfdAt - start, 0, le);
  for (const [value, size] of [[exif.pixelX, width], [exif.pixelY, height]] as const) {
    if (!value) continue;
    if (value.type === LONG) put32(seg, value.at - start, size, le);
    else if (size <= 0xffff) put16(seg, value.at - start, size, le);
  }
  return seg;
}

/** `jpeg` with `segment` (an APP1 EXIF segment) put in at the front, after its JFIF header if it has one. */
export function withExif(jpeg: Uint8Array, segment: Uint8Array): Uint8Array {
  if (jpeg.length < 4 || jpeg[0] !== 0xff || jpeg[1] !== 0xd8) return jpeg;
  const at = jpeg[2] === 0xff && jpeg[3] === 0xe0 && jpeg.length >= 6 ? 4 + ((jpeg[4]! << 8) | jpeg[5]!) : 2;
  if (at > jpeg.length) return jpeg;
  const out = new Uint8Array(jpeg.length + segment.length);
  out.set(jpeg.subarray(0, at), 0);
  out.set(segment, at);
  out.set(jpeg.subarray(at), at + segment.length);
  return out;
}

/** The size of a picture stored `width` by `height` once it's turned as `orientation` asks. */
export const uprightSize = (orientation: number, width: number, height: number): [number, number] =>
  orientation >= 5 && orientation <= 8 ? [height, width] : [width, height];

/**
 * The canvas transform (a, b, c, d, e, f) that draws a picture stored `width` by `height` (as it's
 * drawn, scaled) the right way up, onto a canvas of uprightSize.
 */
export function uprightTransform(orientation: number, width: number, height: number): [number, number, number, number, number, number] {
  switch (orientation) {
    case 2: return [-1, 0, 0, 1, width, 0];
    case 3: return [-1, 0, 0, -1, width, height];
    case 4: return [1, 0, 0, -1, 0, height];
    case 5: return [0, 1, 1, 0, 0, 0];
    case 6: return [0, 1, -1, 0, height, 0];
    case 7: return [0, -1, -1, 0, height, width];
    case 8: return [0, -1, 1, 0, 0, width];
    default: return [1, 0, 0, 1, 0, 0];
  }
}
