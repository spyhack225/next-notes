/**
 * The page is always light, like the app: black ink on white (DESIGN-SYSTEM.md §1). The
 * `light` class on `<html>` is set in `index.html` before first paint and never changes,
 * so there is no toggle and no system-following. `Orb` and the hero's border beam still
 * read the theme through these two functions, so a future theme change has one place to
 * land.
 */
export type Theme = "light" | "dark";

export function getTheme(): Theme {
  return document.documentElement.classList.contains("dark") ? "dark" : "light";
}

/** The theme never changes while the page is open; the unsubscribe is a no-op. */
export function subscribeTheme(listener: (theme: Theme) => void): () => void {
  void listener;
  return () => {};
}
