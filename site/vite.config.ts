import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// The site is served from a project page, not a user page, so every asset URL has to
// carry the repo name: https://spyhack225.github.io/speechify-site/
export default defineConfig({
  base: "/speechify-site/",
  build: {
    // Built straight into the directory GitHub Pages already serves (`main` `/docs`), so
    // publishing is a commit rather than a CI run, and what was previewed locally is
    // byte-for-byte what ships.
    outDir: "../docs",
    // Deliberately NOT emptied. `docs/` also holds PARAKEET-WINDOWS.md and
    // S1-MINI-WINDOWS.md, which are engineering notes linked from README.md, AGENTS.md and
    // windows/README.md — wiping the directory would delete them and break four links. The
    // build script removes `docs/assets` instead, which is the only part that accumulates.
    emptyOutDir: false,
  },
  plugins: [react()],
});
