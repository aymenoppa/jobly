/**
 * The open-source packages Jobly ships, with their licenses. They're under MIT, ISC, BSD,
 * Apache-2.0 and OFL licenses, which ask for their copyright and license text to go with every copy,
 * and a minified bundle keeps none of it. So each build writes a list next to what it built:
 *   licenses.txt          the web app's (apps/web/licenses.ts), served at /licenses.txt
 *   server-licenses.txt   the server's (scripts/build-server.mjs), next to server.mjs in the Docker image
 */
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

/**
 * The folder of the npm package a bundled file came from, or null for Jobly's own code. The last
 * node_modules in the path counts, so a copy nested in another folder (apps/web/node_modules/vite,
 * a/node_modules/b) is that copy. Vite puts \0 before some module ids and queries such as ?used after.
 */
export function packageRoot(file) {
  const path = file.replace(/^\0/, "").replace(/\?.*$/, "").replaceAll("\\", "/");
  return path.match(/^(.*\/node_modules\/(?:@[^/]+\/)?[^/.][^/]*)\//)?.[1] ?? null;
}

/**
 * A package's license file: LICENSE, LICENCE or COPYING, bare or as .md or .txt, in any case, and
 * failing those one like LICENSE-MIT. Sorted first, so the same files always give the same pick.
 */
export function licenseFile(names) {
  const sorted = [...names].sort();
  return sorted.find((n) => /^(licen[cs]e|copying)(\.(md|txt))?$/i.test(n)) ?? sorted.find((n) => /^(licen[cs]e|copying)[.-]/i.test(n)) ?? null;
}

/** A repository as package.json gives it ("git+https://github.com/a/b.git", "git@github.com:a/b", "github:a/b", "a/b") as a web address. */
export const webAddress = (repository) =>
  repository
    .replace(/^git\+/, "")
    .replace(/^(?:git|ssh):\/\/(?:git@)?/, "https://")
    .replace(/^git@([^:]+):/, "https://$1/")
    .replace(/^(?:github:)?([\w.-]+\/[\w.-]+)$/, "https://github.com/$1")
    .replace(/\.git$/, "");

/** What a package's folder says about it: package.json's name, version, license and address, and its license file. */
export function readPackage(root) {
  const pkg = JSON.parse(readFileSync(join(root, "package.json"), "utf8"));
  const file = licenseFile(readdirSync(root, { withFileTypes: true }).filter((f) => f.isFile()).map((f) => f.name));
  const repository = typeof pkg.repository === "string" ? pkg.repository : pkg.repository?.url;
  return {
    name: pkg.name,
    version: pkg.version,
    // Older packages give { type } or a list of them.
    license: (typeof pkg.license === "string" ? pkg.license : pkg.license?.type) ?? pkg.licenses?.map((l) => l.type).join(" OR ") ?? null,
    url: pkg.homepage ?? (repository ? webAddress(repository) : null),
    // Who holds the copyright, for a package with no license file: "Name <email> (site)" is Name.
    author: (typeof pkg.author === "string" ? pkg.author : pkg.author?.name)?.replace(/\s*[<(].*$/, "").trim() || null,
    text: file ? readFileSync(join(root, file), "utf8") : null,
  };
}

/**
 * The standard wording of the short licenses, for a package that came without its license file
 * (its package.json still names the license and its author): MIT and ISC ask for exactly this
 * notice, with the copyright holder's name, to go with every copy.
 */
const STANDARD = {
  MIT: (holder) => `MIT License

Copyright (c) ${holder}

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.`,
  ISC: (holder) => `ISC License

Copyright (c) ${holder}

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.`,
};

/**
 * A package's license text when it came without a file: the standard wording of each license its
 * package.json names (victory-vendor's "MIT AND ISC" gives both), with its author as the holder. A
 * longer license (Apache-2.0) points to its full text, the same as another package's in this file.
 */
function missingText(p, withText) {
  const ids = (p.license ?? "").replace(/[()]/g, "").split(/\s+(?:AND|OR)\s+/).filter(Boolean);
  const holder = p.author ? `${p.author} and the ${p.name} contributors` : `the ${p.name} contributors`;
  const parts = ids.map((id) => {
    if (STANDARD[id]) return STANDARD[id](holder);
    const same = withText.find((o) => o.license === id && o.name !== p.name);
    return same ? `${id}: its full text is the same as in the section for ${same.name}@${same.version} in this file.` : null;
  });
  const note = `This package came without a license file. Its package.json gives its license as: ${p.license ?? "nothing"}.`;
  return parts.every(Boolean) && parts.length ? [note, ...parts].join("\n\n") : note;
}

/**
 * The packages these files (paths, or a bundler's module ids) came from, each read once. Jobly's
 * own workspace packages (@jobly/*) are left out: they're Jobly, under its own license.
 */
export function packagesIn(files) {
  const roots = new Set(files.map(packageRoot).filter(Boolean));
  return [...roots].map(readPackage).filter((p) => !p.name.startsWith("@jobly/"));
}

const compare = (a, b) => (a < b ? -1 : a > b ? 1 : 0);

/**
 * The notices file: `intro`, then each package once, by name, with its license, address and the
 * full text of its license file. The same packages always make the same file.
 */
export function licensesText(intro, packages) {
  const unique = [...new Map(packages.map((p) => [`${p.name}@${p.version}`, p])).values()];
  unique.sort((a, b) => compare(a.name, b.name) || compare(a.version, b.version));
  const withText = unique.filter((p) => p.text?.trim());
  const sections = unique.map((p) =>
    [
      "-".repeat(80),
      `${p.name}@${p.version}`,
      `License: ${p.license ?? "not stated"}`,
      ...(p.url ? [p.url] : []),
      "",
      p.text?.trim() ? p.text.replace(/\r\n?/g, "\n").trim() : missingText(p, withText),
    ].join("\n"),
  );
  return `${[intro.trim(), ...sections].join("\n\n")}\n`;
}
