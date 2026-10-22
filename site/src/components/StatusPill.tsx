/**
 * The honest status of one capability. The page sells the whole vision and labels every
 * part of it, so a future capability is never read as shipped.
 *
 * The site has one ink and no status hues (DESIGN-SYSTEM.md §1), so the three states are
 * told apart by weight alone: filled ink for what works today, an outline for what is
 * being built, a dashed outline in muted ink for what is planned. The dot repeats it for
 * anyone reading the shape rather than the word.
 */
export type Availability = "now" | "progress" | "soon";

const LABEL: Record<Availability, string> = {
  now: "Available now",
  progress: "In progress",
  soon: "Coming soon",
};

const PILL: Record<Availability, string> = {
  now: "border-foreground bg-foreground text-background",
  progress: "border-foreground/50 text-foreground",
  soon: "border-dashed border-muted-foreground/60 text-muted-foreground",
};

const DOT: Record<Availability, string> = {
  now: "bg-background",
  progress: "bg-foreground",
  soon: "border border-muted-foreground",
};

export const AVAILABILITY_ORDER: Availability[] = ["now", "progress", "soon"];

export const AVAILABILITY_MEANING: Record<Availability, string> = {
  now: "Works in the app today",
  progress: "Being built right now",
  soon: "Planned next",
};

/**
 * `quiet` is for places where the dream should lead, like the hero demo: no outline, no
 * capitals, muted ink and a smaller dot. It still names the status and keeps the same dot
 * shapes, so the three states stay distinct. Full pills carry the legend everywhere else.
 */
export type StatusPillVariant = "full" | "quiet";

const QUIET_DOT: Record<Availability, string> = {
  now: "bg-muted-foreground",
  progress: "border border-muted-foreground",
  soon: "border border-muted-foreground/50",
};

export default function StatusPill({
  status,
  variant = "full",
  className = "",
}: {
  status: Availability;
  variant?: StatusPillVariant;
  className?: string;
}) {
  if (variant === "quiet") {
    return (
      <span className={`inline-flex shrink-0 items-center gap-1.5 whitespace-nowrap text-micro text-muted-foreground ${className}`}>
        <span className={`h-1 w-1 rounded-full ${QUIET_DOT[status]}`} aria-hidden="true" />
        {LABEL[status]}
      </span>
    );
  }
  return (
    <span
      className={`inline-flex shrink-0 items-center gap-1.5 whitespace-nowrap rounded-full border px-2.5 py-1 text-micro font-medium uppercase tracking-caption ${PILL[status]} ${className}`}
    >
      <span className={`h-1.5 w-1.5 rounded-full ${DOT[status]}`} aria-hidden="true" />
      {LABEL[status]}
    </span>
  );
}
