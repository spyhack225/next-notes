/**
 * Light/dark on the page. The `<html>` class is the one source of truth: the inline
 * script in `index.html` sets it before first paint, and everything after hydration —
 * the navbar toggle, the orb canvases — reads or flips that same class. A stored choice
 * (`localStorage.theme`) wins; with none, the page follows the system, including live
 * system changes. Canvases cannot read CSS variables themselves, so a change is
 * announced on `window` as `THEME_EVENT` and `Orb` repaints with the new ink.
 */
export type Theme = "light" | "dark";

export const THEME_EVENT = "nextnotes:theme";

const STORAGE_KEY = "theme";

export function getTheme(): Theme {
  return document.documentElement.classList.contains("light") ? "light" : "dark";
}

export function setTheme(theme: Theme, persist = true) {
  document.documentElement.classList.toggle("light", theme === "light");
  document.documentElement.classList.toggle("dark", theme === "dark");
  try {
    if (persist) localStorage.setItem(STORAGE_KEY, theme);
  } catch {
    /* private mode: the class still flips for this visit */
  }
  window.dispatchEvent(new CustomEvent<Theme>(THEME_EVENT, { detail: theme }));
}

export function toggleTheme() {
  setTheme(getTheme() === "dark" ? "light" : "dark");
}

function storedChoice(): Theme | null {
  try {
    const v = localStorage.getItem(STORAGE_KEY);
    return v === "light" || v === "dark" ? v : null;
  } catch {
    return null;
  }
}

/**
 * Calls `listener` on every change, from the toggle or from the system. While the
 * person has not chosen explicitly, a system change flips the page with it; once they
 * have, their choice stands. Returns the unsubscribe.
 */
export function subscribeTheme(listener: (theme: Theme) => void): () => void {
  const onEvent = () => listener(getTheme());
  const system = window.matchMedia("(prefers-color-scheme: dark)");
  const onSystem = () => {
    if (storedChoice() === null) setTheme(system.matches ? "dark" : "light", false);
  };
  window.addEventListener(THEME_EVENT, onEvent);
  system.addEventListener("change", onSystem);
  return () => {
    window.removeEventListener(THEME_EVENT, onEvent);
    system.removeEventListener("change", onSystem);
  };
}
