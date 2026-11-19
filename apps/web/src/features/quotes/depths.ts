/**
 * Fill quantities on a quote (QuotePage's Drawings card): the depth each line gets when its formula
 * reads one. The office confirms them line by line before a drawing fills the quote, and they go to
 * POST /quotes/:id/apply-measurement as `depths`, by line id.
 */

/** A line whose formula reads a depth, with the depth to give it as typed. */
export interface DepthLine {
  id: string;
  name: string;
  depth: string;
}

/** The depths confirmed for the lines, by line id; null while any isn't a depth (more than 0, at most 48 inches). */
export function lineDepths(lines: readonly DepthLine[]): Record<string, number> | null {
  const depths: Record<string, number> = {};
  for (const line of lines) {
    const depth = Number(line.depth);
    if (!line.depth.trim() || !Number.isFinite(depth) || depth <= 0 || depth > 48) return null;
    depths[line.id] = depth;
  }
  return depths;
}

/**
 * The lines to ask about, each starting with its price list item's own depth, else the drawing's,
 * else empty for the office to fill in. `lines` are the quote's, in order; only those whose formula
 * reads a depth (`usesDepth`) are asked about.
 */
export function depthLines(
  lines: ReadonlyArray<{ id: string; name: string; formula: string | null; service?: { default_depth_in: number | string | null } | null }>,
  drawn: number | null | undefined,
  usesDepth: (formula: string | null) => boolean,
): DepthLine[] {
  return lines.filter((l) => usesDepth(l.formula)).map((l) => ({ id: l.id, name: l.name, depth: String(l.service?.default_depth_in ?? drawn ?? "") }));
}
