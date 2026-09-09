/**
 * One entrance for the whole page, used with staggered delays. Wrapped in a
 * <MotionConfig reducedMotion="user">, so the y-transform is dropped and only the
 * opacity survives when the system asks for less motion.
 */
export const fadeUp = (delay: number) =>
  ({
    initial: { opacity: 0, y: 20 },
    whileInView: { opacity: 1, y: 0 },
    viewport: { once: true, margin: "-100px" },
    transition: { duration: 0.6, delay, ease: "easeOut" },
  }) as const;

export const REPO_URL = "https://github.com/spyhack225/speechify-site";
