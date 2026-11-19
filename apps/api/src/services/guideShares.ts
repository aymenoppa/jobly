/**
 * A guide's pictures as its shared page serves them (routes/guideShares.ts): the JPEG as stored,
 * with whatever a camera or an editing program wrote into it taken out.
 */
import { isJpeg } from "./photos";

const ICC = "ICC_PROFILE\0";

/**
 * A JPEG without its metadata: no EXIF (where a phone writes where the photo was taken), XMP,
 * IPTC or comments, and nothing after the picture's end (a phone's second picture or short video
 * rides there). A guide's pictures are redrawn by the browser as they're added, which leaves none
 * of that, but a file put in the folder some other way would carry it, and this page is read by
 * people outside the business. The picture itself isn't touched: its colour profile and Adobe's
 * colour marker stay, since it would look different without them. Null when it isn't a JPEG that
 * reads cleanly from start to end, which is then not served at all.
 */
export function withoutMetadata(bytes: Uint8Array): Uint8Array | null {
  if (!isJpeg(bytes)) return null;
  const kept: Array<[number, number]> = [[0, 2]];
  const u16 = (at: number) => (bytes[at]! << 8) | bytes[at + 1]!;
  let at = 2;
  let scans = 0;
  while (at + 2 <= bytes.length) {
    if (bytes[at] !== 0xff) return null;
    const marker = bytes[at + 1]!;
    // A marker may be padded with extra FFs.
    if (marker === 0xff) {
      at += 1;
      continue;
    }
    if (marker === 0xd9) {
      if (!scans) return null;
      kept.push([at, at + 2]);
      return joined(bytes, kept);
    }
    if (at + 4 > bytes.length) return null;
    const length = u16(at + 2);
    const end = at + 2 + length;
    if (length < 2 || end > bytes.length) return null;
    if (marker === 0xda) {
      // A scan: its header, then the picture's data up to the next marker. Inside the data, FF is
      // followed by 00 (an FF byte of data) or D0 to D7 (a restart), which aren't the next marker.
      let i = end;
      for (;;) {
        while (i < bytes.length && bytes[i] !== 0xff) i++;
        if (i + 1 >= bytes.length) return null;
        const next = bytes[i + 1]!;
        if (next === 0xff) i += 1;
        else if (next === 0x00 || (next >= 0xd0 && next <= 0xd7)) i += 2;
        else break;
      }
      kept.push([at, i]);
      scans += 1;
      at = i;
      continue;
    }
    if (!isMetadata(bytes, marker, at + 4, end)) kept.push([at, end]);
    at = end;
  }
  return null;
}

/** Comments, and every application segment but JFIF's own (APP0), a colour profile (APP2) and Adobe's colour marker (APP14). */
function isMetadata(bytes: Uint8Array, marker: number, start: number, end: number): boolean {
  if (marker === 0xfe) return true;
  if (marker < 0xe1 || marker > 0xef || marker === 0xee) return false;
  // APP2 is a colour profile, or a phone's index of the other pictures in the file.
  if (marker === 0xe2) return !(end - start >= ICC.length && String.fromCharCode(...bytes.subarray(start, start + ICC.length)) === ICC);
  return true;
}

function joined(bytes: Uint8Array, parts: Array<[number, number]>): Uint8Array {
  const out = new Uint8Array(parts.reduce((n, [from, to]) => n + (to - from), 0));
  let at = 0;
  for (const [from, to] of parts) {
    out.set(bytes.subarray(from, to), at);
    at += to - from;
  }
  return out;
}
