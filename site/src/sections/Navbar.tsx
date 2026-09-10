import { Github } from "lucide-react";
import { motion } from "framer-motion";
import Orb from "../components/Orb";
import { REPO_URL } from "../lib/motion";

const links = [
  { label: "How it works", href: "#how-it-works" },
  { label: "Meetings", href: "#meetings" },
  { label: "Privacy", href: "#privacy" },
];

export default function Navbar() {
  return (
    <motion.header
      initial={{ opacity: 0, y: -12 }}
      animate={{ opacity: 1, y: 0 }}
      transition={{ duration: 0.6, ease: "easeOut" }}
      className="fixed top-0 left-0 right-0 z-50 px-8 md:px-28 py-4"
    >
      <nav className="flex items-center justify-between gap-6">
        <a href="#top" className="flex items-center gap-2.5 shrink-0">
          <Orb size={28} />
          <span className="font-bold tracking-[-0.02em]">Next Notes</span>
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
          href={REPO_URL}
          target="_blank"
          rel="noreferrer"
          aria-label="Next Notes on GitHub"
          className="liquid-glass w-10 h-10 rounded-full flex items-center justify-center shrink-0 text-foreground/80 hover:text-foreground transition-colors"
        >
          <Github className="w-[18px] h-[18px]" strokeWidth={1.6} />
        </a>
      </nav>
    </motion.header>
  );
}
