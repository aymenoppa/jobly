/**
 * A note someone typed (a job's instructions for the crew), shown with the little formatting plain
 * text can carry: a line starting "- " or "1. " as a list, "# " as a heading, **bold**, and line
 * breaks where they were typed (core markdownToGuide, as a note). The text itself stays plain, so
 * exports and AI assistants read and write it as they always did.
 */
import { markdownToGuide } from "@jobly/core/markdown";
import type { CSSProperties } from "react";
import { sanitizeHtml } from "@/lib/html";

export function Note({ text, className, style }: { text: string; className?: string; style?: CSSProperties }) {
  return <div className={`prose note-text${className ? ` ${className}` : ""}`} style={style} dangerouslySetInnerHTML={{ __html: sanitizeHtml(markdownToGuide(text, { note: true }).html) }} />;
}
