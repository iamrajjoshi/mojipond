import { writeFile } from "node:fs/promises";
import { resolve } from "node:path";

import { parseReleaseManifest } from "../src/lib/releaseManifest.ts";

const [version, byteCountValue, outputPath] = process.argv.slice(2);

if (!version || !byteCountValue || !outputPath) {
  throw new Error(
    "Usage: write-release-manifest.ts <version> <byte-count> <output-path>",
  );
}

const manifest = parseReleaseManifest({
  version,
  asset: { byteCount: Number(byteCountValue) },
});
if (!manifest) throw new Error("Release metadata is invalid.");

await writeFile(resolve(outputPath), `${JSON.stringify(manifest, null, 2)}\n`, {
  encoding: "utf8",
  flag: "wx",
});
