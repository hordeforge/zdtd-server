//! Per-endpoint reliable-ordered channel (LiteNetLib-compatible subset).
//! Matches game Managed LiteNetLib PacketProperty ordinals and ack sizing.

const std = @import("std");
const packet = @import("packet.zig");
const udp = @import("udp_socket.zig");
const clock = @import("../util/clock.zig");

/// Max assembled user message. Mixed-surface stock chunks + texture planes can exceed 128 KiB.
pub const max_payload: usize = 524288;
/// Pending retransmit slots. allocPending caps in-flight at window_size, so
/// more slots than the window can never be used (fragments beyond it retry
/// via the WindowFull pump loop). max_sequence % window_size == 0 keeps
/// consecutive in-window seqs on distinct slots across wrap.
const pending_cap: usize = packet.window_size;
comptime {
    std.debug.assert(packet.max_sequence % pending_cap == 0);
}
/// One pending slot holds one MTU-sized channeled/fragment datagram.
const pending_bytes: usize = packet.max_packet_size;
const max_frag_parts: usize = 512;
const assemble_cap: usize = max_payload;
/// Game: (windowSize-1)/8 + 2 = 9 bitmap payload bytes on Ack.
const ack_bitmap_bytes: usize = (packet.window_size - 1) / 8 + 2;
const resend_ns: u64 = 80_000_000; // 80ms, similar ballpark to LiteNet resend
/// Sleep between per-part WindowFull pumps so the peer ACK round-trip can
/// land (see the sendReliable retry loop). 2ms is far below the 80ms resend
/// gate and above the localhost RTT, so a drained window resumes promptly.
const ack_yield_ns: u64 = 2_000_000;

const Pending = struct {
    used: bool = false,
    seq: u16 = 0,
    len: u16 = 0,
    last_sent_ns: u64 = 0,
    data: [pending_bytes]u8 = undefined,
};

/// Optional outbound capture for integration tests (records game payloads, not LiteNet headers).
pub const Capture = struct {
    /// Test-only reach into wire/ for package parse (see root.zig dependency note).
    const frame = @import("../wire/frame.zig");

    /// Per-message cap must fit stock inventory frames and medium packages.
    /// Slot count covers join floods (stream r≤8 → 100+ chunks) + multi-step sim.
    /// Full stock chunks may exceed per-slot size; tests assert via counters too.
    slots: [256]struct { len: u16 = 0, data: [8192]u8 = undefined } = undefined,
    n: usize = 0,

    pub fn push(self: *Capture, user: []const u8) void {
        if (self.n >= self.slots.len) {
            // drop oldest
            var i: usize = 1;
            while (i < self.slots.len) : (i += 1) self.slots[i - 1] = self.slots[i];
            self.n = self.slots.len - 1;
        }
        const s = &self.slots[self.n];
        const n = @min(user.len, s.data.len);
        @memcpy(s.data[0..n], user[0..n]);
        s.len = @intCast(n);
        self.n += 1;
    }

    pub fn clear(self: *Capture) void {
        self.n = 0;
    }

    pub fn findPkgId(self: *const Capture, pkg_id: u16) ?[]const u8 {
        var i: usize = 0;
        while (i < self.n) : (i += 1) {
            const msg = self.slots[i].data[0..self.slots[i].len];
            var pkgs: [8]frame.Package = undefined;
            const pn = frame.parseChannelPayload(msg, &pkgs);
            var j: usize = 0;
            while (j < pn) : (j += 1) {
                if (pkgs[j].id == pkg_id) return pkgs[j].body;
            }
        }
        return null;
    }

    /// Find PosAndRot/etc body whose first i32 is entity_id (common package layout).
    pub fn findPkgIdEntity(self: *const Capture, pkg_id: u16, entity_id: i32) ?[]const u8 {
        var i: usize = 0;
        while (i < self.n) : (i += 1) {
            const msg = self.slots[i].data[0..self.slots[i].len];
            var pkgs: [8]frame.Package = undefined;
            const pn = frame.parseChannelPayload(msg, &pkgs);
            var j: usize = 0;
            while (j < pn) : (j += 1) {
                if (pkgs[j].id != pkg_id) continue;
                if (pkgs[j].body.len < 4) continue;
                const eid = std.mem.readInt(i32, pkgs[j].body[0..4], .little);
                if (eid == entity_id) return pkgs[j].body;
            }
        }
        return null;
    }

    /// Find EntitySpawn-style body with matching class hash at body[5..9] (after id+ver).
    pub fn findPkgIdClass(self: *const Capture, pkg_id: u16, class_hash: i32) ?[]const u8 {
        var i: usize = 0;
        while (i < self.n) : (i += 1) {
            const msg = self.slots[i].data[0..self.slots[i].len];
            var pkgs: [8]frame.Package = undefined;
            const pn = frame.parseChannelPayload(msg, &pkgs);
            var j: usize = 0;
            while (j < pn) : (j += 1) {
                if (pkgs[j].id != pkg_id) continue;
                if (pkgs[j].body.len < 9) continue;
                const h = std.mem.readInt(i32, pkgs[j].body[5..9], .little);
                if (h == class_hash) return pkgs[j].body;
            }
        }
        return null;
    }
};

/// One inbound fragment reassembly, keyed by the message's frag_id. Stock
/// LiteNetLib keeps a dictionary of these; zdtd bounds it at a small fixed
/// count (see Peer.asm_slots).
const Assembly = struct {
    active: bool = false,
    frag_id: u16 = 0,
    total: u16 = 0,
    got: u16 = 0,
    have: [max_frag_parts]bool = .{false} ** max_frag_parts,
    part_len: [max_frag_parts]u16 = .{0} ** max_frag_parts,
    /// Part payload storage (part i starts at i * max_fragment_user).
    parts: [max_frag_parts][packet.max_fragment_user]u8 = undefined,
};

pub const Peer = struct {
    addr: udp.IpAddress = .{ .ip4 = .loopback(0) },
    /// Cached hashIp(addr); key for per-datagram peer lookup.
    addr_key: u64 = 0,
    remote_id: i32 = 0,
    local_id: i32 = 0,
    connect_time: i64 = 0,
    conn_num: u8 = 0,
    alive: bool = false,
    authenticated: bool = false,
    /// Test-only: when non-null, sendReliable also records user payloads.
    capture: ?*Capture = null,
    /// Optional ACK pump: called while a large reliable message stalls on a full
    /// window so incoming ACKs advance local_window_start and free slots. Without
    /// it, multi-fragment chunks (POI ids ≥ 256 add a 3072 B/layer upper24 array)
    /// can never drain the 64-slot window and the send fails, holing the chunk disk.
    pump_fn: ?*const fn (?*anyopaque) void = null,
    pump_ctx: ?*anyopaque = null,
    /// Join-critical sends share one reliable-window budget across the enter
    /// bundle (armed at the request boundary, or by a standalone critical send).
    /// A transiently busy peer ACKs within the budget and the
    /// bundle goes through; a dead peer stalls the tick at most once per join
    /// instead of once per package (reap clears it at peer_stale_ms anyway).
    critical_budget_deadline_ns: u64 = 0,
    /// Game-layer deadline for the reliable send currently being fragmented.
    /// Fragment ACK pumping must not outlive sendReliablePumped's tick budget.
    reliable_send_deadline_ns: u64 = 0,

    local_seq: u16 = 0,
    local_window_start: u16 = 0,
    remote_window_start: u16 = 0,
    remote_seq_next: u16 = 0,
    /// Bits for remote sequences currently in window (for duplicate detect + acks).
    ack_bits: [ack_bitmap_bytes]u8 = .{0} ** ack_bitmap_bytes,
    must_ack: bool = false,
    pending: [pending_cap]Pending = [_]Pending{.{}} ** pending_cap,
    /// Earliest time the next resendPending window scan is worth doing. The
    /// WindowFull retry loops call resendPending thousands of times per stall;
    /// without this gate each call walks all 64 pending slots (86 KiB stride)
    /// even though nothing can be due until resend_ns has elapsed.
    next_resend_check_ns: u64 = 0,
    last_recv_ns: u64 = 0,
    next_frag_id: u16 = 1,
    /// Inbound fragment reassembly. Stock LiteNetLib keys assemblies by
    /// fragmentId (a dictionary); two large C2S messages (a Bag plus a
    /// PlayerInventory during a loot transfer) can interleave. A single
    /// assembly destroyed the first on the second's fragments, silently losing
    /// a message that was already ACKed. Two slots cover that interleave;
    /// `parts` is `undefined` so pages map lazily as parts arrive.
    asm_slots: [2]Assembly = .{ .{}, .{} },
    /// Drop counter for fragments arriving while every assembly slot is busy
    /// with a different frag_id (a third concurrent large C2S message). Must
    /// stay 0 in practice; the counter makes a loss observable.
    asm_drops: u32 = 0,
    /// Delivered reassembled user payload (valid until next handlePacket).
    deliver_buf: [assemble_cap]u8 = undefined,
    deliver_len: usize = 0,
    /// Out-of-order reliable payload hold (ordered delivery). Slots indexed by
    /// seq % window_size; hold_len[i] > 0 means a payload for that seq is
    /// buffered awaiting the gap to fill. Non-fragmented C2S only: a
    /// fragmented message's parts always flow into reassembly, and the
    /// completed message delivers on completion (its payload lives in
    /// deliver_buf, which cannot be parked here). Bounded by the window; when
    /// a slot is busy the payload falls back to on-first-sight delivery.
    hold_len: [packet.window_size]u16 = .{0} ** packet.window_size,
    hold_data: [packet.window_size][packet.max_single_user]u8 = undefined,
    /// Extra user payloads from LiteNet Merged packets (multiple game msgs per UDP).
    extra_buf: [assemble_cap]u8 = undefined,
    extra_used: usize = 0,
    /// Merged/drain mailbox slots. 8 was too small: one join burst merges far
    /// more C2S packages than that between polls, and an overflow silently lost
    /// a reliable package (see pushExtra).
    extra_q: [64]struct { off: u32, len: u32 } = undefined,
    extra_n: u8 = 0,
    /// Payloads dropped because the mailbox was full. Must stay 0 in practice.
    extra_drops: u32 = 0,

    pub fn setAddr(self: *Peer, addr: *const udp.IpAddress) void {
        self.addr = addr.*;
        self.addr_key = udp.hashIp(addr);
    }

    pub fn sendRaw(self: *Peer, sock: *udp.Socket, raw: []const u8) !void {
        try sock.sendTo(raw, &self.addr);
    }

    fn allocPending(self: *Peer, sock: *udp.Socket) !*Pending {
        const in_flight = relSeq(@as(i32, self.local_seq) - @as(i32, self.local_window_start));
        if (in_flight >= packet.window_size) {
            try self.resendPending(sock);
            return error.WindowFull;
        }
        const p = &self.pending[self.local_seq % pending_cap];
        if (p.used) {
            try self.resendPending(sock);
            return error.WindowFull;
        }
        return p;
    }

    /// Fire-and-forget unreliable (LiteNet property Unreliable). No retransmit.
    /// Use for high-rate cosmetic motion; game-critical still sendReliable.
    pub fn sendUnreliable(self: *Peer, sock: *udp.Socket, user: []const u8) !void {
        if (user.len > packet.max_single_user) return error.Overflow;
        if (self.capture) |cap| cap.push(user);
        var buf: [packet.max_packet_size]u8 = undefined;
        // Unreliable header: property byte 0 + user
        if (user.len + 1 > buf.len) return error.Overflow;
        buf[0] = @intFromEnum(packet.Property.unreliable);
        @memcpy(buf[1..][0..user.len], user);
        try self.sendRaw(sock, buf[0 .. 1 + user.len]);
    }

    pub fn sendReliable(self: *Peer, sock: *udp.Socket, user: []const u8) !void {
        if (self.capture) |cap| {
            // Record full user message for scenarios, then exercise real send path.
            cap.push(user);
        }
        if (user.len > max_payload) return error.Overflow;

        // Single datagram when it fits MTU (matches stock non-fragment path).
        if (user.len <= packet.max_single_user) {
            try self.sendOneReliable(sock, user, null);
            return;
        }

        // Fragment large messages (PackageIds, stock PlayerLogin tickets, …).
        const part_max = packet.max_fragment_user;
        const total_parts: u16 = @intCast((user.len + part_max - 1) / part_max);
        if (total_parts > max_frag_parts) return error.Overflow;
        const frag_id = self.next_frag_id;
        self.next_frag_id +%= 1;
        var part: u16 = 0;
        var off: usize = 0;
        while (part < total_parts) : (part += 1) {
            const n = @min(part_max, user.len - off);
            // Per-part WindowFull retry: this is LiteNet-level fragmentation,
            // not the Game-layer send path. No Game budget_ns/clock is
            // available here (and per AGENTS.md + ../7dtd-research policy this
            // is liteNet native: black box, residual — by design not wire
            // correctness). The 4000-attempt cap bounds the per-part stall;
            // the outer Game-layer calls (sendFramedReliable / sendGameBudget)
            // still bound the whole join burst via sendReliablePumped.
            var attempts: u32 = 0;
            while (true) : (attempts += 1) {
                self.sendOneReliable(sock, user[off .. off + n], .{
                    .frag_id = frag_id,
                    .frag_part = part,
                    .frag_total = total_parts,
                }) catch |err| switch (err) {
                    error.WindowFull => {
                        if (attempts >= 4000) return error.WindowFull;
                        if (self.reliable_send_deadline_ns != 0 and clock.monoNs() >= self.reliable_send_deadline_ns) return error.WindowFull;
                        try self.resendPending(sock);
                        if (self.pump_fn) |pf| pf(self.pump_ctx);
                        // Yield so the peer's ACK datagrams can land: 4000 spin
                        // pumps burn out in microseconds, before the first ACK
                        // round-trip, and a full window never frees (join
                        // IdMapping repro: part 64/198 exhausts with
                        // inflight=64 while the ACKs arrive right after).
                        if (attempts % 4 == 3) clock.sleepNs(ack_yield_ns);
                        continue;
                    },
                    else => return err,
                };
                break;
            }
            off += n;
        }
    }

    const FragMeta = struct { frag_id: u16, frag_part: u16, frag_total: u16 };

    fn sendOneReliable(self: *Peer, sock: *udp.Socket, user_part: []const u8, frag: ?FragMeta) !void {
        try self.sendOneReliableOnChannel(sock, user_part, frag, 2);
    }

    fn sendOneReliableOnChannel(self: *Peer, sock: *udp.Socket, user_part: []const u8, frag: ?FragMeta, channel_id: u8) !void {
        const p = try self.allocPending(sock);
        const seq = self.local_seq;
        const framed = if (frag) |f|
            try packet.writeChanneledFragment(p.data[0..], seq, channel_id, self.conn_num, f.frag_id, f.frag_part, f.frag_total, user_part)
        else
            try packet.writeChanneled(p.data[0..], seq, channel_id, self.conn_num, user_part);
        p.used = true;
        p.seq = seq;
        p.len = @intCast(framed.len);
        p.last_sent_ns = clock.monoNs();
        self.local_seq = @intCast((@as(u32, seq) + 1) % packet.max_sequence);
        // Capture-only peers: free slot immediately so suite does not WindowFull.
        if (self.capture != null) {
            p.used = false;
            self.local_window_start = self.local_seq;
            return;
        }
        try self.sendRaw(sock, p.data[0..p.len]);
    }

    pub fn resendPending(self: *Peer, sock: *udp.Socket) !void {
        const now = clock.monoNs();
        if (now < self.next_resend_check_ns) {
            if (self.must_ack) try self.flushAcks(sock);
            return;
        }
        // Re-scan at 1/8 of the resend interval: a due packet is delayed by at
        // most resend_ns/8 while the common nothing-due call becomes O(1).
        self.next_resend_check_ns = now + resend_ns / 8;
        var seq = self.local_window_start;
        while (seq != self.local_seq) : (seq = @intCast((@as(u32, seq) + 1) % packet.max_sequence)) {
            const p = &self.pending[seq % pending_cap];
            if (!p.used) continue;
            if (now -% p.last_sent_ns < resend_ns) continue;
            try self.sendRaw(sock, p.data[0..p.len]);
            p.last_sent_ns = now;
        }
        if (self.must_ack) try self.flushAcks(sock);
    }

    fn clearAssembly(self: *Peer, slot: usize) void {
        self.asm_slots[slot] = .{};
    }

    /// Collect fragment parts; return full user payload when complete.
    fn takeFragment(self: *Peer, info: packet.ChanneledInfo) ?[]const u8 {
        if (info.frag_total == 0 or info.frag_total > max_frag_parts) return null;
        if (info.frag_part >= info.frag_total) return null;
        if (info.user.len > packet.max_fragment_user) return null;

        // Find the assembly for this frag_id, or the first free slot.
        var slot: usize = self.asm_slots.len;
        var free: ?usize = null;
        for (&self.asm_slots, 0..) |*a, i| {
            if (a.active and a.frag_id == info.frag_id) {
                slot = i;
                break;
            }
            if (!a.active and free == null) free = i;
        }
        if (slot == self.asm_slots.len) {
            if (free) |f| {
                slot = f;
                self.asm_slots[f] = .{
                    .active = true,
                    .frag_id = info.frag_id,
                    .total = info.frag_total,
                };
            } else {
                // All slots hold a different message: drop this fragment (the
                // message is lost for this connection; stock would keep a
                // dictionary entry, but the third concurrent C2S fragment is
                // outside the realistic Bag + inventory interleave).
                self.asm_drops +%= 1;
                return null;
            }
        }
        const a = &self.asm_slots[slot];
        if (a.total != info.frag_total) return null;
        const part: usize = info.frag_part;
        if (a.have[part]) return null; // duplicate part
        @memcpy(a.parts[part][0..info.user.len], info.user);
        a.have[part] = true;
        a.part_len[part] = @intCast(info.user.len);
        a.got += 1;
        if (a.got < a.total) return null;
        // Reassemble in part order into deliver_buf.
        var out: usize = 0;
        var i: u16 = 0;
        while (i < a.total) : (i += 1) {
            if (!a.have[i]) {
                self.clearAssembly(slot);
                return null;
            }
            const pl = a.part_len[i];
            if (out + pl > assemble_cap) {
                self.clearAssembly(slot);
                return null;
            }
            @memcpy(self.deliver_buf[out .. out + pl], a.parts[i][0..pl]);
            out += pl;
        }
        self.deliver_len = out;
        self.clearAssembly(slot);
        return self.deliver_buf[0..self.deliver_len];
    }

    pub fn inFlight(self: *const Peer) u16 {
        return @intCast(relSeq(@as(i32, self.local_seq) - @as(i32, self.local_window_start)));
    }

    /// Copy a user payload into the peer extra queue (survives the recv buffer
    /// being overwritten). Used by Merged multipacket handling and by
    /// Server.drainControl so mid-send ACK drains do not drop game packages.
    /// No room for another queued payload (slot count or byte budget). Callers
    /// that own the socket must stop consuming datagrams instead of pushing.
    pub fn extraFull(self: *const Peer) bool {
        return self.extra_n >= self.extra_q.len or
            self.extra_used + packet.max_single_user > self.extra_buf.len;
    }

    pub fn pushExtra(self: *Peer, user: []const u8) void {
        // A drop here is silent data loss of an already-ACKed reliable package,
        // so it is counted, not ignored. Callers should gate on extraFull().
        if (self.extra_n >= self.extra_q.len or
            self.extra_used + user.len > self.extra_buf.len)
        {
            self.extra_drops +%= 1;
            return;
        }
        const off: u32 = @intCast(self.extra_used);
        const dst = self.extra_buf[self.extra_used..][0..user.len];
        // `user` may already point into extra_buf, so this cannot be @memcpy:
        // handlePacket's Merged branch pushes then pops, and popExtra reclaims
        // extra_used to 0 once the queue drains, so Server.drainControl re-pushes
        // a slice that overlaps dst (exactly, for a single-payload Merged).
        if (dst.ptr != user.ptr) {
            if (@intFromPtr(dst.ptr) < @intFromPtr(user.ptr)) {
                std.mem.copyForwards(u8, dst, user);
            } else {
                std.mem.copyBackwards(u8, dst, user);
            }
        }
        self.extra_used += user.len;
        self.extra_q[self.extra_n] = .{ .off = off, .len = @intCast(user.len) };
        self.extra_n += 1;
    }

    /// Pop next queued user payload from a prior Merged datagram (FIFO).
    pub fn popExtra(self: *Peer) ?[]const u8 {
        if (self.extra_n == 0) return null;
        const e = self.extra_q[0];
        var i: u8 = 1;
        while (i < self.extra_n) : (i += 1) self.extra_q[i - 1] = self.extra_q[i];
        self.extra_n -= 1;
        if (self.extra_n == 0) self.extra_used = 0;
        return self.extra_buf[e.off..][0..e.len];
    }

    /// Buffer an out-of-order non-fragmented payload for ordered delivery.
    /// False when the slot for this seq is busy (hold full) or the payload is
    /// oversized: the caller falls back to on-first-sight delivery.
    fn holdPayload(self: *Peer, seq: u16, payload: []const u8) bool {
        if (payload.len > packet.max_single_user) return false;
        const i: usize = seq % packet.window_size;
        if (self.hold_len[i] != 0) return false;
        @memcpy(self.hold_data[i][0..payload.len], payload);
        self.hold_len[i] = @intCast(payload.len);
        return true;
    }

    /// After delivering the next-in-order payload, release every held payload
    /// whose seq is now contiguous, routing them through the extra mailbox (the
    /// current handlePacket already has a return value).
    fn drainHeldOrdered(self: *Peer) void {
        while (true) {
            const i: usize = self.remote_seq_next % packet.window_size;
            if (self.hold_len[i] == 0) break;
            const payload = self.hold_data[i][0..self.hold_len[i]];
            self.hold_len[i] = 0;
            self.remote_seq_next = @intCast((@as(u32, self.remote_seq_next) + 1) % packet.max_sequence);
            self.pushExtra(payload);
        }
    }

    pub fn handlePacket(self: *Peer, sock: *udp.Socket, raw: []const u8) !?[]const u8 {
        if (raw.len < 1) return null;
        self.last_recv_ns = clock.monoNs();
        const prop = packet.propertyOf(raw[0]);
        switch (prop) {
            // LiteNet Merged: [prop][u16 size][subpacket]*: NOT a channeled header.
            .merged => {
                var off: usize = 1;
                while (off + 2 <= raw.len) {
                    const slen = std.mem.readInt(u16, raw[off..][0..2], .little);
                    off += 2;
                    if (slen == 0) break;
                    if (off + slen > raw.len) break;
                    const sub = raw[off .. off + slen];
                    off += slen;
                    // Stock LiteNet never nests Merged; refusing it bounds recursion
                    // depth at 1 so a self-nested datagram cannot blow the stack.
                    if (packet.propertyOf(sub[0]) == .merged) continue;
                    if (try self.handlePacket(sock, sub)) |user| {
                        self.pushExtra(user);
                    }
                }
                return self.popExtra();
            },
            .channeled => {
                const info = packet.parseChanneled(raw) orelse return null;
                // Stock rejects seq >= MaxSequence; relSeq would alias it into the window.
                if (info.seq >= packet.max_sequence) return null;
                const relate = relSeq(@as(i32, info.seq) - @as(i32, self.remote_window_start));
                if (relate < 0 or relate >= @as(i32, @intCast(packet.window_size * 2))) {
                    self.must_ack = true;
                    try self.flushAcks(sock);
                    return null;
                }
                // Slide window for very new packets (LiteNet-style).
                if (relate >= @as(i32, @intCast(packet.window_size))) {
                    const new_start: u16 = @intCast((@as(u32, info.seq) + 1 - packet.window_size + packet.max_sequence) % packet.max_sequence);
                    while (self.remote_window_start != new_start) {
                        const wi: usize = self.remote_window_start % packet.window_size;
                        self.ack_bits[wi / 8] &= ~(@as(u8, 1) << @intCast(wi % 8));
                        self.remote_window_start = @intCast((@as(u32, self.remote_window_start) + 1) % packet.max_sequence);
                    }
                }
                const idx: usize = info.seq % packet.window_size;
                const already = (self.ack_bits[idx / 8] & (@as(u8, 1) << @intCast(idx % 8))) != 0;
                self.ack_bits[idx / 8] |= @as(u8, 1) << @intCast(idx % 8);
                self.must_ack = true;
                try self.flushAcks(sock);
                if (already) return null;
                // Ordered delivery: a packet for the next expected seq delivers
                // now and releases any held successors; a newer packet within
                // the window is held until its gap fills (WAN reordering must
                // not apply SetBlock / inventory transactions out of order).
                // Fragmented messages deliver on completion (parts flow into
                // reassembly; the completed payload lives in deliver_buf and
                // cannot be parked in the hold).
                if (info.seq == self.remote_seq_next) {
                    self.remote_seq_next = @intCast((@as(u32, self.remote_seq_next) + 1) % packet.max_sequence);
                    self.drainHeldOrdered();
                    if (info.fragmented) return self.takeFragment(info);
                    return info.user;
                }
                const rel = relSeq(@as(i32, info.seq) - @as(i32, self.remote_seq_next));
                if (rel > 0 and rel < @as(i32, @intCast(packet.window_size))) {
                    if (info.fragmented) return self.takeFragment(info);
                    if (self.holdPayload(info.seq, info.user)) return null;
                    // Hold full: fall back to on-first-sight so a flood of
                    // reordered packets cannot wedge the channel.
                    return info.user;
                }
                // Stale (already delivered / sender slid past) or outside the
                // holdable window: drop rather than stall the channel.
                return null;
            },
            .ack => {
                self.processAck(raw);
                return null;
            },
            .disconnect => {
                self.alive = false;
                self.authenticated = false;
                // Free all pending so the peer slot can be reused without a stuck window.
                for (&self.pending) |*p| p.used = false;
                self.local_window_start = self.local_seq;
                return null;
            },
            .ping => {
                // Stock Ping header size=3: [prop][seq:u16]. Pong header size=11:
                // [prop][seq:u16][utc_ticks:i64]. Wrong pong size fails client NetPacket.Verify
                // → "[NM] DataReceived: bad!" and DisconnectReason.Timeout.
                if (raw.len >= 3) {
                    var pong: [11]u8 = undefined;
                    pong[0] = packet.makeByte0(.pong, self.conn_num);
                    pong[1] = raw[1];
                    pong[2] = raw[2];
                    // Ticks not used for our RTT; client only needs a valid 11-byte pong.
                    const ticks: i64 = @intCast(clock.monoNs() / 100); // 100ns units ≈ DateTime ticks scale
                    std.mem.writeInt(i64, pong[3..][0..8], ticks, .little);
                    try self.sendRaw(sock, &pong);
                }
                return null;
            },
            .mtu_check => {
                // Echo as MtuOk so client MTU discovery completes (same size payload).
                if (raw.len >= 1) {
                    var ok_buf: [1500]u8 = undefined;
                    const n = @min(raw.len, ok_buf.len);
                    @memcpy(ok_buf[0..n], raw[0..n]);
                    ok_buf[0] = packet.makeByte0(.mtu_ok, self.conn_num);
                    try self.sendRaw(sock, ok_buf[0..n]);
                }
                return null;
            },
            .mtu_ok, .pong, .shutdown_ok, .empty => return null,
            else => return null,
        }
    }

    fn processAck(self: *Peer, raw: []const u8) void {
        // Stock ReliableChannel.ProcessAck: Size must match header + (windowSize-1)/8+2.
        // Accept ≥ header; loadgen/stock both send full 13-byte acks.
        if (raw.len < packet.channeled_header_size + 1) return;
        const ack_seq = std.mem.readInt(u16, raw[1..][0..2], .little);
        if (ack_seq >= packet.max_sequence) return;
        // Stock: RelativeSequenceNumber(localWindowStart, ackSeq) = local - ack ∈ [0, window).
        const rel_base = relSeq(@as(i32, self.local_window_start) - @as(i32, ack_seq));
        if (rel_base < 0 or rel_base >= @as(i32, @intCast(packet.window_size))) return;

        // Walk seq from localWindowStart → localSequence; bit at (seq % windowSize).
        var seq = self.local_window_start;
        while (seq != self.local_seq) : (seq = @intCast((@as(u32, seq) + 1) % packet.max_sequence)) {
            // Stop if this seq is outside the ack's reported window span.
            if (relSeq(@as(i32, seq) - @as(i32, ack_seq)) >= @as(i32, @intCast(packet.window_size))) break;
            const pending_idx: usize = @intCast(seq % packet.window_size);
            const byte_i = packet.channeled_header_size + pending_idx / 8;
            const bit_i: u3 = @intCast(pending_idx % 8);
            if (byte_i >= raw.len) break;
            if ((raw[byte_i] & (@as(u8, 1) << bit_i)) == 0) continue;
            const p = &self.pending[seq % pending_cap];
            if (p.used and p.seq == seq) {
                p.used = false;
            }
            if (seq == self.local_window_start) {
                self.local_window_start = @intCast((@as(u32, self.local_window_start) + 1) % packet.max_sequence);
            }
        }
        // Slide window start past contiguous free seqs.
        while (self.local_window_start != self.local_seq) {
            const p = &self.pending[self.local_window_start % pending_cap];
            if (p.used and p.seq == self.local_window_start) break;
            self.local_window_start = @intCast((@as(u32, self.local_window_start) + 1) % packet.max_sequence);
        }
    }

    pub fn flushAcks(self: *Peer, sock: *udp.Socket) !void {
        if (!self.must_ack) return;
        self.must_ack = false;
        var buf: [64]u8 = undefined;
        const total = packet.channeled_header_size + ack_bitmap_bytes;
        if (buf.len < total) return error.Overflow;
        buf[0] = packet.makeByte0(.ack, self.conn_num);
        std.mem.writeInt(u16, buf[1..][0..2], self.remote_window_start, .little);
        buf[3] = 2; // ReliableOrdered channel id
        // Expand window-size bits into ack_bitmap_bytes (extra trailing zeros ok)
        @memset(buf[packet.channeled_header_size..][0..ack_bitmap_bytes], 0);
        const copy_n = @min(self.ack_bits.len, ack_bitmap_bytes);
        @memcpy(buf[packet.channeled_header_size..][0..copy_n], self.ack_bits[0..copy_n]);
        try self.sendRaw(sock, buf[0..total]);
    }
};

fn relSeq(a: i32) i32 {
    // Relative sequence in [-half, half) with modular wrap (LiteNet-style).
    const max: i32 = @intCast(packet.max_sequence);
    const half: i32 = @intCast(packet.max_sequence / 2);
    var r = @rem(a, max);
    if (r < 0) r += max;
    if (r >= half) r -= max;
    return r;
}

test "processAck advances local window when bits set" {
    // Drive real Peer.handlePacket ack path (not a reimplementation).
    var peer: Peer = .{};
    peer.alive = true;
    peer.conn_num = 0;
    // Simulate three outstanding reliable packets seq 0,1,2.
    peer.local_window_start = 0;
    peer.local_seq = 3;
    peer.pending[0] = .{ .used = true, .seq = 0, .len = 8 };
    peer.pending[1] = .{ .used = true, .seq = 1, .len = 8 };
    peer.pending[2] = .{ .used = true, .seq = 2, .len = 8 };

    var ack: [13]u8 = .{0} ** 13;
    ack[0] = packet.makeByte0(.ack, 0);
    std.mem.writeInt(u16, ack[1..3], 0, .little); // window start
    ack[3] = 2; // ReliableOrdered channel id
    // bits for seq 0,1,2 at indices 0,1,2
    ack[4] = 0b0000_0111;

    var sock: udp.Socket = .{}; // unused for ack path
    const user = try peer.handlePacket(&sock, &ack);
    try std.testing.expect(user == null);
    try std.testing.expectEqual(@as(u16, 3), peer.local_window_start);
    try std.testing.expect(!peer.pending[0].used);
    try std.testing.expect(!peer.pending[1].used);
    try std.testing.expect(!peer.pending[2].used);
}

test "pushExtra copies payload for later popExtra (mid-send mailbox)" {
    // drainControl relies on a durable copy: the recv buffer is reused.
    var peer: Peer = .{};
    var scratch: [8]u8 = .{ 1, 2, 3, 4, 5, 6, 7, 8 };
    peer.pushExtra(scratch[0..4]);
    // Overwrite source; queued bytes must be independent.
    @memset(&scratch, 0xFF);
    const got = peer.popExtra() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 4 }, got);
    try std.testing.expect(peer.popExtra() == null);
}

test "pushExtra accepts a slice that already lives in extra_buf (no alias UB)" {
    // Live join repro: a Merged datagram reaches Server.drainControl, handlePacket
    // pushes the sub-payload then returns popExtra(), and popExtra resets
    // extra_used to 0 when the queue drains. drainControl re-pushes that slice,
    // so src and dst are the SAME extra_buf bytes. @memcpy there panics with
    // "arguments alias" (seen live: chunk stream never started after join).
    var peer: Peer = .{};
    const payload = [_]u8{ 9, 8, 7, 6, 5 };
    peer.pushExtra(&payload);
    const popped = peer.popExtra() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 0), peer.extra_used); // reclaimed
    try std.testing.expectEqual(popped.ptr, peer.extra_buf[0..].ptr); // aliases buf
    peer.pushExtra(popped); // must not panic and must preserve the bytes
    const again = peer.popExtra() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u8, &payload, again);

    // Same-buffer re-push at a non-zero destination (queue not drained).
    var p2: Peer = .{};
    p2.pushExtra(&[_]u8{ 1, 2, 3 });
    p2.pushExtra(&payload);
    const first = p2.popExtra() orelse return error.TestUnexpectedResult;
    p2.pushExtra(first);
    try std.testing.expectEqualSlices(u8, &payload, p2.popExtra().?);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3 }, p2.popExtra().?);
}

// Lives here (not fuzz.zig) for access to the private takeFragment/processAck
// state machines; src/fuzz.zig pulls this file in so `zig build fuzz` runs it
// coverage-guided.
const peer_state_corpus = [_][]const u8{
    "",
    &.{ 0, 1, 0, 1, 0, 0, 8 },
    &.{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff },
    &.{ 1, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
};

test "fuzz fragment reassembly and ack window state" {
    try std.testing.fuzz({}, fuzzPeerState, .{ .corpus = &peer_state_corpus });
}

fn fuzzPeerState(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    var peer: Peer = .{};
    peer.alive = true;

    // Interleave fragment parts across a few frag ids so restarts, duplicate
    // parts, out-of-range part indices, and total mismatches all get hit.
    var payload: [64]u8 = undefined;
    @memset(&payload, 0xAA);
    var steps: usize = 0;
    while (steps < 16) : (steps += 1) {
        const info: packet.ChanneledInfo = .{
            .seq = smith.value(u16),
            .channel_id = 2,
            .fragmented = true,
            .frag_id = smith.value(u16) & 0x3,
            .frag_part = smith.value(u16),
            .frag_total = smith.value(u16),
            .user = payload[0..smith.index(payload.len + 1)],
        };
        if (peer.takeFragment(info)) |full| {
            try std.testing.expect(full.len <= max_payload);
        }
        for (&peer.asm_slots) |a| {
            if (a.active) {
                try std.testing.expect(a.total <= max_frag_parts);
                try std.testing.expect(a.got < a.total);
            }
        }
    }

    // Arbitrary ack bytes over a consistent in-flight window must leave the
    // window well-formed: start never passes local_seq.
    const outstanding: u16 = @intCast(smith.index(packet.window_size + 1));
    peer.local_window_start = 0;
    peer.local_seq = outstanding;
    var i: u16 = 0;
    while (i < outstanding) : (i += 1) {
        peer.pending[i] = .{ .used = true, .seq = i, .len = 8 };
    }
    var raw: [64]u8 = undefined;
    const rlen = smith.slice(&raw);
    peer.processAck(raw[0..rlen]);
    try std.testing.expect(peer.local_window_start <= outstanding);
}

test "two interleaved fragmented messages reassemble independently" {
    // Regression for the single-assembly bug: a second fragmented C2S message
    // (Bag plus PlayerInventory during a loot transfer) used to clear the
    // first assembly and lose both. Fragments of two messages now interleave
    // into separate slots and each reassembles whole.
    var peer: Peer = .{};
    peer.alive = true;
    const frag = struct {
        fn mk(frag_id: u16, part: u16, total: u16, user: []const u8) packet.ChanneledInfo {
            return .{ .seq = 0, .channel_id = 2, .fragmented = true, .frag_id = frag_id, .frag_part = part, .frag_total = total, .user = user };
        }
    }.mk;

    // A (frag_id 7, 3 parts) and B (frag_id 9, 2 parts) interleaved.
    try std.testing.expect(peer.takeFragment(frag(7, 0, 3, "AAAA")) == null);
    try std.testing.expect(peer.takeFragment(frag(9, 0, 2, "XX")) == null);
    // Both assemblies are live at once.
    var live: usize = 0;
    for (&peer.asm_slots) |a| {
        if (a.active) live += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), live);
    try std.testing.expect(peer.takeFragment(frag(7, 1, 3, "BBBB")) == null);
    const full_b = peer.takeFragment(frag(9, 1, 2, "YY"));
    try std.testing.expect(full_b != null);
    if (full_b) |fb| try std.testing.expectEqualStrings("XXYY", fb);
    // Completing A overwrites deliver_buf, so read it right after.
    const full_a = peer.takeFragment(frag(7, 2, 3, "CCCC"));
    try std.testing.expect(full_a != null);
    if (full_a) |fa| try std.testing.expectEqualStrings("AAAABBBBCCCC", fa);
    try std.testing.expectEqual(@as(u32, 0), peer.asm_drops);
}

test "out-of-order reliable payloads deliver in sequence" {
    // WAN reordering: seq 1 and 2 arrive before the expected 0. They must be
    // held, not delivered, so SetBlock / inventory transactions stay ordered;
    // when 0 arrives it delivers and 1, 2 drain through the extra mailbox.
    var peer: Peer = .{};
    peer.alive = true;
    peer.conn_num = 0;
    var sock: udp.Socket = .{};
    _ = try sock.openAndBind(0); // real socket so the ACK flush can send
    defer sock.close();
    var dst: udp.IpAddress = .{ .ip4 = .loopback(34567) };
    peer.setAddr(&dst);
    var b1: [64]u8 = undefined;
    const p1 = try packet.writeChanneled(&b1, 1, 2, 0, "one");
    const r1 = try peer.handlePacket(&sock, p1);
    try std.testing.expect(r1 == null);
    var b2: [64]u8 = undefined;
    const p2 = try packet.writeChanneled(&b2, 2, 2, 0, "two");
    const r2 = try peer.handlePacket(&sock, p2);
    try std.testing.expect(r2 == null);
    var b0: [64]u8 = undefined;
    const p0 = try packet.writeChanneled(&b0, 0, 2, 0, "zero");
    const r0 = try peer.handlePacket(&sock, p0);
    try std.testing.expect(r0 != null);
    if (r0) |u| try std.testing.expectEqualStrings("zero", u);
    const e1 = peer.popExtra();
    try std.testing.expect(e1 != null);
    if (e1) |u| try std.testing.expectEqualStrings("one", u);
    const e2 = peer.popExtra();
    try std.testing.expect(e2 != null);
    if (e2) |u| try std.testing.expectEqualStrings("two", u);
    try std.testing.expect(peer.popExtra() == null);
    // Stale retransmit of an already-delivered seq is dropped, not delivered.
    var b0b: [64]u8 = undefined;
    const p0b = try packet.writeChanneled(&b0b, 0, 2, 0, "zero-again");
    const r0b = try peer.handlePacket(&sock, p0b);
    try std.testing.expect(r0b == null);
}
