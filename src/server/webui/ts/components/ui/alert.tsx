//! shadcn Alert: the failure and success notices the dashboard and the modlet
//! panel show (registry source, ui.shadcn.com, new-york, v4). The registry's
//! two variants plus `success`, because the deck reports saved modlet changes
//! as well as failures, and both are soft fills on this palette.

import type { JSX } from "preact";
import { cva, type VariantProps } from "class-variance-authority";
import { cn } from "@/lib/utils";

export const alertVariants = cva(
    "relative grid w-full grid-cols-[0_1fr] items-start gap-y-0.5 rounded-card border px-4 py-3.5 font-sans text-body2 leading-card",
    {
        variants: {
            variant: {
                default: "border-border bg-muted text-foreground",
                destructive: "border-destructive-border bg-destructive-soft text-destructive-foreground",
                success: "border-success-border bg-accent text-accent-foreground",
            },
        },
        defaultVariants: {
            variant: "default",
        },
    },
);

export type AlertProps = JSX.IntrinsicElements["div"] & VariantProps<typeof alertVariants>;

function Alert({ className, variant, role, ...props }: AlertProps) {
    // The registry hardcodes role="alert"; the deck distinguishes the two live
    // regions (a failure announces, a success is polite), so role is a prop.
    return <div data-slot="alert" data-variant={variant ?? "default"} role={role ?? "alert"} className={cn(alertVariants({ variant }), className)} {...props} />;
}

function AlertDescription({ className, ...props }: JSX.IntrinsicElements["div"]) {
    return <div data-slot="alert-description" className={cn("col-start-2 grid justify-items-start gap-1", className)} {...props} />;
}

export { Alert, AlertDescription };
