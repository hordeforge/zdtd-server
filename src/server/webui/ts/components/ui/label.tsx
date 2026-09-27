//! shadcn Label (registry source, ui.shadcn.com, new-york, v4) as a plain
//! <label>: the registry wraps radix Label for the `peer-disabled` plumbing,
//! which no label here needs (the dashboard has no disabled field), so the
//! radix dependency does not come with it.

import type { JSX } from "preact";
import { cn } from "@/lib/utils";

function Label({ className, ...props }: JSX.IntrinsicElements["label"]) {
    return <label data-slot="label" className={cn("inline-flex min-h-[44px] cursor-pointer items-center gap-1.5 font-sans text-body2 font-medium text-muted-foreground select-none", className)} {...props} />;
}

export { Label };
