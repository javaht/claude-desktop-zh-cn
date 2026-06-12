export function normalizeVersion(version: string) {
  return version.trim().replace(/^v/i, "");
}

export function compareVersions(left: string, right: string) {
  const a = normalizeVersion(left).split(/[.-]/).map((part) => Number.parseInt(part, 10) || 0);
  const b = normalizeVersion(right).split(/[.-]/).map((part) => Number.parseInt(part, 10) || 0);
  const length = Math.max(a.length, b.length);

  for (let index = 0; index < length; index += 1) {
    const diff = (a[index] ?? 0) - (b[index] ?? 0);
    if (diff !== 0) {
      return diff;
    }
  }

  return 0;
}
