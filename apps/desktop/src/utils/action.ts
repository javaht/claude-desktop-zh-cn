export function waitForPaint() {
  return new Promise<void>((resolve) => {
    requestAnimationFrame(() => requestAnimationFrame(() => resolve()));
  });
}

export function createActionId(name: string) {
  return `${name}-${Date.now()}-${Math.random().toString(36).slice(2)}`;
}
