/** Types for scripts/i18n.mjs, for the tests that use it. */
export const ROOT: string;
export const COVERED: string[];
export function listFiles(paths: string[]): string[];
export function catalogProblems(): string[];
export function rawStrings(file: string): Array<{ line: number; text: string; kind: string }>;
export function readCatalog(): { lines: Map<string, { value: string | Record<string, string | null> | null; file: string; line: number }>; duplicates: Array<{ key: string; file: string; other: string }> };
export function allKeys(paths?: string[]): { keys: Array<{ file: string; line: number; kind: string; key: string; english: string }>; problems: Array<{ file: string; line: number; problem: string }> };
/** A database function's text as its newest migration defines it (quotes un-doubled). Throws when none does. */
export function sqlFunction(name: string): string;
