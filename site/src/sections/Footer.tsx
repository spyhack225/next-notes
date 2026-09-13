import { Github } from "lucide-react";
import { DOWNLOAD_URL, REPO_URL } from "../lib/motion";

export default function Footer() {
  return (
    <footer className="py-12 px-8 md:px-28 border-t border-border/30">
      <div className="flex items-center justify-between gap-6 flex-wrap">
        <p className="text-muted-foreground text-sm">
          &copy; 2026 Next Notes. Runs entirely on your Mac.
        </p>
        <div className="flex items-center gap-4">
          <a
            href={DOWNLOAD_URL}
            className="text-sm text-muted-foreground hover:text-foreground transition-colors"
          >
            Download
          </a>
          <a
            href={REPO_URL}
            target="_blank"
            rel="noreferrer"
            aria-label="Next Notes on GitHub"
            className="liquid-glass w-10 h-10 rounded-full flex items-center justify-center text-foreground/80 hover:text-foreground transition-colors"
          >
            <Github className="w-[18px] h-[18px]" strokeWidth={1.6} />
          </a>
        </div>
      </div>
    </footer>
  );
}
