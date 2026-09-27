//! shadcn class merge helper: the one way component classes are combined.
//! `cn` is on @shadcn/lint's built-in class-function list, so the linter
//! resolves the classes passed through it (see .oxlintrc.jsonc settings.shadcn).

import { clsx, type ClassValue } from "clsx";
import { twMerge } from "tailwind-merge";

/** Join conditional class values, then let the last Tailwind utility win. */
export function cn(...inputs: Array<ClassValue>): string {
    return twMerge(clsx(inputs));
}
