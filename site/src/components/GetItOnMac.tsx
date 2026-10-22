import { useState } from "react";
import { motion } from "framer-motion";
import { ArrowUpRight, Send } from "lucide-react";
import { DOWNLOAD_URL, SITE_URL } from "../lib/motion";

/**
 * The main action. On a Mac-sized screen it is the download. On a phone there is nothing
 * to download to, so it becomes a softer action that makes sense there: send this page to
 * yourself, with a line saying what to do next. No form and no email is collected; it
 * uses the phone's own share sheet, or copies the link where that isn't available.
 */
export default function GetItOnMac({ align = "start" }: { align?: "start" | "center" }) {
  const [note, setNote] = useState("Open this page on your Mac to download.");

  async function sendToMyMac() {
    try {
      if (navigator.share) {
        await navigator.share({ title: "Next Notes", text: "Open this on my Mac to get Next Notes.", url: SITE_URL });
        return;
      }
      await navigator.clipboard.writeText(SITE_URL);
      setNote("Link copied. Open it on your Mac to download.");
    } catch {
      /* Closing the share sheet is a choice, not an error: the line below still says what to do. */
    }
  }

  return (
    <div className={`flex flex-col gap-3 ${align === "center" ? "items-center text-center" : "items-start"}`}>
      <motion.a
        href={DOWNLOAD_URL}
        whileHover={{ y: -3 }}
        whileTap={{ scale: 0.98 }}
        className="hidden md:inline-flex items-center gap-3 bg-foreground text-background rounded-full px-7 py-4 text-sm font-medium"
      >
        Download for Mac <ArrowUpRight size={17} aria-hidden="true" />
      </motion.a>
      <button
        type="button"
        onClick={sendToMyMac}
        className="md:hidden inline-flex items-center gap-3 rounded-full border border-foreground/40 px-7 py-4 text-sm font-medium focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-foreground"
      >
        Get it on your Mac <Send size={16} aria-hidden="true" />
      </button>
      <p role="status" className="md:hidden text-sm text-muted-foreground">{note}</p>
    </div>
  );
}
