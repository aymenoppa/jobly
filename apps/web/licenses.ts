import { createRequire } from "node:module";
import { join, resolve } from "node:path";
import type { Plugin } from "vite";
import { licensesText, packagesIn } from "../../scripts/licenses.mjs";

const INTRO = `Open-source software in Jobly's web app

This lists the open-source software included in Jobly's web app, and its licenses. Jobly itself
is free software under the GNU Affero General Public License, version 3, with additional terms: see
/license on this server.`;

/**
 * Writes licenses.txt at the root of the built app (the server serves it at /licenses.txt, linked
 * from the license notice in features/legal/License.tsx): every npm package whose code, styles,
 * fonts or other files are in the build, with its license text (scripts/licenses.mjs).
 */
export function licenses(): Plugin {
  let root = process.cwd();
  return {
    name: "jobly-licenses",
    apply: "build",
    configResolved(config) {
      root = config.root;
    },
    generateBundle(_options, bundle) {
      // The icons in components/ui/phosphor.ts are copied out of @phosphor-icons/core
      // (scripts/icons.mjs), so none of that package's own files is in the bundle.
      const files = [createRequire(join(root, "package.json")).resolve("@phosphor-icons/core")];
      for (const output of Object.values(bundle)) {
        if (output.type === "chunk") files.push(...output.moduleIds);
        // Files imported with ?url (a wasm, a worker) and fonts a stylesheet points at. Vite names
        // them from its root.
        else files.push(...(output.originalFileNames ?? []).map((name) => resolve(root, name)));
      }
      this.emitFile({ type: "asset", fileName: "licenses.txt", source: licensesText(INTRO, packagesIn(files)) });
    },
  };
}
