/**
 * The open-source licenses that go with Jobly's builds (scripts/licenses.mjs): licenses.txt next
 * to the web app (apps/web/licenses.ts) and server-licenses.txt next to the server
 * (scripts/build-server.mjs), each package found from the files bundled and listed with its license text.
 */
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { licenseFile, licensesText, packageRoot, packagesIn, webAddress, type Package } from "../../../scripts/licenses.mjs";

describe("packageRoot", () => {
  it("finds the package a bundled file is in, scoped or not", () => {
    expect(packageRoot("/repo/node_modules/react/cjs/react.production.min.js")).toBe("/repo/node_modules/react");
    expect(packageRoot("/repo/node_modules/@base-ui/react/esm/index.js")).toBe("/repo/node_modules/@base-ui/react");
  });
  it("takes the innermost copy when one is nested in another folder", () => {
    expect(packageRoot("/repo/apps/web/node_modules/vite/dist/client/env.mjs")).toBe("/repo/apps/web/node_modules/vite");
    expect(packageRoot("/repo/node_modules/a/node_modules/@s/b/lib/c.js")).toBe("/repo/node_modules/a/node_modules/@s/b");
  });
  it("reads Vite's module ids and Windows paths", () => {
    expect(packageRoot("\0/repo/node_modules/laz-perf/lib/web/index.js?commonjs-proxy")).toBe("/repo/node_modules/laz-perf");
    expect(packageRoot("/repo/node_modules/@fontsource-variable/figtree/index.css?used")).toBe("/repo/node_modules/@fontsource-variable/figtree");
    expect(packageRoot("C:\\repo\\node_modules\\dompurify\\dist\\purify.es.mjs")).toBe("C:/repo/node_modules/dompurify");
  });
  it("leaves out Jobly's own code and a bundler's helpers", () => {
    expect(packageRoot("/repo/apps/web/src/main.tsx")).toBeNull();
    expect(packageRoot("/repo/packages/core/src/money.ts")).toBeNull();
    expect(packageRoot("\0vite/preload-helper.js")).toBeNull();
    expect(packageRoot("/repo/node_modules/.vite/deps/react.js")).toBeNull();
  });
});

describe("licenseFile", () => {
  it("picks LICENSE, LICENCE or COPYING, bare or as .md or .txt, in any case", () => {
    expect(licenseFile(["README.md", "package.json", "LICENSE"])).toBe("LICENSE");
    expect(licenseFile(["index.js", "license.md"])).toBe("license.md");
    expect(licenseFile(["LICENCE.txt"])).toBe("LICENCE.txt");
    expect(licenseFile(["Copying.TXT"])).toBe("Copying.TXT");
  });
  it("prefers those to one like LICENSE-MIT, and picks the same whatever order the folder lists", () => {
    expect(licenseFile(["LICENSE-MIT", "LICENSE.md"])).toBe("LICENSE.md");
    expect(licenseFile(["LICENSE-MIT", "LICENSE-APACHE"])).toBe("LICENSE-APACHE");
    expect(licenseFile(["LICENSE-APACHE", "LICENSE-MIT"])).toBe("LICENSE-APACHE");
  });
  it("finds none when there isn't one", () => {
    expect(licenseFile(["README.md", "package.json", "licensing.js"])).toBeNull();
  });
});

describe("webAddress", () => {
  it("turns package.json's repository into an address to open", () => {
    expect(webAddress("git+https://github.com/a/b.git")).toBe("https://github.com/a/b");
    expect(webAddress("git@github.com:yisibl/resvg-js")).toBe("https://github.com/yisibl/resvg-js");
    expect(webAddress("git://github.com/a/b.git")).toBe("https://github.com/a/b");
    expect(webAddress("github:a/b")).toBe("https://github.com/a/b");
    expect(webAddress("a/b")).toBe("https://github.com/a/b");
  });
});

describe("licensesText", () => {
  const pkg = (name: string, version: string, extra: Partial<Package> = {}): Package => ({ name, version, license: "MIT", url: null, text: `Copyright (c) ${name}\r\n\r\nPermission is hereby granted\r\n`, ...extra });
  const packages = [
    pkg("react-dom", "18.3.1"),
    pkg("react", "18.3.1", { url: "https://react.dev/" }),
    pkg("@base-ui/react", "1.9.0"),
    pkg("react", "18.3.1", { url: "https://react.dev/" }),
    pkg("splaytree", "3.2.3", { text: null }),
  ];
  it("lists each package once, by name, with its license, address and full license text", () => {
    const text = licensesText("Open-source software\n\nWhat this is.\n", packages);
    expect(text.startsWith(
      [
        "Open-source software\n\nWhat this is.",
        `${"-".repeat(80)}\n@base-ui/react@1.9.0\nLicense: MIT\n\nCopyright (c) @base-ui/react\n\nPermission is hereby granted`,
        `${"-".repeat(80)}\nreact@18.3.1\nLicense: MIT\nhttps://react.dev/\n\nCopyright (c) react\n\nPermission is hereby granted`,
        `${"-".repeat(80)}\nreact-dom@18.3.1\nLicense: MIT\n\nCopyright (c) react-dom\n\nPermission is hereby granted`,
      ].join("\n\n") + "\n\n",
    )).toBe(true);
    // No license file: the standard wording of the license its package.json names.
    expect(text).toContain(
      `${"-".repeat(80)}\nsplaytree@3.2.3\nLicense: MIT\n\nThis package came without a license file. Its package.json gives its license as: MIT.\n\nMIT License\n\nCopyright (c) the splaytree contributors\n\nPermission is hereby granted, free of charge`,
    );
  });

  it("gives a package without a license file its author, each license it names, and a longer one's full text from elsewhere", () => {
    const text = licensesText("Intro", [
      pkg("victory-vendor", "37.3.6", { license: "MIT AND ISC", author: "Formidable", text: null }),
      pkg("laz-perf", "0.0.7", { license: "Apache-2.0", text: null }),
      pkg("pdfjs-dist", "6.4.299", { license: "Apache-2.0", text: "Apache License\nVersion 2.0" }),
    ]);
    expect(text).toContain("MIT License\n\nCopyright (c) Formidable and the victory-vendor contributors");
    expect(text).toContain("ISC License\n\nCopyright (c) Formidable and the victory-vendor contributors");
    expect(text).toContain("Apache-2.0: its full text is the same as in the section for pdfjs-dist@6.4.299 in this file.");
  });
  it("writes the same file whatever order the packages come in", () => {
    expect(licensesText("Intro", [...packages].reverse())).toBe(licensesText("Intro", packages));
  });
});

describe("packagesIn", () => {
  let dir = "";
  afterEach(() => rmSync(dir, { recursive: true, force: true }));
  const write = (path: string, text: string) => {
    mkdirSync(join(dir, path, ".."), { recursive: true });
    writeFileSync(join(dir, path), text);
  };

  it("reads each package once from its package.json and license file, and leaves out Jobly's own", () => {
    dir = mkdtempSync(join(tmpdir(), "licenses-"));
    write("node_modules/a/package.json", JSON.stringify({ name: "a", version: "1.0.0", license: "MIT", repository: { url: "git+https://github.com/x/a.git" } }));
    write("node_modules/a/LICENSE.md", "MIT License a");
    write("node_modules/a/node_modules/b/package.json", JSON.stringify({ name: "b", version: "2.0.0", licenses: [{ type: "ISC" }], homepage: "https://b.dev" }));
    write("node_modules/@jobly/core/package.json", JSON.stringify({ name: "@jobly/core", version: "0.1.0", license: "AGPL-3.0-only" }));
    const files = ["node_modules/a/index.js", "node_modules/a/lib/x.js", "node_modules/a/node_modules/b/index.js", "node_modules/@jobly/core/src/i18n.ts", "apps/web/src/main.tsx"];

    expect(packagesIn(files.map((f) => join(dir, f)))).toEqual([
      { name: "a", version: "1.0.0", license: "MIT", url: "https://github.com/x/a", author: null, text: "MIT License a" },
      { name: "b", version: "2.0.0", license: "ISC", url: "https://b.dev", author: null, text: null },
    ]);
  });
});
