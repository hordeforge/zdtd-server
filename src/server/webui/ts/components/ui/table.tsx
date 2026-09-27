//! shadcn Table (registry source, ui.shadcn.com, new-york, v4) with the
//! ledger's own density: 14px body, a muted head row, and hairline row rules.
//! The registry's scroll container is narrowed to a width-constrained box: the
//! ledgers already scroll horizontally inside their card's own region, and two
//! nested scrollers are worse than one. The registry's TableFooter and
//! TableCaption text styles are dropped, this deck has neither (the caption is
//! the visually hidden table name, so it keeps the screen-reader-only form).

import type { JSX } from "preact";
import { cn } from "@/lib/utils";

function Table({ className, ...props }: JSX.IntrinsicElements["table"]) {
    return (
        <div data-slot="table-container" className="relative w-full">
            <table data-slot="table" className={cn("w-full border-collapse text-body2", className)} {...props} />
        </div>
    );
}

function TableHeader({ className, ...props }: JSX.IntrinsicElements["thead"]) {
    return <thead data-slot="table-header" className={cn("[&_tr]:border-b", className)} {...props} />;
}

function TableBody({ className, ...props }: JSX.IntrinsicElements["tbody"]) {
    return <tbody data-slot="table-body" className={cn("[&_tr:last-child]:border-b-0", className)} {...props} />;
}

function TableRow({ className, ...props }: JSX.IntrinsicElements["tr"]) {
    return <tr data-slot="table-row" className={cn("border-b border-border hover:bg-muted/50", className)} {...props} />;
}

const HEAD_CLASS = "bg-muted px-3.5 py-3 text-left font-sans text-hud font-semibold tracking-eyebrow text-muted-foreground uppercase whitespace-nowrap";

function TableHead({ className, ...props }: JSX.IntrinsicElements["td"]) {
    return <th data-slot="table-head" className={cn(HEAD_CLASS, className)} {...props} />;
}

const CELL_CLASS = "border-b border-border px-3.5 py-3 text-left align-middle font-sans text-foreground";

function TableCell({ className, ...props }: JSX.IntrinsicElements["td"]) {
    return <td data-slot="table-cell" className={cn(CELL_CLASS, className)} {...props} />;
}

/** The row-header cell the ledgers use for the name column. */
function TableRowHeader({ className, ...props }: JSX.IntrinsicElements["th"]) {
    return <th scope="row" data-slot="table-row-header" className={cn(CELL_CLASS, className)} {...props} />;
}

const NUMERIC_CELL_CLASS = `${CELL_CLASS} font-mono text-num tabular-nums`;

function TableNumber({ className, ...props }: JSX.IntrinsicElements["td"]) {
    return <td data-slot="table-number" className={cn(NUMERIC_CELL_CLASS, className)} {...props} />;
}

function TableCaption({ className, ...props }: JSX.IntrinsicElements["caption"]) {
    return <caption data-slot="table-caption" className={cn("sr-only absolute h-px w-px overflow-hidden whitespace-nowrap border-0 p-0 -m-px [clip:rect(0,0,0,0)]", className)} {...props} />;
}

/** The "nothing here yet" row: no bottom rule, muted, spanning the ledger. */
function TableEmpty({ className, colSpan, ...props }: JSX.IntrinsicElements["td"]) {
    return <TableCell colSpan={colSpan} className={cn("border-b-0 text-muted-foreground", className)} {...props} />;
}

export { Table, TableHeader, TableBody, TableRow, TableHead, TableCell, TableRowHeader, TableNumber, TableCaption, TableEmpty };
