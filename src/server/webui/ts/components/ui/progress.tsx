//! shadcn Progress (registry source, ui.shadcn.com, new-york, v4) for the
//! glance band's tick-p99 meter, as a native <progress>: the element carries
//! the progressbar role and its value range itself, so neither the radix
//! dependency nor an inline transform comes with it. `value` is the filled
//! share, 0 to 1.

import type { JSX } from "preact";
import { cn } from "@/lib/utils";

const TONE_CLASS = {
    default: "[&::-moz-progress-bar]:bg-primary [&::-webkit-progress-value]:bg-primary",
    destructive: "[&::-moz-progress-bar]:bg-destructive [&::-webkit-progress-value]:bg-destructive",
} as const;

function Progress({
    className,
    value,
    tone = "default",
    ...props
}: Omit<JSX.IntrinsicElements["progress"], "value" | "max"> & {
    /** Filled share, 0 to 1; clamped. */
    value: number;
    tone?: keyof typeof TONE_CLASS;
}) {
    return (
        <progress
            data-slot="progress"
            value={Math.min(1, Math.max(0, value))}
            max={1}
            className={cn(
                "block h-2.5 w-full appearance-none overflow-hidden rounded-full border border-border bg-muted [&::-moz-progress-bar]:rounded-full [&::-webkit-progress-bar]:bg-muted [&::-webkit-progress-value]:rounded-full",
                TONE_CLASS[tone],
                className,
            )}
            {...props}
        />
    );
}

export { Progress };
