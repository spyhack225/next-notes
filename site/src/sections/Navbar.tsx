import { Github, Moon, Sun } from "lucide-react";
import { motion } from "framer-motion";
import { useEffect, useState } from "react";
import Orb from "../components/Orb";
import { DOWNLOAD_URL, REPO_URL } from "../lib/motion";
import { getTheme, subscribeTheme, toggleTheme, type Theme } from "../lib/theme";

const links = [
  { label: "One companion", href: "#impact" },
  { label: "A meeting", href: "#how-it-works" },
  { label: "Your trust", href: "#privacy" },
];

export default function Navbar() {
  const [theme, setTheme] = useState<Theme>(getTheme);

  useEffect(() => subscribeTheme(setTheme), []);

  return (
    <motion.header
      initial={{ opacity: 0, y: -12 }}
      animate={{ opacity: 1, y: 0 }}
      transition={{ duration: 0.6, ease: "easeOut" }}
      className="fixed top-0 left-0 right-0 z-50 px-6 sm:px-8 md:px-16 lg:px-28 py-4 bg-background/90 backdrop-blur-xl border-b border-border/40"
    >
      <nav className="flex items-center justify-between gap-6">
        <a href="#top" className="flex items-center gap-2.5 shrink-0">
          <Orb size={28} />
          <span className="font-bold tracking-logo">Next Notes</span>
        </a>

        <div className="hidden md:flex items-center gap-3 text-sm">
          {links.map((link, i) => (
            <span key={link.href} className="flex items-center gap-3">
              {i > 0 && <span className="text-muted-foreground/50">&bull;</span>}
              <a
                href={link.href}
                className="text-muted-foreground hover:text-foreground transition-colors"
              >
                {link.label}
              </a>
            </span>
          ))}
        </div>

        <div className="flex items-center gap-3 shrink-0">
          <a
            href={DOWNLOAD_URL}
            className="hidden sm:inline-block text-sm font-medium text-foreground/80 hover:text-foreground transition-colors"
          >
            Download
          </a>
          <button
            type="button"
            onClick={toggleTheme}
            aria-label={theme === "dark" ? "Switch to light mode" : "Switch to dark mode"}
            className="liquid-glass w-10 h-10 rounded-full flex items-center justify-center text-foreground/80 hover:text-foreground transition-colors"
          >
            {theme === "dark" ? (
              <Sun className="w-4.5 h-4.5" strokeWidth={1.6} />
            ) : (
              <Moon className="w-4.5 h-4.5" strokeWidth={1.6} />
            )}
          </button>
          <a
            href={REPO_URL}
            target="_blank"
            rel="noreferrer"
            aria-label="Next Notes on GitHub"
            className="liquid-glass w-10 h-10 rounded-full flex items-center justify-center text-foreground/80 hover:text-foreground transition-colors"
          >
            <Github className="w-4.5 h-4.5" strokeWidth={1.6} />
          </a>
        </div>
      </nav>
    </motion.header>
  );
}
