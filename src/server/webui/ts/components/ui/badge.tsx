//! shadcn Badge: the state pill the dashboard puts beside every signal
//! (registry source, ui.shadcn.com, new-york, v4, minus asChild and so without
//! radix Slot). shadcn's `destructive` is a solid fill; the paper cockpit
//! states are soft fills with a border, so the variant set is the deck's four
//! states over that shape. `default` is the soft signal green, not the solid
//! primary: a solid green pill would read as an action, not a state.

import type { JSX } from "preact";
import { cva, type VariantProps } from "class-variance-authority";
import { cn } from "@/lib/utils";

export type BadgeTone = "ok" | "warn" | "bad" | "";

export const badgeVariants = cva(
    "inline-flex w-fit shrink-0 items-center justify-center gap-1 overflow-hidden rounded-full border px-2.5 py-1 font-sans text-body2 font-semibold tracking-pill whitespace-nowrap",
    {
        variants: {
            variant: {
                default: "border-success-border bg-accent text-accent-foreground",
                secondary: "border-border-strong bg-muted text-muted-foreground",
                outline: "border-border bg-transparent text-foreground",
                success: "border-success-border bg-accent text-accent-foreground",
                warning: "border-warning-border bg-warning-soft text-warning",
                destructive: "border-destructive-border bg-destructive-soft text-destructive-foreground",
            },
        },
        defaultVariants: {
            variant: "default",
        },
    },
);

export type BadgeProps = JSX.IntrinsicElements["span"] & VariantProps<typeof badgeVariants>;

/** Map a dashboard tone to its badge variant. */
export function toneToVariant(tone: BadgeTone): NonNullable<BadgeProps["variant"]> {
    if (tone === "ok") {
        return "success";
    }
    if (tone === "warn") {
        return "warning";
    }
    if (tone === "bad") {
        return "destructive";
    }
    return "secondary";
}

function Badge({ className, variant, ...props }: BadgeProps) {
    return <span data-slot="badge" data-variant={variant ?? "default"} className={cn(badgeVariants({ variant }), className)} {...props} />;
}

export { Badge };
