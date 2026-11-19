/**
 * Pictures added to Plans and files and Drive from the browser, before they're sent:
 *
 *   - A camera's JPEG photo bigger than SHRINK_TO pixels on its long side is made that size when
 *     that saves at least SHRINK_SAVES of it. A phone's 12 MB photo is a few MB once it's smaller,
 *     and still sharp on any screen. Only photos a camera clearly took (EXIF names the camera and
 *     its exposure): never a PDF, a PNG, a screenshot, a scan or a drawing, so a plan sheet stays as
 *     readable as it came. It keeps its name, when and where it was taken, and the right way up.
 *     HEIC, AVIF and WebP photos are left as they are: their EXIF couldn't be carried over. Settings
 *     → Storage can turn it off (settings.files.shrink_photos, on unless it's false).
 *   - Every picture the browser can open gets a small preview copy, PREVIEW_SIZE pixels on its long
 *     side, for the lists to show instead of the whole picture (plans.ts, storePreview).
 *   - Neither opens a picture whose size in pixels can't be read from its first bytes (a TIFF), or
 *     one bigger than OPEN_MAX_PIXELS: a small file can hold a huge plan scan, and opening it on a
 *     phone can take the page's memory, and the upload with it.
 *
 * Neither ever stops a file going up: anything that can't be done here leaves the file as it is,
 * with no copy, as before.
 */
import { exifFor, readJpeg, unturned, uprightSize, uprightTransform, withExif, type Exif, type JpegInfo } from "./exif";

/** A camera's photo is made this many pixels on its long side, at most. */
export const SHRINK_TO = 2560;
export const SHRINK_QUALITY = 0.85;
/** The smaller photo is kept only when it's at least this much smaller (30%): less isn't worth a re-saved copy. */
export const SHRINK_SAVES = 0.3;
/** A preview copy's long side, in pixels: sharp at the lists' size on any screen. */
export const PREVIEW_SIZE = 320;
/** A picture this small loads whole on the list, as before: a copy would be about as big. */
export const PREVIEW_MIN_BYTES = 64 * 1024;
/** A file bigger than this isn't opened here: the phone's memory is for the upload. */
const OPEN_MAX_BYTES = 60 * 1024 * 1024;
/** Nor a picture with more pixels than this (a 48 MP phone photo opens; a 100 MP plan scan doesn't). */
export const OPEN_MAX_PIXELS = 50_000_000;
/** How much of a file other than a JPEG is read for its size (a JPEG is read whole, for its EXIF). */
const HEADER_BYTES = 256 * 1024;
/** How long a copy may take: a picture the browser chokes on goes up without one. */
const PREVIEW_WAIT_MS = 20_000;

/**
 * What kind of picture a file is, for this: a JPEG (EXIF in its APP1 segment, turned by its
 * orientation), HEIC, HEIF or AVIF (turned by the file itself, as browsers open them), WebP, any
 * other picture (PNG, GIF, BMP, TIFF: never shrunk, but it may get a copy), or null for anything
 * else, a drawing (SVG) included.
 */
export type PictureKind = "jpeg" | "heif" | "webp" | "other";

export function pictureKind(f: { type: string; name: string }): PictureKind | null {
  const type = f.type.toLowerCase();
  // No type, or one that says nothing: by the name.
  const by = (types: RegExp, names: RegExp) => (type && type !== "application/octet-stream" ? types.test(type) : names.test(f.name));
  if (by(/^image\/svg/, /\.svgz?$/i)) return null;
  if (by(/^image\/p?jpeg$/, /\.(jpe?g|jfif)$/i)) return "jpeg";
  if (by(/^image\/(heic|heif|avif)(-sequence)?$/, /\.(heic|heif|avif)$/i)) return "heif";
  if (by(/^image\/webp$/, /\.webp$/i)) return "webp";
  if (by(/^image\//, /\.(png|gif|bmp|tiff?)$/i)) return "other";
  return null;
}

/** Whether the company has photos made smaller as they're added (settings.files.shrink_photos: on unless it's false). */
export function shrinksPhotos(settings: Record<string, unknown> | null | undefined): boolean {
  const files = settings?.files;
  return !(files && typeof files === "object" && (files as { shrink_photos?: unknown }).shrink_photos === false);
}

/** `width` by `height` made to fit `max` on its long side (never bigger than it was). */
export function fitWithin(width: number, height: number, max: number): [number, number] {
  const scale = Math.min(1, max / Math.max(width, height));
  return [Math.max(1, Math.round(width * scale)), Math.max(1, Math.round(height * scale))];
}

/**
 * A camera clearly took it: EXIF names the make or model, and the exposure it took it with. A
 * screenshot or a drawing has neither; a scanner names itself but has no exposure.
 */
export const cameraPhoto = (exif: Exif | null): boolean => Boolean(exif && (exif.make || exif.model) && exif.exposure);

/**
 * The size to make a photo, upright (`width` by `height`, as it shows), or null to send it as it is:
 * only a camera's JPEG (its EXIF carries over), bigger than SHRINK_TO.
 */
export function shrinkSize(kind: PictureKind | null, exif: Exif | null, width: number, height: number): [number, number] | null {
  if (kind !== "jpeg" || !cameraPhoto(exif)) return null;
  if (!width || !height || Math.max(width, height) <= SHRINK_TO) return null;
  return fitWithin(width, height, SHRINK_TO);
}

/** Whether the smaller photo is worth keeping: at least SHRINK_SAVES smaller. */
export const keepsShrunk = (before: number, after: number) => after > 0 && after <= before * (1 - SHRINK_SAVES);

/**
 * A picture's width and height from its first bytes, without opening it: a PNG, GIF, BMP, WebP,
 * HEIC, HEIF or AVIF. Null when they can't be told (a TIFF, say), and then it isn't opened.
 */
export function pixelSize(b: Uint8Array): [number, number] | null {
  const is = (at: number, text: string) => [...text].every((c, i) => b[at + i] === c.charCodeAt(0));
  const be32 = (i: number) => ((b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3]) >>> 0;
  const le16 = (i: number) => b[i] | (b[i + 1] << 8);
  const le24 = (i: number) => b[i] | (b[i + 1] << 8) | (b[i + 2] << 16);
  const le32 = (i: number) => (b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24)) >>> 0;
  if (b.length >= 24 && b[0] === 0x89 && is(1, "PNG") && is(12, "IHDR")) return [be32(16), be32(20)];
  if (b.length >= 10 && is(0, "GIF8")) return [le16(6), le16(8)];
  // A BMP's height is negative when it's stored top down.
  if (b.length >= 26 && is(0, "BM")) return [Math.abs(le32(18) | 0), Math.abs(le32(22) | 0)];
  if (b.length >= 30 && is(0, "RIFF") && is(8, "WEBP")) {
    if (is(12, "VP8X")) return [le24(24) + 1, le24(27) + 1];
    if (is(12, "VP8L") && b[20] === 0x2f) return [(le32(21) & 0x3fff) + 1, ((le32(21) >>> 14) & 0x3fff) + 1];
    if (is(12, "VP8 ") && b[23] === 0x9d && b[24] === 0x01 && b[25] === 0x2a) return [le16(26) & 0x3fff, le16(28) & 0x3fff];
    return null;
  }
  if (b.length >= 12 && is(4, "ftyp")) {
    // HEIC, HEIF, AVIF: each image in it says its size in an 'ispe' box. The biggest is the whole
    // picture; the others are its tiles and thumbnail.
    let size: [number, number] | null = null;
    for (let i = 8; i + 16 <= b.length; i++) {
      if (b[i] !== 0x69 || !is(i, "ispe")) continue;
      const [w, h] = [be32(i + 8), be32(i + 12)];
      if (!size || w * h > size[0] * size[1]) size = [w, h];
    }
    return size;
  }
  return null;
}

/** Whether a picture of `size` may be opened here: its size known, and not too many pixels. */
export const opens = (size: [number, number] | null): boolean => Boolean(size && size[0] > 0 && size[1] > 0 && size[0] * size[1] <= OPEN_MAX_PIXELS);

/** Whether a picture gets a preview copy: one the browser may open, not too small to bother or too big to open. */
export const wantsPreview = (kind: PictureKind | null, size: number) => kind !== null && size > PREVIEW_MIN_BYTES && size <= OPEN_MAX_BYTES;

// ---------------------------------------------------------------------------------------------
// In the browser
// ---------------------------------------------------------------------------------------------

/** What goes up: the file (made smaller, or as it was), and its preview copy as it's made (null: none). */
export interface Prepared {
  file: File;
  preview: Promise<Blob | null>;
}

const NO_PREVIEW: Promise<Blob | null> = Promise.resolve(null);

/** A picture opened upright: drawn with `orientation`'s turn, it's `width` by `height`. */
interface Opened {
  bitmap: ImageBitmap;
  orientation: number;
  width: number;
  height: number;
}

/**
 * The file to send for `file`, made smaller when it's a camera's big photo and `shrink` allows, with
 * its preview copy on the way. Never throws: anything that goes wrong sends the file as it was.
 */
export async function preparePicture(file: File, shrink: boolean): Promise<Prepared> {
  const kind = pictureKind(file);
  if (!wantsPreview(kind, file.size)) return { file, preview: NO_PREVIEW };
  try {
    // A JPEG is read whole (its EXIF says who took it and which way up it goes); anything else only
    // as far as its size.
    const bytes = new Uint8Array(await (kind === "jpeg" ? file : file.slice(0, HEADER_BYTES)).arrayBuffer());
    const jpeg = kind === "jpeg" ? readJpeg(bytes) : null;
    if (!opens(jpeg ? (jpeg.width && jpeg.height ? [jpeg.width, jpeg.height] : null) : pixelSize(bytes))) return { file, preview: NO_PREVIEW };
    const exif = jpeg?.exif ?? null;
    if (!jpeg || !shrink || !shrinkSize(kind, exif, ...uprightSize(exif?.orientation ?? 1, jpeg.width, jpeg.height))) {
      return { file, preview: previewOf(file, jpeg ? bytes : null, jpeg) };
    }
    const opened = await open(file, bytes, jpeg);
    const size = shrinkSize(kind, exif, opened.width, opened.height);
    if (!size) return { file, preview: previewFrom(opened) };
    const canvas = draw(opened, size[0] / opened.width);
    opened.bitmap.close();
    let body = await encode(canvas, "image/jpeg", SHRINK_QUALITY);
    if (body && jpeg.exif) {
      // When and where it was taken, and the camera, carried over (the right way up now).
      const segment = exifFor(bytes, jpeg.exif, canvas.width, canvas.height);
      if (segment) body = new Blob([withExif(new Uint8Array(await body.arrayBuffer()), segment) as BlobPart], { type: "image/jpeg" });
    }
    const preview = previewFromCanvas(canvas);
    if (!body || !keepsShrunk(file.size, body.size)) return { file, preview };
    return { file: new File([body], file.name, { type: "image/jpeg", lastModified: file.lastModified }), preview };
  } catch {
    return { file, preview: NO_PREVIEW };
  }
}

/** A preview copy of a picture sent as it is: opened and made small while it uploads. */
function previewOf(file: File, bytes: Uint8Array | null, jpeg: JpegInfo | null): Promise<Blob | null> {
  return settle((async () => previewFrom(await open(file, bytes, jpeg)))());
}

/** Never longer than PREVIEW_WAIT_MS, and never a failure: null instead. */
function settle(copy: Promise<Blob | null>): Promise<Blob | null> {
  return new Promise((resolve) => {
    const timer = setTimeout(() => resolve(null), PREVIEW_WAIT_MS);
    copy.then(
      (blob) => {
        clearTimeout(timer);
        resolve(blob);
      },
      () => {
        clearTimeout(timer);
        resolve(null);
      },
    );
  });
}

/**
 * Opens a picture to draw it. A JPEG is opened with its orientation set to 1 and turned here, so it
 * comes out the same in every browser (some turn a JPEG by its EXIF as they open it, some don't).
 * Anything else is opened as the browser opens it: HEIC and AVIF turn themselves.
 */
async function open(file: File, bytes: Uint8Array | null, jpeg: JpegInfo | null): Promise<Opened> {
  const exif = jpeg?.exif;
  const turned = exif && exif.orientation !== 1 && exif.orientationAt !== null;
  const bitmap = await createImageBitmap(turned ? new Blob([unturned(bytes!, exif) as BlobPart], { type: "image/jpeg" }) : file);
  const orientation = turned ? exif.orientation : 1;
  const [width, height] = uprightSize(orientation, bitmap.width, bitmap.height);
  return { bitmap, orientation, width, height };
}

function canvasOf(width: number, height: number): HTMLCanvasElement {
  const canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;
  return canvas;
}

/** The picture drawn upright at `scale`, on white (a see-through part would turn black as a JPEG). */
function draw(opened: Opened, scale: number): HTMLCanvasElement {
  const [width, height] = [Math.max(1, Math.round(opened.width * scale)), Math.max(1, Math.round(opened.height * scale))];
  const canvas = canvasOf(width, height);
  const ctx = canvas.getContext("2d")!;
  ctx.fillStyle = "#fff";
  ctx.fillRect(0, 0, width, height);
  ctx.imageSmoothingQuality = "high";
  // Drawn as stored, at the size that's upright once turned.
  const [storedWidth, storedHeight] = uprightSize(opened.orientation, width, height);
  ctx.setTransform(...uprightTransform(opened.orientation, storedWidth, storedHeight));
  ctx.drawImage(opened.bitmap, 0, 0, storedWidth, storedHeight);
  return canvas;
}

/** A preview copy straight from the opened picture: first to 4 times its size at most, then down from there. */
function previewFrom(opened: Opened): Promise<Blob | null> {
  try {
    const canvas = draw(opened, Math.min(1, (PREVIEW_SIZE * 4) / Math.max(opened.width, opened.height)));
    opened.bitmap.close();
    return previewFromCanvas(canvas);
  } catch {
    return NO_PREVIEW;
  }
}

/**
 * A preview copy of an upright picture, halved a step at a time (one big step leaves fine lines
 * out), as WebP, or JPEG where the browser can't make WebP. `source` is let go once it's done with:
 * a phone has only so much room for canvases, and a batch of pictures would use it up.
 */
function previewFromCanvas(source: HTMLCanvasElement): Promise<Blob | null> {
  return settle(
    (async () => {
      const [width, height] = fitWithin(source.width, source.height, PREVIEW_SIZE);
      let current = source;
      while (current.width > width * 2) {
        const next = canvasOf(Math.round(current.width / 2), Math.round(current.height / 2));
        const ctx = next.getContext("2d")!;
        ctx.imageSmoothingQuality = "high";
        ctx.drawImage(current, 0, 0, next.width, next.height);
        if (current !== source) current.width = current.height = 0; // hand the memory back
        current = next;
      }
      const out = canvasOf(width, height);
      const ctx = out.getContext("2d")!;
      ctx.imageSmoothingQuality = "high";
      ctx.drawImage(current, 0, 0, width, height);
      if (current !== source) current.width = current.height = 0;
      source.width = source.height = 0;
      const webp = await encode(out, "image/webp", 0.72);
      const copy = webp?.type === "image/webp" ? webp : await encode(out, "image/jpeg", 0.75);
      out.width = out.height = 0;
      return copy && (copy.type === "image/webp" || copy.type === "image/jpeg") ? copy : null;
    })(),
  );
}

const encode = (canvas: HTMLCanvasElement, type: string, quality: number) => new Promise<Blob | null>((resolve) => canvas.toBlob(resolve, type, quality));
