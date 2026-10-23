import { motion } from "framer-motion";
import Orb from "../components/Orb";
import { DOWNLOAD_URL } from "../lib/motion";

const links = [
  { label: "Who it's for", href: "#who" },
  { label: "How it works", href: "#how-it-works" },
  { label: "Privacy", href: "#privacy" },
  { label: "Benchmarks", href: "?page=benchmarks" },
];

export default function Navbar() {
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

        <a
          href={DOWNLOAD_URL}
          className="hidden md:inline-block shrink-0 text-sm font-medium text-foreground/80 hover:text-foreground transition-colors"
        >
          Download
        </a>
      </nav>
    </motion.header>
  );
}
