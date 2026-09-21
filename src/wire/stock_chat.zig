//! Chat + effect-request bodies: stock chat build/parse with recipient
//! routing, sound-at-position, and particle-effect invoke, with the
//! roundtrip tests.
//!
//! Split out of the packages.zig facade (same code, same tests);
//! import via `packages.stock_chat` like the other stock_* leaves.

const std = @import("std");
const binary = @import("binary.zig");

/// NetPackageChat body (RE chat.md §1): chatType u8 (EChatType: 0 Global,
/// 1 Friends, 2 Party, 3 Whisper, 4 Discord), senderEntityId i32, msg string,
/// msgSender u8, bbMode u8, recipientEntityIds (i32 count + ids). The
/// recipient list is the routing key: ChatMessageServer sends only to those
/// clients when non-empty, else broadcasts (chat.md §2).
pub const StockChat = struct {
    chat_type: u8,
    sender: i32,
    msg: []const u8,
    msg_sender: u8 = 0,
    bb_mode: u8 = 0,
    /// Party/friends/whisper recipients (≤ 8, the party cap).
    recipients: [8]i32 = .{-1} ** 8,
    recipient_count: u8 = 0,
};

/// NetPackageChat (RE inventories/netpackage-bodies.md, write IL=63):
/// `chatType` u8 | `senderEntityId` i32 | `msg` string | `msgSender` u8
/// (EMessageSender) | `bbMode` u8 (BbCodeSupportMode) | `recipientEntityIds`
/// count i32 | count x i32. An empty recipient list means every peer.
pub fn buildStockChat(buf: []u8, chat_type: u8, sender_entity_id: i32, msg: []const u8, recipients: []const i32) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeByte(chat_type);
    try w.writeI32(sender_entity_id);
    try w.writeString(msg);
    try w.writeByte(0); // EMessageSender
    try w.writeByte(0); // BbCodeSupportMode
    try w.writeI32(@intCast(recipients.len));
    for (recipients) |rid| try w.writeI32(rid);
    return w.written();
}

/// NetPackageChat, read side (RE write IL=63; same field order as
/// buildStockChat): `chatType` u8 | `senderEntityId` i32 | `msg` string |
/// `msgSender` u8 | `bbMode` u8 | recipient count i32 | count x i32.
pub fn parseStockChat(body: []const u8) !StockChat {
    if (body.len < 6) return error.EndOfStream;
    var r: binary.Reader = .{ .data = body };
    const chat_type = try r.readByte();
    const sender = try r.readI32();
    // Zero-copy message slice into `body` (no caller buffer). Overlong length
    // prefix maps Overflow → InvalidString to match string reader contract.
    const len_u = binary.read7BitEncodedInt(&r) catch |err| switch (err) {
        error.Overflow => return error.InvalidString,
        else => |e| return e,
    };
    const len: usize = len_u;
    if (r.pos + len > body.len) return error.EndOfStream;
    const msg = body[r.pos .. r.pos + len];
    r.pos += len;
    var out = StockChat{ .chat_type = chat_type, .sender = sender, .msg = msg };
    out.msg_sender = try r.readByte();
    out.bb_mode = try r.readByte();
    const count = try r.readI32();
    if (count > 0) {
        if (count > out.recipients.len) return error.Overflow; // forged list
        var i: usize = 0;
        while (i < @as(usize, @intCast(count))) : (i += 1) {
            out.recipients[i] = try r.readI32();
        }
        out.recipient_count = @intCast(count);
    }
    return out;
}

/// Stock `NetPackageSoundAtPosition` (write IL=25, read IL=21): pos Vector3
/// (3xf32) | audioClipName string | mode u8 (UnityEngine.AudioRolloffMode
/// Logarithmic=0/Linear=1/Custom=2) | distance i32 | entityId i32. The
/// dedicated-server relay (GameManager PlaySoundAtPositionServer IL=60)
/// re-broadcasts Setup(...) with allButAttachedToEntityId = entityId, so
/// every client except the owning player hears the sound (the owner already
/// played it locally); the `distance` field drives the receiving client's
/// rolloff, not the fan-out. Note: `volumeScale` is a Setup-only field that
/// stock never puts on the wire (write stops after entityId, read stops
/// after entityId; the client-side receiver gets the field default 0) - it
/// is kept on the struct for API symmetry but must not be encoded/decoded.
pub const SoundAtPosition = struct {
    pos: [3]f32,
    clip: [max_audio_clip_len]u8 = .{0} ** max_audio_clip_len,
    clip_len: u8 = 0,
    mode: u8 = 0,
    distance: i32 = 0,
    entity_id: i32 = 0,
    volume_scale: f32 = 0,
    /// End of the stock body. The clip string makes the length variable, so a
    /// relay must forward `body[0..wire_len]` rather than the raw slice.
    wire_len: usize = 0,

    pub fn clipSlice(self: *const SoundAtPosition) []const u8 {
        return self.clip[0..self.clip_len];
    }
};

/// Audio clip names are short asset paths; anything longer fails closed.
pub const max_audio_clip_len: usize = 256;

/// Read side of NetPackageSoundAtPosition (RE write IL=25): pos Vector3 | clip
/// string | `mode` u8 | `distance` i32 | `entityId` i32, the order
/// buildSoundAtPosition writes and where stock's write also stops.
///
/// `volume_scale` therefore never comes off the wire; it stays at its default
/// and only the local relay path sets it. The clip string is the one
/// client-controlled length in the body, so it is capped rather than trusted.
pub fn parseSoundAtPosition(body: []const u8) (binary.ReadError || error{Overflow})!SoundAtPosition {
    if (body.len < 22) return error.EndOfStream; // 12 pos + 1 clip-len + 1 mode + 4 + 4
    var r: binary.Reader = .{ .data = body };
    var out: SoundAtPosition = .{
        .pos = .{ try r.readF32(), try r.readF32(), try r.readF32() },
    };
    var clip_buf: [max_audio_clip_len]u8 = undefined;
    const clip = try r.readString(&clip_buf);
    // clip_len is a u8, so the cap itself does not fit: readString accepts a
    // length equal to the buffer, and >= (not >) is what keeps the cast below
    // in range. A joined client controls this length.
    if (clip.len >= max_audio_clip_len) return error.Overflow;
    @memcpy(out.clip[0..clip.len], clip);
    out.clip_len = @intCast(clip.len);
    out.mode = try r.readByte();
    out.distance = try r.readI32();
    out.entity_id = try r.readI32();
    out.wire_len = r.pos;
    return out;
}

/// Encode the stock body (write IL=25): pos Vector3 | clip string | mode u8 |
/// distance i32 | entityId i32. Server-initiated sounds carry entityId -1
/// (the dedicated relay's allButAttachedToEntityId). volumeScale is never
/// encoded: stock's write stops after entityId (see SoundAtPosition note).
pub fn buildSoundAtPosition(buf: []u8, s: SoundAtPosition) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeF32(s.pos[0]);
    try w.writeF32(s.pos[1]);
    try w.writeF32(s.pos[2]);
    try w.writeString(s.clipSlice());
    try w.writeByte(s.mode);
    try w.writeI32(s.distance);
    try w.writeI32(s.entity_id);
    return w.written();
}

test "sound at position parses the stock 5-field body" {
    // write IL=25 / read IL=21: pos 3xf32 | clip string | mode u8 | distance
    // i32 | entityId i32. volumeScale is Setup-only and never on the wire.
    var body: [128]u8 = undefined;
    var w: binary.Writer = .{ .buf = &body };
    // pos[1] is 64.75, not 0: with a zero there a swap with either neighbour
    // emitted bytes the assertions could not tell apart.
    try w.writeF32(100.5);
    try w.writeF32(64.75);
    try w.writeF32(-50.25);
    try w.writeString("Sounds/explosions/boom");
    try w.writeByte(1); // Linear
    try w.writeI32(30);
    try w.writeI32(42);
    const s = try parseSoundAtPosition(w.written());
    try std.testing.expectApproxEqAbs(@as(f32, 100.5), s.pos[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -50.25), s.pos[2], 0.001);
    try std.testing.expectEqualStrings("Sounds/explosions/boom", s.clipSlice());
    try std.testing.expectEqual(@as(u8, 1), s.mode);
    try std.testing.expectEqual(@as(i32, 30), s.distance);
    try std.testing.expectEqual(@as(i32, 42), s.entity_id);
    try std.testing.expectEqual(@as(f32, 0), s.volume_scale); // Setup-only default

    // A trailing volumeScale byte is not part of the wire: the parser stops
    // after entityId and the builder emits exactly 5 fields (a stock client
    // reader would desync on a 6-field body).
    // Separate buffer: `body` is the parsed input and `s` slices into it, so
    // building into it would overwrite the very values being written.
    var out_buf: [128]u8 = undefined;
    const built = try buildSoundAtPosition(&out_buf, s);
    // Values, not just the field count: this block only checked that the body
    // ends after five fields, so a reordering inside the builder would hide
    // behind a parser that moved with it. pos[1] also had to stop being 0.
    const f32At = struct {
        fn get(b: []const u8, off: usize) f32 {
            return @bitCast(std.mem.readInt(u32, b[off..][0..4], .little));
        }
    }.get;
    try std.testing.expectEqual(@as(f32, 100.5), f32At(built, 0));
    try std.testing.expectEqual(@as(f32, 64.75), f32At(built, 4));
    try std.testing.expectEqual(@as(f32, -50.25), f32At(built, 8));
    var br: binary.Reader = .{ .data = built };
    _ = try br.readF32();
    _ = try br.readF32();
    _ = try br.readF32();
    var nb: [64]u8 = undefined;
    _ = try br.readString(&nb);
    _ = try br.readByte();
    _ = try br.readI32();
    _ = try br.readI32();
    try std.testing.expectError(error.EndOfStream, br.readF32()); // no 6th field
}

test "a clip name at the cap fails closed instead of trapping the cast" {
    // clip_len is u8 while max_audio_clip_len is 256, and readString accepts a
    // length equal to the buffer, so a clip of exactly 256 bytes reached
    // @intCast(256) -> u8 and panicked. Any joined client can send this
    // package, so the cast has to be unreachable, not merely unlikely.
    var body: [512]u8 = undefined;
    var w: binary.Writer = .{ .buf = &body };
    try w.writeF32(1);
    try w.writeF32(2);
    try w.writeF32(3);
    const long = [_]u8{'a'} ** max_audio_clip_len;
    try w.writeString(&long);
    try w.writeByte(1);
    try w.writeI32(30);
    try w.writeI32(42);
    try std.testing.expectError(error.Overflow, parseSoundAtPosition(w.written()));

    // One byte under the cap still parses, so the rejection is about the cap
    // itself and not a broken length path.
    var body2: [512]u8 = undefined;
    var w2: binary.Writer = .{ .buf = &body2 };
    try w2.writeF32(1);
    try w2.writeF32(2);
    try w2.writeF32(3);
    try w2.writeString(long[0 .. max_audio_clip_len - 1]);
    try w2.writeByte(1);
    try w2.writeI32(30);
    try w2.writeI32(42);
    const ok = try parseSoundAtPosition(w2.written());
    try std.testing.expectEqual(@as(usize, max_audio_clip_len - 1), ok.clipSlice().len);
}

/// Stock `NetPackageParticleEffect` (write IL=20): a `ParticleEffect`
/// (ParticleEffect.Write IL=47: ParticleId i32, pos Vector3 3xf32, rot
/// Quaternion 4xf32, color Color32 4 bytes, soundName string,
/// additionalHitSoundName string, volumeScale f32) followed by
/// entityThatCausedIt i32, forceCreation bool, worldSpawn bool. The
/// dedicated-server relay (GameManager.SpawnParticleEffectServer IL=41)
/// re-broadcasts Setup(...) with allButAttachedToEntityId =
/// entityThatCausedIt, so every client except the causing entity's owner
/// sees the effect (the owner already spawned it locally).
pub const ParticleEffectInvoke = struct {
    entity_caused: i32,
    force_creation: bool,
    world_spawn: bool,
    /// End of the stock body. The two sound-name strings make the length
    /// variable, so a relay must forward `body[0..wire_len]`.
    wire_len: usize = 0,
};

/// NetPackageParticleEffect (write IL=20, NetPackageParticleEffect.il.txt:43):
/// `pe` (ParticleEffect::Write) | `entityThatCausedIt` i32 | `forceCreation`
/// bool | `worldSpawn` bool.
///
/// `ParticleEffect::Write` (ParticleEffect.il.txt:397-435) ends with
/// `parentEntityId` i32 and `attachment` u8 after volumeScale. Those five
/// bytes are part of the effect, not the package tail: reading the package's
/// own i32 too early took `parentEntityId` as `entityThatCausedIt` and then
/// derived both bools from the attachment byte and the real causing id.
pub fn parseParticleEffectInvoke(body: []const u8) (binary.ReadError || error{Overflow})!ParticleEffectInvoke {
    var r: binary.Reader = .{ .data = body };
    _ = try r.readI32(); // ParticleId
    var i: usize = 0;
    while (i < 3) : (i += 1) _ = try r.readF32(); // pos
    i = 0;
    while (i < 4) : (i += 1) _ = try r.readF32(); // rot (Quaternion)
    i = 0;
    while (i < 4) : (i += 1) _ = try r.readByte(); // color (Color32)
    var scratch: [128]u8 = undefined;
    _ = try r.readString(&scratch); // soundName
    _ = try r.readString(&scratch); // additionalHitSoundName
    _ = try r.readF32(); // volumeScale
    _ = try r.readI32(); // ParticleEffect.parentEntityId
    _ = try r.readByte(); // ParticleEffect.attachment
    var out: ParticleEffectInvoke = .{
        .entity_caused = try r.readI32(),
        .force_creation = try r.readBool(),
        .world_spawn = try r.readBool(),
    };
    out.wire_len = r.pos;
    return out;
}

test "particle effect invoke parses the stock body" {
    var body: [256]u8 = undefined;
    var w: binary.Writer = .{ .buf = &body };
    try w.writeI32(7); // ParticleId
    try w.writeF32(1);
    try w.writeF32(2);
    try w.writeF32(3);
    try w.writeF32(0);
    try w.writeF32(0);
    try w.writeF32(0);
    try w.writeF32(1);
    try w.writeByte(255);
    try w.writeByte(0);
    try w.writeByte(0);
    try w.writeByte(255);
    try w.writeString("Sounds/blood");
    try w.writeString("");
    try w.writeF32(1); // volumeScale
    // ParticleEffect::Write ends here, with two fields the package tail sits
    // behind. Distinct values so reading them as the tail cannot pass.
    try w.writeI32(999); // ParticleEffect.parentEntityId
    try w.writeByte(3); // ParticleEffect.attachment
    try w.writeI32(42); // entityThatCausedIt
    try w.writeBool(true); // forceCreation
    try w.writeBool(false); // worldSpawn
    const pe = try parseParticleEffectInvoke(w.written());
    try std.testing.expectEqual(@as(i32, 42), pe.entity_caused);
    try std.testing.expect(pe.force_creation);
    try std.testing.expect(!pe.world_spawn);
}

test "stock chat round-trips channel, sender, message and recipients" {
    var buf: [128]u8 = undefined;
    const recips = [_]i32{ 20, 30 };
    const body = try buildStockChat(&buf, 2, 10, "hello party", &recips); // EChatType.Party
    const ch = try parseStockChat(body);
    try std.testing.expectEqual(@as(u8, 2), ch.chat_type);
    try std.testing.expectEqual(@as(i32, 10), ch.sender);
    try std.testing.expectEqualStrings("hello party", ch.msg);
    try std.testing.expectEqual(@as(u8, 2), ch.recipient_count);
    try std.testing.expectEqual(@as(i32, 20), ch.recipients[0]);
    try std.testing.expectEqual(@as(i32, 30), ch.recipients[1]);
}

test "stock chat global has no recipients and rejects a forged oversized list" {
    var buf: [128]u8 = undefined;
    const body = try buildStockChat(&buf, 0, 10, "global", &.{});
    const ch = try parseStockChat(body);
    try std.testing.expectEqual(@as(u8, 0), ch.chat_type);
    try std.testing.expectEqual(@as(u8, 0), ch.recipient_count);
    // 9 recipients > the 8 cap is rejected, not truncated.
    var w = binary.Writer{ .buf = &buf };
    try w.writeByte(0);
    try w.writeI32(10);
    try w.writeString("x");
    try w.writeByte(0);
    try w.writeByte(0);
    try w.writeI32(9);
    var i: usize = 0;
    while (i < 9) : (i += 1) try w.writeI32(@intCast(100 + i));
    try std.testing.expectError(error.Overflow, parseStockChat(w.written()));
}
