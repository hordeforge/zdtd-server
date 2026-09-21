//! Lock bodies: request parse, grant/deny/force-unlock/trader/unlock
//! responses, and the span-cap + grant-layout tests.
//!
//! Split out of the packages.zig facade (same builders, same tests);
//! import via `packages.stock_lock` like the other stock_* leaves.

const std = @import("std");
const binary = @import("binary.zig");
const stock_entity = @import("stock_entity.zig");


/// Stock NetPackageLockRequest body (after package id):
/// locking:bool | channel:u16 | targetCount:i32 | targets… | contextType:string | context?
pub const LockRequestHead = struct {
    locking: bool,
    channel: u16,
    /// Declared target span length. Stock's `LockRequestServer` gate 2
    /// (IL=239) refuses more than `max_lock_targets_declared`, but the deny
    /// response echoes the request's targets, so the parser walks the span and
    /// the C2S handler owns the rule.
    target_count: i32,
    /// True when any target entry is null (`WriteIdentifyingInfo` writes a
    /// `false` presence byte and nothing else). Stock's gate 2 rejects a span
    /// containing a null target with the same deny as an over-long span.
    has_null_target: bool,
    /// Slice of request body covering targetCount i32 + target identifying blobs (not context).
    targets_blob: []const u8,
    /// Remaining body after targets (context type string + optional payload).
    context_tail: []const u8,
};

/// Walk one target's identifying info, returning false for a null target (the
/// presence byte was 0).
fn skipLockTargetIdent(r: *binary.Reader) binary.ReadError!bool {
    const present = try r.readByte();
    if (present == 0) return false;
    const ty = try r.readByte();
    switch (ty) {
        0 => { // TileEntity → Vector3i
            _ = try r.readI32();
            _ = try r.readI32();
            _ = try r.readI32();
        },
        1 => { // TEFeatureAbs → Vector3i + feature name
            _ = try r.readI32();
            _ = try r.readI32();
            _ = try r.readI32();
            try r.skipString();
        },
        2 => { // Entity → entityId
            _ = try r.readI32();
        },
        3 => { // TransactionalInventory → Guid
            if (r.remaining() < 16) return error.EndOfStream;
            r.pos += 16;
        },
        else => return error.EndOfStream,
    }
    return true;
}

/// Stock's hard cap on a lock request's target span. `LockRequestServer` gate 2
/// (IL=239, RE dedicated-leftovers.md:136) refuses a span longer than 5. The
/// refusal still produces a reply: the failure sets `errorMsg` and falls
/// through to the `NetPackageLockResponse` send with `success = false`
/// (IL_0263), so the C2S handler owns this rule and must answer with a deny.
/// The constant previously held 32 with a comment claiming the limit was
/// undocumented, which accepted requests stock rejects.
pub const max_lock_targets_declared: i32 = 5;

/// Parse-time work bound on the declared target count, deliberately above the
/// stock rule above: the parser has to walk the span even for a request the
/// server will refuse, because the deny response echoes the request's targets.
/// A count past this bound is malformed rather than merely over-limit.
const max_lock_targets_parseable: i32 = 64;

/// NetPackageLockRequest (RE write IL=74; the response in buildLockResponseGrant
/// echoes these fields): `locking` bool | `channel` u16 | target count i32 |
/// targets | `context` string. On success returns a head with slices into `body`.
pub fn parseLockRequest(body: []const u8) binary.ReadError!LockRequestHead {
    var r: binary.Reader = .{ .data = body };
    const locking = try r.readBool();
    const channel = try r.readU16();
    const count_pos = r.pos;
    const count = try r.readI32();
    if (count < 0 or count > max_lock_targets_parseable) return error.EndOfStream;
    var has_null_target = false;
    var i: i32 = 0;
    while (i < count) : (i += 1) {
        if (!try skipLockTargetIdent(&r)) has_null_target = true;
    }
    const targets_end = r.pos;
    // remainder is context
    return .{
        .locking = locking,
        .channel = channel,
        .target_count = count,
        .has_null_target = has_null_target,
        .targets_blob = body[count_pos..targets_end],
        .context_tail = body[targets_end..],
    };
}

/// NetPackageLockResponse granting the lock (RE inventories/netpackage-bodies.md,
/// write IL=74): `locking` bool | `success` bool | `errorMsg` string |
/// `isForceUnlocked` bool | `channel` u16 | `targets` | `context` string. The
/// targets and context are echoed verbatim from the request, which is what
/// keeps the client's pending lock correlated.
pub fn buildLockResponseGrant(buf: []u8, req: LockRequestHead) ![]u8 {
    return buildLockResponse(buf, req, true, "");
}

/// NetPackageLockResponse denying the lock, held by another peer or a busy
/// channel (RE write IL=74; field order in buildLockResponseGrant).
pub fn buildLockResponseDeny(buf: []u8, req: LockRequestHead, err_msg: []const u8) ![]u8 {
    return buildLockResponse(buf, req, false, err_msg);
}

fn buildLockResponse(buf: []u8, req: LockRequestHead, success: bool, err_msg: []const u8) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeBool(req.locking);
    try w.writeBool(success);
    try w.writeString(err_msg);
    try w.writeBool(false); // isForceUnlocked
    try w.writeU16(req.channel);
    try w.writeBytes(req.targets_blob);
    if (req.context_tail.len > 0) {
        try w.writeBytes(req.context_tail);
    } else {
        try w.writeString("");
    }
    return w.written();
}

/// NetPackageLockResponse forcing a held lock open (RE write IL=74; field order
/// in `buildLockResponseGrant`). `locking = false` selects the client's
/// `LockManager.UnlockResponse(success, errorMsg, isForceUnlocked)` branch
/// (ProcessPackage IL=27), which reads neither the targets nor the context - so
/// this needs only the channel, and the server does not have to have kept the
/// original request's target blob. Stock sends the same thing from
/// `ForceUnlockByPlayer` (IL=11) on disconnect cleanup and after a failed
/// inventory transaction.
pub fn buildLockResponseForceUnlock(buf: []u8, channel: u16) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeBool(false); // locking = false -> UnlockResponse branch
    try w.writeBool(true); // success
    try w.writeString("");
    try w.writeBool(true); // isForceUnlocked
    try w.writeU16(channel);
    try w.writeI32(0); // no targets: the unlock branch never reads them
    try w.writeString("");
    return w.written();
}

test "force-unlock lock response selects the unlock branch" {
    // The two directions are different client calls (ProcessPackage IL=27), so
    // `locking` is what routes it; a grant-shaped body with success=true would
    // re-open the window instead of closing it.
    var buf: [64]u8 = undefined;
    const body = try buildLockResponseForceUnlock(&buf, 3);
    var r: binary.Reader = .{ .data = body };
    try std.testing.expectEqual(false, try r.readBool()); // locking
    try std.testing.expectEqual(true, try r.readBool()); // success
    var s: [8]u8 = undefined;
    try std.testing.expectEqualStrings("", try r.readString(&s));
    try std.testing.expectEqual(true, try r.readBool()); // isForceUnlocked
    try std.testing.expectEqual(@as(u16, 3), try r.readU16());
    try std.testing.expectEqual(@as(i32, 0), try r.readI32()); // target count
    try std.testing.expectEqualStrings("", try r.readString(&s));
    try std.testing.expectEqual(@as(usize, 0), r.remaining());
}

/// Grant a lock whose target is a trader. Stock serializes the target's lock
/// context into the LockResponse, and the two trader-ish contexts do **not**
/// share a layout:
///   - `EntityTraderLockContext::Read` (EntityTrader_EntityTraderLockContext
///     .il.txt:38): `Command` string, `hasTraderData` bool, then TraderData
///     only when that bool is set.
///   - `VendingMachineLockContext::Read` (TileEntityVendingMachine_Vending
///     MachineLockContext.il.txt:19): TraderData **directly**, with no command
///     and no bool.
/// Emitting the entity shape for a vending machine hands the client two extra
/// bytes (the empty command's length and the bool) which it reads as the first
/// half of `TraderID`, desyncing the rest of the body.
/// NetPackageTraderData is ToServer-only, so this is the packet that carries
/// trader inventory to the opening client.
pub fn buildLockResponseTrader(buf: []u8, req: LockRequestHead, td: stock_entity.TraderDataInfo) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    // Type name + Command from the request context tail (empty-safe fallbacks).
    // Separate buffers: the second readString must not clobber the first.
    var type_buf: [64]u8 = undefined;
    var cmd_buf: [64]u8 = undefined;
    var r: binary.Reader = .{ .data = req.context_tail };
    const type_name = if (req.context_tail.len > 0)
        r.readString(&type_buf) catch "EntityTraderLockContext"
    else
        "EntityTraderLockContext";
    const command = if (r.pos < req.context_tail.len)
        (r.readString(&cmd_buf) catch "")
    else
        "";
    try w.writeBool(req.locking);
    try w.writeBool(true); // success
    try w.writeString(""); // error
    try w.writeBool(false); // isForceUnlocked
    try w.writeU16(req.channel);
    try w.writeBytes(req.targets_blob);
    try w.writeString(type_name);
    // VendingMachineLockContext has neither field; only the entity context
    // carries Command + hasTraderData ahead of the TraderData.
    if (!std.mem.eql(u8, type_name, vending_lock_context)) {
        try w.writeString(command);
        try w.writeBool(true); // hasTraderData
    }
    try stock_entity.writeTraderDataBody(&w, td);
    return w.written();
}

/// Stock type name for the vending-machine lock context, the discriminator the
/// client uses to pick which context `Read` runs.
pub const vending_lock_context = "VendingMachineLockContext";

/// Unlock response (locking=false path on client ProcessPackage).
/// NetPackageLockResponse for an unlock (RE write IL=74; field order in
/// buildLockResponseGrant). locking=false with an empty target list.
pub fn buildLockResponseUnlock(buf: []u8, success: bool) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeBool(false); // locking
    try w.writeBool(success);
    try w.writeString("");
    try w.writeBool(false); // isForceUnlocked
    // The tail is written even though an unlock carries nothing in it:
    // omitting it would desync the reader's BinaryReader rather than save
    // bytes. The RE body table lists nine fields, but the last two (target
    // `FullName`, `ILockContext.Write`) sit behind the same two null guards as
    // LockRequest (protocol-packages.md residual table): the per-target info
    // is written only for a non-null target list, and the context payload only
    // for a non-null context. An empty list and an empty context type name are
    // therefore the complete stock encoding of "nothing locked".
    try w.writeU16(0); // channel
    try w.writeI32(0); // targets: empty list
    try w.writeString(""); // context type name (empty = null context)
    return w.written();
}

test "lock request span cap is the handler's rule, not the parser's" {
    // Stock LockRequestServer gate 2 (IL=239) refuses a span longer than 5 and
    // still replies with a deny that echoes the request's targets (IL_0263), so
    // the parser must walk an over-limit span far enough for the C2S handler to
    // answer it. Rejecting at parse time silently dropped the request, which
    // left the client's pending lock unresolved.
    const buildTargets = struct {
        fn call(w: *binary.Writer, n: i32) !void {
            try w.writeBool(true);
            try w.writeU16(0);
            try w.writeI32(n);
            var i: i32 = 0;
            while (i < n) : (i += 1) {
                try w.writeByte(1); // present
                try w.writeByte(1); // TEFeatureAbs
                try w.writeI32(i);
                try w.writeI32(70);
                try w.writeI32(2);
                try w.writeString("Storage");
            }
            try w.writeString("");
        }
    }.call;

    // The literal 5 is the point of the test: deriving the bounds from the
    // constant would pass for any value it happens to hold, which is exactly
    // what let the old 32 sit here unnoticed.
    try std.testing.expectEqual(@as(i32, 5), max_lock_targets_declared);

    var over_buf: [1024]u8 = undefined;
    var over_w: binary.Writer = .{ .buf = &over_buf };
    try buildTargets(&over_w, 6);
    const over = try parseLockRequest(over_w.written());
    try std.testing.expectEqual(@as(i32, 6), over.target_count);
    try std.testing.expect(!over.has_null_target);
    // The whole span is walked, so the deny response can echo it. The blob
    // starts after locking (1) + channel (2).
    try std.testing.expectEqual(over_w.written().len, 3 + over.targets_blob.len + over.context_tail.len);

    // A null target is gate 2's other reject; the parser reports it rather than
    // pretending the span was well formed.
    var null_buf: [64]u8 = undefined;
    var null_w: binary.Writer = .{ .buf = &null_buf };
    try null_w.writeBool(true);
    try null_w.writeU16(0);
    try null_w.writeI32(1);
    try null_w.writeByte(0); // present = 0 -> null target
    try null_w.writeString("");
    const nul = try parseLockRequest(null_w.written());
    try std.testing.expect(nul.has_null_target);

    // Past the parse bound the body is malformed, not merely over-limit.
    var huge_buf: [2048]u8 = undefined;
    var huge_w: binary.Writer = .{ .buf = &huge_buf };
    try buildTargets(&huge_w, max_lock_targets_parseable + 1);
    try std.testing.expectError(error.EndOfStream, parseLockRequest(huge_w.written()));
}

test "lock request grant response layout" {
    // locking=true, channel=0, 1 TEFeatureAbs target at (1,70,2) name=Storage, empty context
    var req: [64]u8 = undefined;
    var w: binary.Writer = .{ .buf = &req };
    try w.writeBool(true);
    try w.writeU16(0);
    try w.writeI32(1);
    try w.writeByte(1); // present
    try w.writeByte(1); // TEFeatureAbs
    try w.writeI32(1);
    try w.writeI32(70);
    try w.writeI32(2);
    try w.writeString("Storage");
    try w.writeString(""); // no context type
    const head = try parseLockRequest(w.written());
    try std.testing.expect(head.locking);
    try std.testing.expectEqual(@as(u16, 0), head.channel);

    var resp_buf: [128]u8 = undefined;
    const resp = try buildLockResponseGrant(&resp_buf, head);
    try std.testing.expectEqual(@as(u8, 1), resp[0]); // locking
    try std.testing.expectEqual(@as(u8, 1), resp[1]); // success

    // Only those two bytes were checked. The rest is locking | success |
    // errorMsg | isForceUnlocked | channel | targets | context, and the deny
    // path had no test at all - it differs from grant only in the success bit
    // and the message, which is exactly the pair a swap would hide.
    var r: binary.Reader = .{ .data = resp };
    var s_buf: [64]u8 = undefined;
    try std.testing.expectEqual(true, try r.readBool()); // locking
    try std.testing.expectEqual(true, try r.readBool()); // success
    try std.testing.expectEqualStrings("", try r.readString(&s_buf)); // errorMsg
    try std.testing.expectEqual(false, try r.readBool()); // isForceUnlocked
    try std.testing.expectEqual(@as(u16, 0), try r.readU16()); // channel
    // targets_blob is echoed verbatim: count 1 then the one target entry.
    try std.testing.expectEqual(@as(i32, 1), try r.readI32());

    var deny_buf: [128]u8 = undefined;
    const deny = try buildLockResponseDeny(&deny_buf, head, "busy");
    var dr: binary.Reader = .{ .data = deny };
    try std.testing.expectEqual(true, try dr.readBool()); // locking echoed
    try std.testing.expectEqual(false, try dr.readBool()); // success cleared
    try std.testing.expectEqualStrings("busy", try dr.readString(&s_buf));
    try std.testing.expectEqual(false, try dr.readBool()); // isForceUnlocked
    try std.testing.expectEqual(@as(u16, 0), try dr.readU16()); // channel
}
