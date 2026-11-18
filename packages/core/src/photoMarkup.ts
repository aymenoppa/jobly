/**
 * Drawing on a photo (the photo editor, apps/web/src/components/PhotoEditor.tsx): the marks as
 * data, the undo history, the size the marked-up copy is saved at, and how each mark is drawn,
 * against any 2D context. Nothing here touches the page, so it's tested on its own.
 *
 * Marks are kept in the picture's own pixels (the copy that's saved), whatever size it's shown at,
 * so a line drawn on a phone and saved lands where the finger was.
 */

import { msg } from "./i18n";

export type MarkupTool = "pen" | "arrow" | "ellipse" | "box" | "text";
export type MarkupWidth = "thin" | "thick";

export const MARKUP_TOOLS: ReadonlyArray<{ tool: MarkupTool; label: string }> = [
  { tool: "pen", label: msg("Pen") },
  { tool: "arrow", label: msg("Arrow") },
  { tool: "ellipse", label: msg("Circle") },
  { tool: "box", label: msg("Box") },
  { tool: "text", label: msg("Text") },
];

/** A few colours that show on grass, roofs, concrete and sky alike. */
export const MARKUP_COLORS: ReadonlyArray<{ color: string; label: string }> = [
  { color: "#e5243b", label: msg("Red") },
  { color: "#ffd60a", label: msg("Yellow") },
  { color: "#1d6cf2", label: msg("Blue") },
  { color: "#ffffff", label: msg("White") },
  { color: "#111111", label: msg("Black") },
];

export interface Point {
  x: number;
  y: number;
}

export type Mark =
  | { kind: "pen"; color: string; width: MarkupWidth; points: Point[] }
  | { kind: "arrow" | "ellipse" | "box"; color: string; width: MarkupWidth; from: Point; to: Point }
  | { kind: "text"; color: string; width: MarkupWidth; at: Point; text: string };

/** The longest side of a marked-up copy: the same as a photo as it's uploaded (lib/files.ts compressImage). */
export const MARKUP_MAX_SIDE = 2000;

/** The size to save a picture at: never larger than it is, and its longest side at most `max`. */
export function exportSize(width: number, height: number, max = MARKUP_MAX_SIDE): { width: number; height: number } {
  if (!(width > 0) || !(height > 0)) return { width: 1, height: 1 };
  const scale = Math.min(1, max / Math.max(width, height));
  return { width: Math.max(1, Math.round(width * scale)), height: Math.max(1, Math.round(height * scale)) };
}

/** The dark edge kept around the photo in the editor, in screen pixels (the stage's canvas rule in components.css says the same). */
export const STAGE_EDGE = 8;

/**
 * The size a picture is shown at so that all of it is on screen: its own shape, inside the box
 * less an edge all round, and never larger than the picture is. Null while the box isn't laid out.
 * The editor sets the canvas to this, so a tall photo on a wide screen, or a wide one on a phone
 * whose tool bar has wrapped, is never cut off.
 */
export function fitInside(picture: { width: number; height: number }, box: { width: number; height: number }, edge = STAGE_EDGE): { width: number; height: number } | null {
  const w = box.width - edge * 2;
  const h = box.height - edge * 2;
  if (!(picture.width > 0) || !(picture.height > 0) || !(w > 0) || !(h > 0)) return null;
  const scale = Math.min(1, w / picture.width, h / picture.height);
  return { width: Math.max(1, Math.floor(picture.width * scale)), height: Math.max(1, Math.floor(picture.height * scale)) };
}

/** How thick a line is in the picture's pixels: about the same on screen whatever the photo's size. */
export function strokeWidth(width: MarkupWidth, picture: { width: number; height: number }): number {
  const side = Math.max(picture.width, picture.height);
  return Math.max(width === "thick" ? 4 : 2, Math.round(side * (width === "thick" ? 0.012 : 0.005)));
}

/** Text's size in the picture's pixels: readable on a phone, bigger with the thick line. */
export function textSize(width: MarkupWidth, picture: { width: number; height: number }): number {
  const side = Math.max(picture.width, picture.height);
  return Math.max(14, Math.round(side * (width === "thick" ? 0.055 : 0.038)));
}

/** Where a point on the screen is on the picture, given where the picture is shown; kept inside it. */
export function toPicture(client: Point, shown: { left: number; top: number; width: number; height: number }, picture: { width: number; height: number }): Point {
  const x = ((client.x - shown.left) / Math.max(1, shown.width)) * picture.width;
  const y = ((client.y - shown.top) / Math.max(1, shown.height)) * picture.height;
  return { x: Math.min(picture.width, Math.max(0, x)), y: Math.min(picture.height, Math.max(0, y)) };
}

/** A pen stroke with the next point, unless it's too close to the last to matter (keeps a long stroke light). */
export function extendStroke(points: readonly Point[], next: Point, minGap = 2): Point[] {
  const last = points[points.length - 1];
  if (last && Math.hypot(next.x - last.x, next.y - last.y) < minGap) return points as Point[];
  return [...points, next];
}

/** Whether a mark is worth keeping: a shape needs some size (a tap isn't a box), words need words. A tap with the pen is a dot. */
export function keepsMark(mark: Mark, minSize = 4): boolean {
  if (mark.kind === "pen") return mark.points.length > 0;
  if (mark.kind === "text") return mark.text.trim().length > 0;
  return Math.hypot(mark.to.x - mark.from.x, mark.to.y - mark.from.y) >= minSize;
}

/** The two ends of an arrow's head, drawn back from its tip. */
export function arrowHead(from: Point, to: Point, lineWidth: number): [Point, Point] {
  const angle = Math.atan2(to.y - from.y, to.x - from.x);
  const length = Math.min(Math.max(lineWidth * 4, 12), Math.hypot(to.x - from.x, to.y - from.y) * 0.6 || lineWidth * 4);
  const spread = Math.PI / 7;
  return [
    { x: to.x - length * Math.cos(angle - spread), y: to.y - length * Math.sin(angle - spread) },
    { x: to.x - length * Math.cos(angle + spread), y: to.y - length * Math.sin(angle + spread) },
  ];
}

// ---------------------------------------------------------------------------------------------
// Undo and redo
// ---------------------------------------------------------------------------------------------

/** The marks now, with every earlier state to go back to and every undone one to go forward to. */
export interface MarkupHistory {
  past: Mark[][];
  marks: Mark[];
  future: Mark[][];
}

export const emptyHistory = (): MarkupHistory => ({ past: [], marks: [], future: [] });

const step = (h: MarkupHistory, marks: Mark[]): MarkupHistory => ({ past: [...h.past, h.marks], marks, future: [] });

/** One more mark. One that isn't worth keeping changes nothing. */
export const addMark = (h: MarkupHistory, mark: Mark): MarkupHistory => (keepsMark(mark) ? step(h, [...h.marks, mark]) : h);

/** Every mark off at once, and back with one undo. */
export const clearMarks = (h: MarkupHistory): MarkupHistory => (h.marks.length ? step(h, []) : h);

export const canUndo = (h: MarkupHistory) => h.past.length > 0;
export const canRedo = (h: MarkupHistory) => h.future.length > 0;

export function undo(h: MarkupHistory): MarkupHistory {
  if (!canUndo(h)) return h;
  return { past: h.past.slice(0, -1), marks: h.past[h.past.length - 1]!, future: [h.marks, ...h.future] };
}

export function redo(h: MarkupHistory): MarkupHistory {
  if (!canRedo(h)) return h;
  return { past: [...h.past, h.marks], marks: h.future[0]!, future: h.future.slice(1) };
}

// ---------------------------------------------------------------------------------------------
// The marks kept beside a photo, so drawing again starts from the photo as taken
// ---------------------------------------------------------------------------------------------

/**
 * A photo's marks as they're kept on its row (attachments.marks): what was drawn, the size of the
 * picture they were drawn on, and which drawing they made (`for`, the drawing's path). Drawing
 * again opens the photo as taken with these marks on it, each still its own (undo, clear), rather
 * than the flattened copy, which would lose a little each time it's saved again. Marks that belong
 * to another drawing (an older app drew on the photo since, and knows nothing of this) aren't used.
 */
export interface SavedMarks {
  v: 1;
  for: string;
  width: number;
  height: number;
  marks: Mark[];
}

/** Marks longer than this as text aren't kept: the drawing is still saved, and drawing again starts from it. */
export const SAVED_MARKS_MAX = 200_000;

const whole = (p: Point): Point => ({ x: Math.round(p.x), y: Math.round(p.y) });
const isPoint = (p: unknown): p is Point => Boolean(p) && typeof p === "object" && Number.isFinite((p as Point).x) && Number.isFinite((p as Point).y);
const isMark = (m: unknown): m is Mark => {
  if (!m || typeof m !== "object") return false;
  const mark = m as Record<string, unknown>;
  if (typeof mark.color !== "string" || !/^#[0-9a-f]{6}$/i.test(mark.color) || (mark.width !== "thin" && mark.width !== "thick")) return false;
  if (mark.kind === "pen") return Array.isArray(mark.points) && mark.points.length > 0 && mark.points.every(isPoint);
  if (mark.kind === "text") return isPoint(mark.at) && typeof mark.text === "string" && mark.text.trim().length > 0 && mark.text.length <= 120;
  return (mark.kind === "arrow" || mark.kind === "ellipse" || mark.kind === "box") && isPoint(mark.from) && isPoint(mark.to);
};

/** The marks to keep with a drawing saved at `path`, to the pixel. Null when there are none, or too many to keep. */
export function packMarks(marks: readonly Mark[], picture: { width: number; height: number }, path: string): SavedMarks | null {
  if (!marks.length) return null;
  const packed: SavedMarks = {
    v: 1,
    for: path,
    width: picture.width,
    height: picture.height,
    marks: marks.map((m): Mark => (m.kind === "pen" ? { ...m, points: m.points.map(whole) } : m.kind === "text" ? { ...m, at: whole(m.at) } : { ...m, from: whole(m.from), to: whole(m.to) })),
  };
  return JSON.stringify(packed).length > SAVED_MARKS_MAX ? null : packed;
}

/**
 * The marks to start from when a photo is drawn on again: those kept for the drawing it shows now
 * (`markedPath`), fitted to the size the picture is being drawn on. Null when there are none, they
 * belong to another drawing, or anything about them isn't as this app writes them: the editor then
 * opens the drawing itself, as before.
 */
export function unpackMarks(saved: unknown, markedPath: string | null | undefined, picture: { width: number; height: number }): Mark[] | null {
  if (!saved || typeof saved !== "object" || !markedPath) return null;
  const s = saved as Partial<SavedMarks>;
  if (s.v !== 1 || s.for !== markedPath || !(Number(s.width) > 0) || !(Number(s.height) > 0) || !Array.isArray(s.marks) || !s.marks.length || !s.marks.every(isMark)) return null;
  const kx = picture.width / s.width!;
  const ky = picture.height / s.height!;
  if (kx === 1 && ky === 1) return s.marks;
  const fit = (p: Point): Point => ({ x: p.x * kx, y: p.y * ky });
  return s.marks.map((m): Mark => (m.kind === "pen" ? { ...m, points: m.points.map(fit) } : m.kind === "text" ? { ...m, at: fit(m.at) } : { ...m, from: fit(m.from), to: fit(m.to) }));
}

/** A history that starts from marks made before: nothing to undo yet. */
export const historyFrom = (marks: Mark[]): MarkupHistory => ({ past: [], marks, future: [] });

// ---------------------------------------------------------------------------------------------
// Leaving the editor
// ---------------------------------------------------------------------------------------------

/**
 * What Cancel (or Escape) asks before the editor closes. A photo being added isn't anywhere yet,
 * so it's never dropped without a question: "Add without drawing" keeps it. A stored photo only
 * has the new drawing to lose, and nothing to ask when nothing was drawn.
 */
export function leaveQuestion(editing: { adding: boolean; drawn: boolean }): "add-without-drawing" | "throw-away-drawing" | null {
  if (editing.adding) return "add-without-drawing";
  return editing.drawn ? "throw-away-drawing" : null;
}

/**
 * What an answer does: the question's own button (true), its other button (false), or closed
 * without either (null), which goes back to the photo.
 */
export function leaveAnswer(question: ReturnType<typeof leaveQuestion>, answer: boolean | null): "close" | "add-as-taken" | "stay" {
  if (question === null) return "close";
  if (question === "add-without-drawing") return answer === null ? "stay" : answer ? "add-as-taken" : "close";
  return answer ? "close" : "stay";
}

// ---------------------------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------------------------

/** The parts of a canvas's 2D context the marks need (CanvasRenderingContext2D has them all). */
export interface MarkupContext {
  strokeStyle: unknown;
  fillStyle: unknown;
  lineWidth: number;
  lineCap: string;
  lineJoin: string;
  font: string;
  textBaseline: string;
  beginPath(): void;
  moveTo(x: number, y: number): void;
  lineTo(x: number, y: number): void;
  arc(x: number, y: number, radius: number, start: number, end: number): void;
  ellipse(x: number, y: number, rx: number, ry: number, rotation: number, start: number, end: number): void;
  rect(x: number, y: number, w: number, h: number): void;
  stroke(): void;
  fill(): void;
  fillText(text: string, x: number, y: number): void;
  strokeText(text: string, x: number, y: number): void;
  /** How wide words come out in the font set. Without it the width is reckoned from the letters. */
  measureText?(text: string): { width: number } | undefined;
}

/**
 * Words as they go on the picture: broken into lines that fit across it (a word longer than the
 * picture is broken too), and moved in from the edge they were tapped near, so nothing typed runs
 * off the photo. `measure` says how wide some words are at this size.
 */
export function layoutWords(text: string, at: Point, size: number, picture: { width: number; height: number }, measure: (words: string) => number): { lines: string[]; x: number; y: number; lineHeight: number } {
  const pad = Math.round(size * 0.3);
  const room = Math.max(size, picture.width - pad * 2);
  const lines: string[] = [];
  let line = "";
  const push = (word: string) => {
    const joined = line ? `${line} ${word}` : word;
    if (measure(joined) <= room) {
      line = joined;
      return;
    }
    if (line) lines.push(line);
    line = "";
    // A word wider than the picture by itself: as many letters as fit on each line.
    let rest = word;
    while (measure(rest) > room && rest.length > 1) {
      let n = rest.length - 1;
      while (n > 1 && measure(rest.slice(0, n)) > room) n--;
      lines.push(rest.slice(0, n));
      rest = rest.slice(n);
    }
    line = rest;
  };
  for (const word of text.trim().split(/\s+/)) if (word) push(word);
  if (line) lines.push(line);
  const lineHeight = Math.round(size * 1.2);
  const width = Math.max(0, ...lines.map(measure));
  const height = Math.max(0, lines.length - 1) * lineHeight + size;
  const x = Math.max(pad, Math.min(at.x, picture.width - pad - width));
  const top = Math.max(pad, Math.min(at.y - size / 2, picture.height - pad - height));
  return { lines, x, y: top + size / 2, lineHeight };
}

/** A dark edge around light words and a light one around dark words, so they read on any photo. */
const edgeFor = (color: string) => (/^#(f|e|d)/i.test(color) ? "rgba(0,0,0,0.75)" : "rgba(255,255,255,0.85)");

/** Draws one mark on a picture of this size. */
export function drawMark(ctx: MarkupContext, mark: Mark, picture: { width: number; height: number }) {
  const width = strokeWidth(mark.width, picture);
  ctx.strokeStyle = mark.color;
  ctx.fillStyle = mark.color;
  ctx.lineWidth = width;
  ctx.lineCap = "round";
  ctx.lineJoin = "round";
  if (mark.kind === "pen") {
    const [first, ...rest] = mark.points;
    if (!first) return;
    ctx.beginPath();
    if (!rest.length) {
      ctx.arc(first.x, first.y, width / 2, 0, Math.PI * 2);
      ctx.fill();
      return;
    }
    ctx.moveTo(first.x, first.y);
    for (const p of rest) ctx.lineTo(p.x, p.y);
    ctx.stroke();
    return;
  }
  if (mark.kind === "text") {
    const size = textSize(mark.width, picture);
    ctx.font = `700 ${size}px system-ui, -apple-system, "Segoe UI", Roboto, sans-serif`;
    ctx.textBaseline = "middle";
    ctx.lineWidth = Math.max(2, Math.round(size / 7));
    ctx.strokeStyle = edgeFor(mark.color);
    // Kept on the photo: wrapped to its width and moved in from the edge (layoutWords).
    const words = layoutWords(mark.text, mark.at, size, picture, (w) => ctx.measureText?.(w)?.width ?? w.length * size * 0.6);
    words.lines.forEach((line, i) => {
      ctx.strokeText(line, words.x, words.y + i * words.lineHeight);
      ctx.fillText(line, words.x, words.y + i * words.lineHeight);
    });
    return;
  }
  const { from, to } = mark;
  ctx.beginPath();
  if (mark.kind === "arrow") {
    const [left, right] = arrowHead(from, to, width);
    ctx.moveTo(from.x, from.y);
    ctx.lineTo(to.x, to.y);
    ctx.moveTo(left.x, left.y);
    ctx.lineTo(to.x, to.y);
    ctx.lineTo(right.x, right.y);
  } else if (mark.kind === "ellipse") {
    ctx.ellipse((from.x + to.x) / 2, (from.y + to.y) / 2, Math.abs(to.x - from.x) / 2, Math.abs(to.y - from.y) / 2, 0, 0, Math.PI * 2);
  } else {
    ctx.rect(Math.min(from.x, to.x), Math.min(from.y, to.y), Math.abs(to.x - from.x), Math.abs(to.y - from.y));
  }
  ctx.stroke();
}

/** Draws every mark, in the order they were made. */
export function drawMarks(ctx: MarkupContext, marks: readonly Mark[], picture: { width: number; height: number }) {
  for (const mark of marks) drawMark(ctx, mark, picture);
}
