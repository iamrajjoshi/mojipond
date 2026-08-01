export interface ReleaseManifest {
  version: string;
  asset: {
    byteCount: number;
  };
}

const semanticVersionPattern = /^\d+\.\d+\.\d+$/;

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

export const parseReleaseManifest = (
  value: unknown,
): ReleaseManifest | undefined => {
  if (!isRecord(value) || !isRecord(value.asset)) return undefined;

  const { version, asset } = value;
  if (
    typeof version !== "string" ||
    !semanticVersionPattern.test(version) ||
    typeof asset.byteCount !== "number" ||
    !Number.isSafeInteger(asset.byteCount) ||
    asset.byteCount <= 0
  ) {
    return undefined;
  }

  return {
    version,
    asset: { byteCount: asset.byteCount },
  };
};
