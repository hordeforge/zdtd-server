# LiteNet transport

LiteNet owns the UDP carrier for every stock client connection: the socket, the fixed peer slot table, LiteNet datagram framing, the reliability window and its ACKs, MTU discovery, and the accept/disconnect transitions that create and free a peer slot. It does not own anything above the datagram: package ids, framed game payloads, the pre-auth 17-byte challenge, join phases, interest and replication all sit in `src/wire/` and `src/server/`, and this subsystem hands them opaque user bytes.

The package is the lowest network layer, so the dependency direction only points up. Its root module states the rule (src/litenet/root.zig:1): it may import `util` (for the clock) and must not import `server`, game packages, `ecs`, `world`, `assets`, or `apm`. One exception is carved out explicitly - `peer.Capture` imports `wire/frame.zig` so the scenario harness can decode package ids by name, while production send and receive paths stay wire-free (src/litenet/root.zig:4, src/litenet/peer.zig:50). The socket file is one of the four places AGENTS rule 26 permits direct socket and syscall access.

Sources: [`src/litenet/root.zig`](../../src/litenet/root.zig), [`src/litenet/server.zig`](../../src/litenet/server.zig), [`src/litenet/peer.zig`](../../src/litenet/peer.zig), [`src/litenet/packet.zig`](../../src/litenet/packet.zig), [`src/litenet/udp_socket.zig`](../../src/litenet/udp_socket.zig), [`src/protocol.zig`](../../src/protocol.zig).

## Server and peer slots

The server is a single struct holding the socket plus a fixed array of peer slots; there is no dynamic peer allocation and no map. The slot table and the join admission fields (src/litenet/server.zig:9):

```zig
pub const max_peers = 64;

pub const Server = struct {
    sock: udp.Socket = .{},
    port: u16 = 0,
    peers: [max_peers]peer_mod.Peer = [_]peer_mod.Peer{.{}} ** max_peers,
    next_local_id: i32 = 1,
    server_password: []const u8 = "",
    join_rate_limit_ms: u64 = 0,
    join_ip: [64]u32 = .{0} ** 64,
    join_ip_ms: [64]u64 = .{0} ** 64,
    join_ip_n: usize = 0,
    connect_rejects: u64 = 0,
```

`Game` embeds one by value (`net: ln_server.Server = .{}`, src/server/game.zig:404) and holds the receive buffer it passes to poll (`recv_buf: [65536]u8`, src/server/game.zig:454). The port is not the operator's `--port`: stock binds the LiteNet UDP socket at `ServerPort + 2`, so init computes `port +% 2` and calls `net.listen` there, then copies the ServerPassword into the transport (src/server/game/init_world.zig:93). A `port == 0` harness run never binds, and the unbound socket then reports `WouldBlock` on receive and silently drops on send so the seeded sim stays sealed (src/litenet/udp_socket.zig:87, src/litenet/udp_socket.zig:102).

Lookup and allocation are linear scans. `findPeer` matches `alive` plus the cached `addr_key`, an FNV-1a hash of address and port (src/litenet/server.zig:232, src/litenet/udp_socket.zig:109). `allocPeer` prefers a free slot, fully resets the peer with `p.* = .{}`, assigns the next `local_id`, and sets `alive`; when every slot is live it evicts the first peer whose `authenticated` flag is false, and otherwise returns `error.TooManyPeers` (src/litenet/server.zig:240). That error is not absorbed: `poll` propagates it, so an unexpected transport error returns out of `Game.step` (src/server/game/step.zig:63) and out of the run loop (src/server/game.zig:4146). Only `error.WouldBlock` is converted to `.none` (src/litenet/server.zig:106).

## Connect handshake

`poll` returns one of three events; the union is the entire ingress surface of the subsystem (src/litenet/server.zig:92):

```zig
    pub const Event = union(enum) {
        none,
        connected: *peer_mod.Peer,
        data: struct { peer: *peer_mod.Peer, payload: []const u8 },
    };
```

The connect path in `poll` (src/litenet/server.zig:113) has four outcomes, in this order:

1. A datagram whose property is `connect_request` is parsed; a malformed one is dropped silently (src/litenet/packet.zig:98). The parser enforces the LiteNet protocol id 13, an address size of 16 or 28, and truncation (src/litenet/packet.zig:98). Invalid protocol id, invalid address size and short datagrams all return null.
2. The Connect key from the request data is compared against `server_password`, constant time, and a mismatch sends a LiteNet Disconnect carrying `reject_invalid_password` without allocating a slot (src/litenet/packet.zig:147, src/litenet/packet.zig:95). Retransmits from an existing peer are re-checked, so auth is never skipped on retransmit.
3. A retransmitted request from an address that already has a live slot only refreshes the recorded connection fields and re-sends ConnectAccept with the peer's stored `local_id` (src/litenet/server.zig:147).
4. A new source passes the per-IP join gate, then `allocPeer` runs and ConnectAccept is written; the peer is returned as `.connected`. The rate gate compares source IPs at host-order key granularity against `join_rate_limit_ms`, exempts loopback, and rejects with `reject_rate_limit` before any slot is allocated (src/litenet/server.zig:36, src/litenet/packet.zig:96). The IP table is append-only with oldest-entry eviction so the limit keeps applying once the 64-entry table fills (src/litenet/server.zig:52).

Transport accept is not authentication. `Game.onConnected` allocates the game-side client slot, installs the ACK pump, and sends the 17-byte `0xCA` + GUID challenge by way of a reliable send; the peer only becomes `authenticated` when that GUID is echoed back, which is where the transport boundary with the join subsystem sits (src/server/game/net_handlers.zig:13, src/server/game/net_handlers.zig:49). The challenge marker and size are wire constants in the shared leaf module (src/protocol.zig:10).

## Packet framing

Every datagram opens with one property byte: the low five bits are the `PacketProperty` ordinal and the high two bits are the connection number, so the mux between concurrent connections rides that byte (src/litenet/packet.zig:72, src/litenet/packet.zig:80). The game's Managed LiteNetLib ordinal table is reflected verbatim, including `connect_request = 5`, and the enum stays non-exhaustive so a hostile ordinal cannot panic the decode (src/litenet/packet.zig:48).

The framing sizes every reader and writer is built on (src/litenet/packet.zig:15):

```zig
pub const header_size: usize = 1;
pub const channeled_header_size: usize = 4;
/// FragmentId:u16 + FragmentPart:u16 + FragmentsTotal:u16 (after channeled header).
pub const fragment_header_size: usize = 6;
pub const fragmented_header_total: usize = channeled_header_size + fragment_header_size; // 10
```

A channeled (reliable) datagram is that four-byte header plus the user bytes, and the writer is the layout of record (src/litenet/packet.zig:172):

```zig
pub fn writeChanneled(buf: []u8, seq: u16, channel_id: u8, conn_num: u8, user: []const u8) ![]u8 {
    const total = channeled_header_size + user.len;
    if (buf.len < total) return error.Overflow;
    buf[0] = makeByte0(.channeled, conn_num);
    std.mem.writeInt(u16, buf[header_size..][0..2], seq, .little);
    buf[3] = channel_id;
    @memcpy(buf[4..][0..user.len], user);
    return buf[0..total];
}
```

A fragment sets bit `0x80` on byte 0 and inserts the 6-byte fragment header between the channel id and the payload (src/litenet/packet.zig:183). The unreliable property is a bare property byte followed by the user bytes with no sequence and no ACK (src/litenet/peer.zig:263). `merged` is a different framing entirely - property, `u16` subpacket size, subpackets - and is refused when nested, which bounds recursion depth at one (src/litenet/peer.zig:546).

Two properties are handled outside the game layer: a `ping` is answered with an 11-byte `pong` (property, sequence, `i64` .NET `DateTime.UtcNow.Ticks` via `clock.dotnetUtcTicks`), and an `mtu_check` is echoed at its own length as `mtu_ok` (src/litenet/peer.zig:626, src/litenet/peer.zig:642). RTT on the client is a local Stopwatch; the ticks feed LiteNetLib `_remoteDelta` / `RemoteUtcTime`, so a mono-scaled stand-in would read as year 0001. A wrong pong size fails the client's own packet verification, which is why the length is pinned rather than approximated. `broadcast`, `unconnected_message`, `peer_not_found`, `invalid_protocol` and `nat_message` fall through the `else` arm and are dropped, and no LiteNet-level encryption or NAT punch path exists in these files (src/litenet/peer.zig:662).

## Reliability window, channels and ACKs

Each peer owns a 64-slot send window, a receive bitmap, and a retransmit store. A pending slot holds one MTU-sized datagram (src/litenet/peer.zig:39):

```zig
const Pending = struct {
    used: bool = false,
    seq: u16 = 0,
    len: u16 = 0,
    last_sent_ns: u64 = 0,
    data: [pending_bytes]u8 = undefined,
};
```

The window state on the peer is sequences plus a bitmap, not a ring of payloads (src/litenet/peer.zig:169):

```zig
    local_seq: u16 = 0,
    local_window_start: u16 = 0,
    remote_window_start: u16 = 0,
    remote_seq_next: u16 = 0,
    /// Bits for remote sequences currently in window (for duplicate detect + acks).
    ack_bits: [ack_bitmap_bytes]u8 = .{0} ** ack_bitmap_bytes,
    must_ack: bool = false,
    pending: [pending_cap]Pending = [_]Pending{.{}} ** pending_cap,
```

`pending_cap` equals the window size and `max_sequence` is 32768, asserted divisible so consecutive in-window sequence numbers never collide on a slot across wrap (src/litenet/peer.zig:15, src/litenet/packet.zig:44). `relSeq` maps a difference into `[-half, half)` with modular wrap, and every window comparison in the file is built on it (src/litenet/peer.zig:720).

Sending is direct: `sendReliable` writes a single channeled datagram when the payload fits the negotiated MTU, otherwise it splits into parts under one fresh `frag_id` and retries each part on `error.WindowFull` until the caller's deadline, pumping ACKs and sleeping 2 ms every fourth attempt so a real round trip can land (src/litenet/peer.zig:281, src/litenet/peer.zig:322). Stock instead queues packages and flushes selectively; this subsystem has no send queue, so every package is effectively flushed on send and the stock `get_FlushQueue` property selects nothing (DIVERGENCES §1; src/litenet/peer.zig:274).

Ack generation is batched: `handlePacket` sets `must_ack` and flushes immediately, and the ACK payload is the window-start sequence plus the game's `(windowSize-1)/8+2 = 9` bitmap bytes on the ReliableOrdered channel id 2 (src/litenet/peer.zig:703, src/litenet/packet.zig:248). Inbound ACKs run through `processAck`, which extracts the reported window start, walks `local_window_start` up to `local_seq`, frees each slot whose bit is set, then slides the window past contiguous free sequences; an ACK whose base is outside the window is ignored (src/litenet/peer.zig:667). Retransmit scanning is gated by `next_resend_check_ns` so the frequent `WindowFull` retry loops do not walk all 64 slots each call, and a due packet waits at most `resend_ns/8` beyond the 80 ms resend interval (src/litenet/peer.zig:375).

Inbound reliable delivery is ordered. A datagram for `remote_seq_next` delivers immediately and then drains any held successors; a newer sequence inside the window is copied into `hold_data` at `seq % window_size` until the gap fills, falling back to on-first-sight delivery if the hold slot is busy so a reordering flood cannot wedge the channel; a duplicate or stale sequence is dropped (src/litenet/peer.zig:596, src/litenet/peer.zig:517). A sequence at or beyond `max_sequence` is rejected rather than aliased into the window (src/litenet/peer.zig:567).

Fragmented messages reassemble into per-peer slots keyed by `frag_id`, because two large C2S messages can interleave (src/litenet/peer.zig:130):

```zig
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
```

There are exactly two assembly slots; a third concurrently fragmented C2S message is dropped and counted in `asm_drops`, where stock would keep a dictionary entry (src/litenet/peer.zig:198, src/litenet/peer.zig:424). Completed payloads are reassembled in part order into `deliver_buf`, which stays valid only until the next `handlePacket` (src/litenet/peer.zig:441).

## MTU, caps and mailboxes

The compile-time frame cap is the stock `MaxPacketSize` 1432 - the last entry of the stock `PossibleMtu` list - and the per-peer part and pending buffers all derive from it (src/litenet/packet.zig:30). The negotiated size is learned from the client's own probes: `peer_mtu` only ever climbs, is clamped to 1432, and 0 means not yet negotiated (src/litenet/peer.zig:642). Senders must guard on `singleUserLimit()` rather than the compile cap, because that method folds the negotiated MTU in and a frame between the two would otherwise return `error.Overflow` and be dropped with no fallback (src/litenet/peer.zig:256).

Caps, all fixed and all per peer:

- `max_payload` is 524288 bytes, the assembled user-message ceiling; the fragment part count is derived from it and `max_fragment_user`, not from a round number (src/litenet/peer.zig:10, src/litenet/peer.zig:25).
- The out-of-order hold is bounded by the window: `hold_len` and `hold_data` are `[window_size]`, and a payload larger than `max_single_user` is not held (src/litenet/peer.zig:213, src/litenet/peer.zig:517).
- The extra mailbox holds user payloads pulled out of a `merged` datagram or drained mid-send: `extra_q_len = 64` slots with a byte budget of 64 times `max_single_user` (src/litenet/peer.zig:30, src/litenet/peer.zig:219). `extraFull` gates the caller, and an overflow is counted in `extra_drops` rather than silently dropped, because the packet has already been ACKed and the client will not resend it (src/litenet/peer.zig:471, src/litenet/peer.zig:476).
- `Capture` is the test-only outbound recorder: 256 slots of 8192 bytes, dropped oldest first (src/litenet/peer.zig:48). It is the only reason the transport package reaches into `wire/`.

## Tick wiring

Ingress runs at the top of every tick, bounded: at most 64 datagram polls per tick, each returning one `.none`, `.connected` or `.data` event (src/server/game/step.zig:26, src/server/game/step.zig:44). The poll loop breaks on `.none` and stops at the cap, so one chatty peer cannot monopolize the 50 ms budget; `connected` runs `Game.onConnected` and `data` runs `Game.onData`, both with failure counters rather than a crash (src/server/game/step.zig:65). Immediately after the drain the tick calls `reapStalePeers` (src/server/game/step.zig:81).

Egress has no queue to flush, so there is no end-of-tick flush step: every `sendReliable` or `sendUnreliable` writes the datagram to the socket at the call site. What the send path does need is window pressure relief, so `sendReliablePumped` sets `peer.reliable_send_deadline_ns`, retries on `error.WindowFull`, and calls `pollNetOnce` between attempts (src/server/game/net.zig:183). While `Game.pumping` is set (mid-send or mid-`onData`), `pollNetOnce` narrows to `drainControl`, which applies inbound ACKs and pings without delivering game payloads, copying any user payload into the peer extra mailbox for a later poll (src/server/game/net.zig:400, src/litenet/server.zig:207). `drainControl` stops consuming datagrams when any live peer's mailbox is full, because `handlePacket` ACKs a packet before the mailbox sees it and a dropped already-ACKed package is lost for good (src/litenet/server.zig:200).

Teardown paths are three. A LiteNet Disconnect property clears `alive` and `authenticated` and frees every pending slot so the slot can be reused without a stuck window (src/litenet/peer.zig:618). The tick's `reapStalePeers` reaps a peer whose `challenge_ns` age exceeds the 10 s auth-state cap even if it keeps the socket warm, and a peer whose `last_recv_ns` is older than `peer_stale_ms` (default 10000 ms), applying the same pending and window release (src/server/game/tick.zig:1557, src/server/game/tick.zig:1572, src/server/game/types.zig:136). Saving the player on reap happens above this subsystem, in the same loop that clears the client slot (src/server/game/tick.zig:1582).

Nothing in this subsystem persists. Peer slots, windows, assemblies and the IP rate table are plain in-memory struct fields reset by `p.* = .{}` on accept; the only syscall-level state is the bound socket, closed by `Server.deinit` (src/litenet/server.zig:88). A restart therefore drops all connections, which is correct for a transport but means reconnect handling is entirely the game layer's problem.

## See also

- [wire.md](wire.md) - package framing, ids and the pre-auth challenge envelope above this layer.
- [join.md](join.md) - the phase machine driven by `onConnected` and the challenge echo.
- [tick.md](tick.md) - the 20 TPS loop that drains and drives these sends.
- [ARCHITECTURE.md](../ARCHITECTURE.md) - net stack overview and the `port + 2` LiteNet port rule.
- [STATE_MACHINES.md](../STATE_MACHINES.md) - the LiteNet peer lifecycle diagram and the reap windows.
