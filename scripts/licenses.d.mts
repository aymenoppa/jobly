/** Types for scripts/licenses.mjs, for the web app's Vite plugin (apps/web/licenses.ts) and its test. */
export interface Package { name: string; version: string; license: string | null; url: string | null; author?: string | null; text: string | null }
export function packageRoot(file: string): string | null;
export function licenseFile(names: string[]): string | null;
export function webAddress(repository: string): string;
export function readPackage(root: string): Package;
export function packagesIn(files: string[]): Package[];
export function licensesText(intro: string, packages: Package[]): string;
