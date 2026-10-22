import { DOWNLOAD_URL, REPO_URL } from "../lib/motion";

export default function Footer() {
  return (
    <footer className="py-10 px-6 sm:px-8 md:px-28 border-t border-border/30">
      <div className="flex items-center justify-between gap-x-6 gap-y-3 flex-wrap">
        <p className="text-muted-foreground text-sm">
          &copy; 2026 Next Notes. Your assistant, on your Mac.
        </p>
        <div className="flex items-center gap-5 text-sm text-muted-foreground">
          <a href="?page=benchmarks" className="hover:text-foreground transition-colors">
            Benchmarks
          </a>
          <a href={DOWNLOAD_URL} className="hidden md:inline hover:text-foreground transition-colors">
            Download
          </a>
          <a href={REPO_URL} target="_blank" rel="noreferrer" className="hover:text-foreground transition-colors">
            Check how it&apos;s built
          </a>
        </div>
      </div>
    </footer>
  );
}
