import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Served from the root of its own domain — https://next-notes.com/ — on DigitalOcean App
// Platform, which publishes `docs/` as the site root. No repo-name prefix: that was needed
// only while this was a GitHub Pages *project* page, and carrying it here asks the browser
// for every asset one directory too deep.
export default defineConfig({
  // Relative, deliberately. Production is next-notes.com on DigitalOcean, a domain root,
  // where "/" would work just as well — this once had to serve a GitHub Pages copy under a
  // /<repo>/ subpath too, and that copy is gone now. Kept relative anyway: it costs nothing
  // and it means the build does not care what path it is mounted at, which is the property
  // that broke the site the last time this file assumed one.
  base: "./",
  build: {
    // Built straight into the directory the App Platform static site serves (`docs/`), so
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
