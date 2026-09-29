//! shadcn Card: the panel every dashboard section and the glance band are
//! built from. Registry source (ui.shadcn.com, new-york, v4) restyled to the
//! paper cockpit, with three adaptations the deck needs:
//!   * CardTitle and CardDescription render <h2> and <p> rather than <div>, so
//!     a card that is a page section keeps a real heading in the document
//!     outline (the registry's div would drop it);
//!   * CardAction is dropped: no card here has a corner action;
//!   * the registry's gap-6 / py-6 chrome gives way to the deck's spacing,
//!     which the section headers own.

import type { JSX } from "preact";
import { cn } from "@/lib/utils";

function Card({ className, ...props }: JSX.IntrinsicElements["div"]) {
    return <div data-slot="card" className={cn("flex flex-col overflow-hidden rounded-card border border-border bg-card text-card-foreground shadow-card", className)} {...props} />;
}

function CardHeader({ className, ...props }: JSX.IntrinsicElements["div"]) {
    return <div data-slot="card-header" className={cn("grid auto-rows-min grid-rows-[auto_auto] items-start gap-2 px-5 pt-4 pb-1", className)} {...props} />;
}

function CardTitle({ className, children, ...props }: JSX.IntrinsicElements["h2"]) {
    return (
        <h2 data-slot="card-title" className={cn("m-0 font-sans text-h3 font-semibold tracking-tight1 text-foreground", className)} {...props}>
            {children}
        </h2>
    );
}

function CardDescription({ className, ...props }: JSX.IntrinsicElements["p"]) {
    return <p data-slot="card-description" className={cn("m-0 text-muted-foreground font-sans text-body2 max-md:break-words", className)} {...props} />;
}

function CardContent({ className, ...props }: JSX.IntrinsicElements["div"]) {
    return <div data-slot="card-content" className={cn("p-0", className)} {...props} />;
}

function CardFooter({ className, ...props }: JSX.IntrinsicElements["div"]) {
    return <div data-slot="card-footer" className={cn("flex items-center px-5 pb-2.5", className)} {...props} />;
}

export { Card, CardHeader, CardFooter, CardTitle, CardDescription, CardContent };
