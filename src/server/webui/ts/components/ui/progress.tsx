//! shadcn Progress (registry source, ui.shadcn.com, new-york, v4) for the
//! glance band's tick-p99 meter. The registry's indicator translates a
//! full-width bar; this one scales a left-anchored bar, which is the same
//! read with one less property and no reflow. `value` is a percentage of `max`
//! and the component owns the transform, so the only thing the page passes is
//! the number and the tone.

import type { JSX } from "preact";
import { cn } from "@/lib/utils";

const PERCENT_SCALE = 100;

function Progress({
    className,
    indicatorClassName,
    value,
    tone = "default",
    ...props
}: JSX.IntrinsicElements["div"] & {
    indicatorClassName?: string;
    /** Filled share of `max`, 0 to max. */
    value: number;
    tone?: "default" | "destructive";
}) {
    const fill = Math.min(1, Math.max(0, value));
    const indicator = tone === "destructive" ? "bg-destructive" : "bg-primary";
    return (
        <div
            data-slot="progress"
            role="progressbar"
            aria-valuenow={Math.round(fill * PERCENT_SCALE)}
            aria-valuemin={0}
            aria-valuemax={PERCENT_SCALE}
            className={cn("h-2.5 w-full overflow-hidden rounded-full border border-border bg-muted", className)}
            {...props}
        >
            {/* oxlint-disable-next-line shadcn/no-inline-styles -- the fill is a per-poll number; the allowed transform prop is where it belongs */}
            <div
                data-slot="progress-indicator"
                className={cn("h-full w-full origin-left rounded-full", indicator, indicatorClassName)}
                style={{ transform: `scaleX(${fill})` }}
            />
        </div>
    );
}

export { Progress };
