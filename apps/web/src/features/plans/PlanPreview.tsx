/**
 * A picture shown small in place of its file icon: on Plans and files, a crew's visit and Drive, and
 * while a picture uploads. A picture added from the browser has a small copy for this (preview_path,
 * a few dozen KB), which shows even while the device asks to save data. One with none (from before
 * copies, or added by the server) loads the whole file: canPreview keeps that to pictures browsers
 * can show, of 10 MB or less, and none load while the device asks to save data.
 */
import { useState } from "react";
import { canPreview, savesData, type PlanFile } from "./plans";
import styles from "./plans.module.css";

/** Over the icon, which shows until the picture has loaded, and stays if it can't be shown. */
export function PlanPreview({ src }: { src: string }) {
  // Keyed by the link: a fresh link (they last an hour) loads afresh.
  return <Picture key={src} src={src} />;
}

function Picture({ src }: { src: string }) {
  const [state, setState] = useState<"loading" | "shown" | "failed">("loading");
  if (state === "failed") return null;
  return <img className={styles.preview} src={src} alt="" loading="lazy" decoding="async" data-shown={state === "shown" || undefined} onLoad={() => setState("shown")} onError={() => setState("failed")} />;
}

/** A stored file as a list has it, for its preview. A list read before copies has no preview_path. */
type Listed = Pick<PlanFile, "path" | "content_type" | "file_name" | "size_bytes"> & { preview_path?: string | null };

/**
 * The link to show a stored file's preview from, out of the list's open links, if it gets one: its
 * copy's, or for a picture with none, its own, unless `whole` is false (a crew's phone on a visit:
 * only copies, never a whole photo over mobile data). Never the whole picture for one with a copy,
 * even while the copy's link is on its way.
 */
export function previewLink(file: Listed, open: Record<string, string> | undefined, whole = true): string | undefined {
  if (!open) return undefined;
  if (file.preview_path) return open[file.preview_path];
  return whole && canPreview(file) && !savesData() ? open[file.path] : undefined;
}

/** The copies a list needs links made for, to show previews (each named as its file, though only shown). */
export function previewCopies(files: Listed[]): Array<Pick<PlanFile, "path" | "file_name">> {
  return files.flatMap((f) => (f.preview_path ? [{ path: f.preview_path, file_name: f.file_name }] : []));
}

/** The stored files a list needs links made for, to show previews: each copy, and pictures with none (not while the device saves data). */
export function previewable(files: Listed[]): Array<Pick<PlanFile, "path" | "file_name">> {
  const whole = savesData() ? [] : files.filter((f) => !f.preview_path && canPreview(f));
  return [...previewCopies(files), ...whole];
}

/**
 * A picture on this device as it uploads: a link to the file itself, so nothing is downloaded. The
 * one who made it revokes it (URL.revokeObjectURL) once the upload is over.
 */
export function localPreview(file: File): string | null {
  return canPreview({ content_type: file.type || null, file_name: file.name, size_bytes: file.size }) ? URL.createObjectURL(file) : null;
}
