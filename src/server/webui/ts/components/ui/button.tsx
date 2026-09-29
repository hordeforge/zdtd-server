//! shadcn Button. The registry source (ui.shadcn.com, new-york, v4) restyled
//! to the paper cockpit and its 44px minimum touch target, minus `asChild`
//! (nothing here composes a button onto another element) and so without the
//! radix Slot dependency. The visible focus ring is the theme's
//! `:focus-visible` outline in webui.css, which every focusable gets, so the
//! component does not re-declare one.
//!
//! `className` (not Preact's `class`) is the merge prop on purpose: it is what
//! @shadcn/lint reads to compare a call site's classes against this component.

import type { JSX } from "preact";
import { cva, type VariantProps } from "class-variance-authority";
import { cn } from "@/lib/utils";

export const buttonVariants = cva(
    "inline-flex shrink-0 cursor-pointer items-center justify-center gap-2 rounded-ctl border font-sans font-semibold whitespace-nowrap disabled:pointer-events-none disabled:opacity-45",
    {
        variants: {
            variant: {
                default: "border-primary bg-primary text-primary-foreground hover:bg-accent-foreground",
                outline: "border-input bg-card text-foreground hover:bg-muted",
                ghost: "border-transparent bg-transparent text-muted-foreground hover:bg-muted hover:text-foreground",
                destructive: "border-destructive-border bg-destructive-soft text-destructive-foreground hover:bg-destructive hover:text-primary-foreground",
            },
            size: {
                sm: "min-h-[44px] rounded-full px-3.5 py-1.5 font-mono text-body2 font-medium",
                default: "min-h-[44px] px-4 py-2 text-ui",
                lg: "min-h-[44px] min-w-[4.5rem] px-5 text-ui",
            },
        },
        defaultVariants: {
            variant: "default",
            size: "default",
        },
    },
);

// A button defaults to type="button": the registry leaves it untyped, and an
// untyped button inside a form submits by accident. No reset buttons here.
export type ButtonProps = Omit<JSX.IntrinsicElements["button"], "type"> & VariantProps<typeof buttonVariants> & { type?: "button" | "submit" };

function Button({ className, variant, size, type, ...props }: ButtonProps) {
    return (
        <button
            data-slot="button"
            data-variant={variant ?? "default"}
            data-size={size ?? "default"}
            className={cn(buttonVariants({ variant, size }), className)}
            type={type === "submit" ? "submit" : "button"}
            {...props}
        />
    );
}

export { Button };
