//! shadcn Input (registry source, ui.shadcn.com, new-york, v4) with the
//! dashboard command field's own shape: mono type, the 2px edge border, and the
//! 44px target. The hint color of an empty field is the theme's `cmd-hint`
//! utility on the form, so the input itself carries none.

import type { JSX } from "preact";
import { cn } from "@/lib/utils";

function Input({ className, type, ...props }: JSX.IntrinsicElements["input"]) {
    return (
        <input
            type={type ?? "text"}
            data-slot="input"
            className={cn(
                "min-h-[44px] w-full min-w-40 flex-none rounded-ctl border-2 border-input bg-card px-3 py-2.5 font-mono text-foreground hover:border-muted-foreground focus:border-ring",
                className,
            )}
            {...props}
        />
    );
}

export { Input };
