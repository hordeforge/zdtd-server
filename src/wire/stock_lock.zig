//! Lock bodies for the V3.3.0 `NetPackageLockTarget` package (one package,
//! both directions, opaque length-prefixed `LockManager` payload).
//!
//! The b10 `NetPackageLockRequest` / `NetPackageLockResponse` pair collapsed
//! into one package whose body is `i32 payloadLen` + `payload bytes`
//! (protocol-packages.md §1.5.1). Request and response carry distinct
//! payloads; `LockManager` owns their layouts:
//!
//! request: `isLock bool` | `channel u16` | `targetCount i32` |
//!          `targetCount x WorldAddress` (per-target `OnLockRequestLocal`
//!          context is empty for every implementer, so none is written).
//! response: `isLock bool` | `success bool` | `error string` | `channel u16` |
//!          `targetCount i32` | `targetCount x WorldAddress`, then per-target
//!          `OnLockResponseServer` context **only when success**.
//!
//! `WorldAddress` replaced `LockTargetType`/`ILockContext`: a `u8` tag
//! (0 None, 1 TileEntity, 2 TEFeature, 3 Entity) precedes the fields, with no
//! presence byte. The b10 `context_tail` (type name + `ILockContext`) is gone.
//!
//! Split out of the packages.zig facade (same builders, same tests);
//! import via `packages.stock_lock` like the other stock_* leaves.

const std = @import("std");
const binary = @import("binary.zig");
const stock_entity = @import("stock_entity.zig");

/// `WorldAddress.WorldObjectType` tag (protocol-packages.md §1.5.1): the first
/// byte of every target. `LockTargetType` and its `TransactionalInventory`
/// member are gone; the tag now lives on `WorldAddress`.
pub const WorldObjectType = enum(u8) {
    none = 0,
    tile_entity = 1,
    te_feature = 2,
    entity = 3,
    _,
};

/// Parsed `NetPackageLockTarget` request payload (slices into `payload`).
pub const LockRequestHead = struct {
    is_lock: bool,
    channel: u16,
    /// Declared target span length. `LockRequestServer` gate (IL_000E-0014)
    /// accepts 1..5 and otherwise logs and drops; the parser walks the span so
    /// the handler can enforce the rule (protocol-packages.md §1.5.1).
    target_count: i32,
    /// True when a target tag is `None` (0). `LockRequestServer` fails closed
    /// on a null target (IL_00BE) with a deny, so the handler reports it.
    has_null_target: bool,
    /// Slice of the request payload covering `targetCount i32` + the target
    /// addresses (not the context, which is empty). Echoed verbatim by the
    /// response's own target list.
    targets_blob: []const u8,
    /// Empty for every request (all `OnLockRequestLocal` are `ret`); kept so a
    /// future context-bearing request has a place to land.
    context_tail: []const u8,
};

/// Stock's hard cap on a lock request's target span (`LockRequestServer`
/// IL_000E-0014: `count < 1 || count > 5` logs and drops). The b10 code
/// replied with a deny; b18 drops with no reply, but the constant still names
/// the limit the handler enforces.
pub const max_lock_targets_declared: i32 = 5;

/// Parse-time work bound on the declared target count, above the stock rule so
/// the handler can enforce 1..5 rather than the parser rejecting early. A count
/// past this bound is malformed rather than merely over-limit.
const max_lock_targets_parseable: i32 = 64;

/// Skip one `WorldAddress`, returning false when the tag is `None` (a null
/// target). Used to walk a span without materialising it.
fn skipWorldAddress(r: *binary.Reader) binary.ReadError!bool {
    const tag: WorldObjectType = @enumFromInt(try r.readByte());
    switch (tag) {
        .none => return false,
        .tile_entity => {
            _ = try r.readI32();
            _ = try r.readI32();
            _ = try r.readI32();
        },
        .te_feature => {
            _ = try r.readI32();
            _ = try r.readI32();
            _ = try r.readI32();
            try r.skipString();
        },
        .entity => _ = try r.readI32(),
        else => return error.EndOfStream,
    }
    return true;
}

/// Strip the `i32 payloadLen` framing from a `NetPackageLockTarget` package
/// body, returning the payload slice (protocol-packages.md §1.5.1, write
/// IL=15: `(i32)payload.Length` then the bytes). Fails closed when the
/// declared length disagrees with the body, so a truncated or padded body
/// never reaches `parseLockRequest`.
pub fn unwrapLockTargetPayload(body: []const u8) binary.ReadError![]const u8 {
    if (body.len < 4) return error.EndOfStream;
    var r: binary.Reader = .{ .data = body };
    const len = try r.readI32();
    if (len < 0 or @as(usize, @intCast(len)) != r.remaining()) return error.EndOfStream;
    return body[4..];
}

/// Parse a `NetPackageLockTarget` request payload (the bytes after the
/// `i32 payloadLen` framing). Returns a head with slices into `payload`.
pub fn parseLockRequest(payload: []const u8) binary.ReadError!LockRequestHead {
    var r: binary.Reader = .{ .data = payload };
    const is_lock = try r.readBool();
    const channel = try r.readU16();
    const count_pos = r.pos;
    const count = try r.readI32();
    if (count < 0 or count > max_lock_targets_parseable) return error.EndOfStream;
    var has_null_target = false;
    var i: i32 = 0;
    while (i < count) : (i += 1) {
        if (!try skipWorldAddress(&r)) has_null_target = true;
    }
    const targets_end = r.pos;
    // Remainder is the per-target context, empty for every request.
    return .{
        .is_lock = is_lock,
        .channel = channel,
        .target_count = count,
        .has_null_target = has_null_target,
        .targets_blob = payload[count_pos..targets_end],
        .context_tail = payload[targets_end..],
    };
}

/// Frame any LockTarget payload (request or response) into a package body:
/// `i32 payloadLen` + payload bytes (protocol-packages.md §1.5.1, write IL=15).
/// Callers (fixtures, handlers) build a payload with `binary.Writer`, then
/// frame it here before `packages.framed(_, "NetPackageLockTarget", ...)`.
pub fn frameLockTarget(buf: []u8, payload: []const u8) ![]u8 {
    if (buf.len < payload.len + 4) return error.NoSpaceLeft;
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(@intCast(payload.len));
    try w.writeBytes(payload);
    return w.written();
}

/// Response payload prefix shared by every reply: `isLock` | `success` |
/// `error string` | `channel u16` | `targetCount i32` + targets. `context`
/// (per-target `OnLockResponseServer` bytes) is appended only when `success`
/// (`LockRequestServer` IL_0200 skips the context loop on failure), so the
/// caller passes `with_context`.
fn buildLockResponsePayload(
    buf: []u8,
    req: LockRequestHead,
    success: bool,
    err_msg: []const u8,
    context: []const u8,
) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeBool(req.is_lock); // isLock echoed (true for a lock reply)
    try w.writeBool(success);
    try w.writeString(err_msg);
    try w.writeU16(req.channel);
    // targets_blob starts with the targetCount i32, so echoing it reproduces
    // `targetCount i32 | targets`, exactly the response's target span.
    try w.writeBytes(req.targets_blob);
    if (success and context.len > 0) try w.writeBytes(context);
    return w.written();
}

/// Frame a `NetPackageLockTarget` grant: success with the caller's per-target
/// context (trader `TraderData`, storage grid, or empty). The context is
/// appended only on success per `LockRequestServer` IL_0200.
pub fn buildLockResponseGrant(
    buf: []u8,
    req: LockRequestHead,
    context: []const u8,
) ![]u8 {
    var payload_buf: [512]u8 = undefined;
    const payload = try buildLockResponsePayload(&payload_buf, req, true, "", context);
    return frameLockTarget(buf, payload);
}

/// Frame a `NetPackageLockTarget` deny: failure, `err_msg`, no context.
pub fn buildLockResponseDeny(buf: []u8, req: LockRequestHead, err_msg: []const u8) ![]u8 {
    var payload_buf: [512]u8 = undefined;
    const payload = try buildLockResponsePayload(&payload_buf, req, false, err_msg, "");
    return frameLockTarget(buf, payload);
}

/// Frame a `NetPackageLockTarget` force-unlock: `isLock = false` selects the
/// client's `UnlockResponse` branch (ProcessPackage), which reads neither the
/// targets nor a context. Stock sends this from `ForceUnlockByPlayer` on
/// disconnect cleanup. It names the channel, so the head is synthesised.
pub fn buildLockResponseForceUnlock(buf: []u8, channel: u16) ![]u8 {
    var payload_buf: [64]u8 = undefined;
    var w: binary.Writer = .{ .buf = &payload_buf };
    try w.writeBool(false); // isLock = false -> UnlockResponse branch
    try w.writeBool(true); // success
    try w.writeString(""); // error
    try w.writeU16(channel);
    try w.writeI32(0); // no targets: the unlock branch never reads them
    return frameLockTarget(buf, w.written());
}

/// Frame a `NetPackageLockTarget` unlock reply (`isLock = false`, success or
/// refusal). Same shape as force-unlock but `success` is the caller's verdict.
pub fn buildLockResponseUnlock(buf: []u8, success: bool) ![]u8 {
    var payload_buf: [64]u8 = undefined;
    var w: binary.Writer = .{ .buf = &payload_buf };
    try w.writeBool(false); // isLock
    try w.writeBool(success);
    try w.writeString("");
    try w.writeU16(0); // channel (unlock branch ignores it)
    try w.writeI32(0); // empty target list
    return frameLockTarget(buf, w.written());
}

/// Frame a `NetPackageLockTarget` grant whose single target is a trader or
/// vending machine, carrying that target's `OnLockResponseServer` context.
/// `EntityTrader` writes `TraderData` on channel 1 (Trade) and nothing on
/// channel 0; `TileEntityVendingMachine` always writes `TraderData`
/// (EntityTrader.il.txt IL_005B-0082, TileEntityVendingMachine.il.txt
/// IL_0000-0023). The caller decides which by passing the built context bytes.
pub fn buildLockResponseTrader(
    buf: []u8,
    req: LockRequestHead,
    td: stock_entity.TraderDataInfo,
    write_trader_data: bool,
) ![]u8 {
    var ctx_buf: [512]u8 = undefined;
    var ctx: []const u8 = &.{};
    if (write_trader_data) {
        var cw: binary.Writer = .{ .buf = &ctx_buf };
        try stock_entity.writeTraderDataBody(&cw, td);
        ctx = cw.written();
    }
    return buildLockResponseGrant(buf, req, ctx);
}

test "lock target request payload: tag-prefixed WorldAddress, no presence byte" {
    // isLock=true, channel=1, one TEFeature target at (1,70,2) name=Storage.
    var req_buf: [128]u8 = undefined;
    var w: binary.Writer = .{ .buf = &req_buf };
    try w.writeBool(true);
    try w.writeU16(1);
    try w.writeI32(1);
    try w.writeByte(2); // WorldObjectType.te_feature
    try w.writeI32(1);
    try w.writeI32(70);
    try w.writeI32(2);
    try w.writeString("Storage");
    const head = try parseLockRequest(w.written());
    try std.testing.expect(head.is_lock);
    try std.testing.expectEqual(@as(u16, 1), head.channel);
    try std.testing.expectEqual(@as(i32, 1), head.target_count);
    try std.testing.expect(!head.has_null_target);
    // targets_blob starts with the targetCount i32 and covers the address span.
    var tr: binary.Reader = .{ .data = head.targets_blob };
    try std.testing.expectEqual(@as(i32, 1), try tr.readI32());
    // WorldAddress: tag byte then fields (no presence byte ahead of it).
    try std.testing.expectEqual(@as(u8, 2), try tr.readByte()); // te_feature tag
    try std.testing.expectEqual(@as(i32, 1), try tr.readI32()); // x
    try std.testing.expectEqual(@as(i32, 70), try tr.readI32()); // y
    try std.testing.expectEqual(@as(i32, 2), try tr.readI32()); // z
    var fbuf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Storage", try tr.readString(&fbuf)); // feature
    try std.testing.expectEqual(@as(usize, 0), tr.remaining());

    // A `None` tag is a null target, reported rather than silently accepted.
    var null_buf: [64]u8 = undefined;
    var nw: binary.Writer = .{ .buf = &null_buf };
    try nw.writeBool(true);
    try nw.writeU16(0);
    try nw.writeI32(1);
    try nw.writeByte(0); // WorldObjectType.none
    const nul = try parseLockRequest(nw.written());
    try std.testing.expect(nul.has_null_target);

    // Past the parse bound the payload is malformed, not merely over-limit.
    var huge_buf: [4096]u8 = undefined;
    var hw: binary.Writer = .{ .buf = &huge_buf };
    try hw.writeBool(true);
    try hw.writeU16(0);
    try hw.writeI32(max_lock_targets_parseable + 1);
    var i: i32 = 0;
    while (i < max_lock_targets_parseable + 1) : (i += 1) {
        try hw.writeByte(1); // tile_entity
        try hw.writeI32(i);
        try hw.writeI32(0);
        try hw.writeI32(0);
    }
    try std.testing.expectError(error.EndOfStream, parseLockRequest(hw.written()));
}

test "lock target grant frames an i32 payload length envelope" {
    var req_buf: [128]u8 = undefined;
    var w: binary.Writer = .{ .buf = &req_buf };
    try w.writeBool(true);
    try w.writeU16(0);
    try w.writeI32(1);
    try w.writeByte(2); // te_feature
    try w.writeI32(1);
    try w.writeI32(70);
    try w.writeI32(2);
    try w.writeString("Storage");
    const head = try parseLockRequest(w.written());

    var resp_buf: [256]u8 = undefined;
    const resp = try buildLockResponseGrant(&resp_buf, head, "");
    // Envelope: i32 payloadLen then payload.
    var er: binary.Reader = .{ .data = resp };
    const plen = try er.readI32();
    try std.testing.expectEqual(@as(usize, @intCast(plen)), resp.len - 4);
    // Payload: isLock | success | error | channel | targets…
    try std.testing.expectEqual(true, try er.readBool()); // isLock
    try std.testing.expectEqual(true, try er.readBool()); // success
    var s_buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("", try er.readString(&s_buf)); // error
    try std.testing.expectEqual(@as(u16, 0), try er.readU16()); // channel
    try std.testing.expectEqual(@as(i32, 1), try er.readI32()); // targetCount
    try std.testing.expectEqual(@as(u8, 2), try er.readByte()); // te_feature tag
    _ = try er.readI32(); // x
    _ = try er.readI32(); // y
    _ = try er.readI32(); // z
    var ebuf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Storage", try er.readString(&ebuf)); // feature
    try std.testing.expectEqual(@as(usize, 0), er.remaining()); // no context (empty)

    // Deny: same shape, success=false, no context, carries the error.
    var deny_buf: [256]u8 = undefined;
    const deny = try buildLockResponseDeny(&deny_buf, head, "locked");
    var dr: binary.Reader = .{ .data = deny };
    const dplen = try dr.readI32();
    try std.testing.expectEqual(@as(usize, @intCast(dplen)), deny.len - 4);
    try std.testing.expectEqual(true, try dr.readBool()); // isLock
    try std.testing.expectEqual(false, try dr.readBool()); // success
    try std.testing.expectEqualStrings("locked", try dr.readString(&s_buf));
    try std.testing.expectEqual(@as(u16, 0), try dr.readU16());
    try std.testing.expectEqual(@as(i32, 1), try dr.readI32());
}

test "force-unlock lock response selects the unlock branch" {
    // isLock=false is what routes it client-side (ProcessPackage); a
    // grant-shaped body with success=true would re-open the window instead.
    var buf: [64]u8 = undefined;
    const body = try buildLockResponseForceUnlock(&buf, 3);
    var r: binary.Reader = .{ .data = body };
    const plen = try r.readI32();
    try std.testing.expectEqual(@as(usize, @intCast(plen)), body.len - 4);
    try std.testing.expectEqual(false, try r.readBool()); // isLock
    try std.testing.expectEqual(true, try r.readBool()); // success
    var s: [8]u8 = undefined;
    try std.testing.expectEqualStrings("", try r.readString(&s)); // error
    try std.testing.expectEqual(@as(u16, 3), try r.readU16()); // channel
    try std.testing.expectEqual(@as(i32, 0), try r.readI32()); // targetCount
    try std.testing.expectEqual(@as(usize, 0), r.remaining());
}

test "trader grant carries TraderData context only when requested" {
    var req_buf: [128]u8 = undefined;
    var w: binary.Writer = .{ .buf = &req_buf };
    try w.writeBool(true);
    try w.writeU16(1); // Trade channel
    try w.writeI32(1);
    try w.writeByte(3); // entity
    try w.writeI32(42);
    const head = try parseLockRequest(w.written());

    var resp_buf: [512]u8 = undefined;
    const resp = try buildLockResponseTrader(&resp_buf, head, .{
        .trader_id = 7,
        .available_money = 1000,
        .entries = &.{},
    }, true);
    var r: binary.Reader = .{ .data = resp };
    const plen = try r.readI32();
    try std.testing.expectEqual(true, try r.readBool()); // isLock
    try std.testing.expectEqual(true, try r.readBool()); // success
    var s_buf: [64]u8 = undefined;
    _ = try r.readString(&s_buf); // error
    try std.testing.expectEqual(@as(u16, 1), try r.readU16()); // channel
    try std.testing.expectEqual(@as(i32, 1), try r.readI32()); // targetCount
    try std.testing.expectEqual(@as(u8, 3), try r.readByte()); // entity tag
    try std.testing.expectEqual(@as(i32, 42), try r.readI32()); // entity id
    // TraderData context follows the targets (channel 1 writes it).
    try std.testing.expectEqual(@as(i32, 7), try r.readI32()); // TraderID
    try std.testing.expectEqual(@as(usize, @intCast(plen)), resp.len - 4);

    // Without the context (channel 0 / Interaction writes none) the payload
    // ends at the target.
    var resp2_buf: [512]u8 = undefined;
    const resp2 = try buildLockResponseTrader(&resp2_buf, head, .{
        .trader_id = 7,
        .available_money = 1000,
        .entries = &.{},
    }, false);
    var r2: binary.Reader = .{ .data = resp2 };
    const plen2 = try r2.readI32();
    _ = try r2.readBool();
    _ = try r2.readBool();
    _ = try r2.readString(&s_buf);
    _ = try r2.readU16();
    _ = try r2.readI32();
    _ = try r2.readByte();
    _ = try r2.readI32();
    try std.testing.expectEqual(@as(usize, 0), r2.remaining());
    try std.testing.expectEqual(@as(usize, @intCast(plen2)), resp2.len - 4);
}
