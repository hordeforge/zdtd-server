//! Coverage-guided fuzz targets for remote wire parsing boundaries and
//! other untrusted-input surfaces (admin lines, map XML, COG headers,
//! config XML patches, quest catalogs, GSI text builders, save formats).

const std = @import("std");
const packet = @import("litenet/packet.zig");
const frame = @import("wire/frame.zig");
const binary = @import("wire/binary.zig");
const packages = @import("wire/packages.zig");
const platform_user = @import("wire/platform_user.zig");
const stock_te = @import("wire/stock_te.zig");
const stock_inv = @import("wire/stock_inv.zig");
const stock_quest = @import("wire/stock_quest.zig");
const stock_buff = @import("wire/stock_buff.zig");
const admin = @import("server/admin.zig");
const components = @import("ecs/components.zig");
const mode_pack = @import("server/mode.zig");
const zdtd_config = @import("server/zdtd_config.zig");
const serverconfig = @import("server/config.zig");
const serverinfo = @import("server/serverinfo_tcp.zig");
const xml_util = @import("assets/xml_util.zig");
const xml_patch = @import("assets/xml_patch.zig");
const quests_xml = @import("assets/quests.zig");
const biome_layers = @import("assets/biome_layers.zig");
const gamestages_xml = @import("assets/gamestages.zig");
const loot = @import("assets/loot.zig");
const dtm = @import("world/dtm.zig");
const dem = @import("world/dem.zig");
const water = @import("world/water.zig");
const containers = @import("world/containers.zig");
const workstations = @import("world/workstations.zig");
const biomes = @import("world/biomes.zig");
const prefabs = @import("world/prefabs.zig");
const tts = @import("world/tts.zig");
const store = @import("world/store.zig");
const path_mod = @import("ecs/path.zig");

const packet_corpus = [_][]const u8{
    "",
    &.{ 0xff, 0xff, 0xff, 0xff },
    &.{ 5, 13, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 16 },
    &.{ 1, 0, 0, 0 },
    &.{ 0x81, 0, 0, 0, 1, 0, 0, 0, 1, 0 },
    // oversized claimed connect payload / truncated channeled fragment
    &.{ 5, 0xff, 0xff, 0xff, 0xff },
    &.{ 2, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
};

test "fuzz LiteNet packet decoders" {
    try std.testing.fuzz({}, fuzzPacketDecoders, .{ .corpus = &packet_corpus });
}

fn fuzzPacketDecoders(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    var storage: [packet.max_packet_size * 2]u8 = undefined;
    const len: usize = smith.slice(&storage);
    const input = storage[0..len];

    if (packet.parseConnectRequest(input)) |request| {
        try std.testing.expect(request.data.len <= input.len);
        try std.testing.expect(request.connection_number <= 3);
    }
    if (packet.parseChanneled(input)) |info| {
        try std.testing.expect(info.user.len <= input.len);
        if (info.fragmented) {
            try std.testing.expect(input.len >= packet.fragmented_header_total);
        } else {
            try std.testing.expect(input.len >= packet.channeled_header_size);
        }
    }
    if (packet.readNetString(input)) |value| {
        try std.testing.expect(value.len <= input.len);
    }
    _ = packet.connectKeyMatches(input, "fuzz-password");
}

// zlib of package stream: content_len=7, id=42, body="hello"
// (matches wire/frame.zig "compressed zlib package stream parses" test).
const frame_zlib_hello = [_]u8{
    0x78, 0x9c, 0x63, 0x67, 0x60, 0x60, 0xd0, 0x62, 0xc8, 0x48, 0xcd, 0xc9,
    0xc9, 0x07, 0x00, 0x07, 0xa5, 0x02, 0x46,
};

const frame_corpus = [_][]const u8{
    "",
    &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    &.{ 0, 6, 0, 0, 0, 0, 0, 1, 0, 2, 0, 0, 0, 1, 0 },
    // compressed flag set, truncated zlib header
    &.{ 0, 2, 0, 0, 0, 1, 0, 1, 0, 0x78, 0x9c },
    // full zlib-compressed single package (channel=0, compressed=1, count=1)
    &([_]u8{ 0, 19, 0, 0, 0, 1, 0, 1, 0 } ++ frame_zlib_hello),
    // gzip magic under compressed flag (header sniff path)
    &.{ 0, 4, 0, 0, 0, 1, 0, 1, 0, 0x1f, 0x8b, 0x08, 0x00 },
    // claimed large package body truncated mid-stream
    &.{ 0, 0xff, 0xff, 0x00, 0x00, 0, 0, 1, 0 },
    // multi-package envelope with empty bodies
    &.{ 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0 },
    // encrypted flag set (must reject)
    &.{ 0, 6, 0, 0, 0, 0, 1, 1, 0, 2, 0, 0, 0, 1, 0 },
    // zero package count
    &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    // negative payload size (LE 0xffffffff)
    &.{ 0, 0xff, 0xff, 0xff, 0xff, 0, 0, 1, 0 },
};

test "fuzz channel envelope decoder" {
    try std.testing.fuzz({}, fuzzChannelEnvelope, .{ .corpus = &frame_corpus });
}

fn fuzzChannelEnvelope(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    var storage: [4096]u8 = undefined;
    const len: usize = smith.slice(&storage);
    const input = storage[0..len];
    var decoded: [32]frame.Package = undefined;
    const count = frame.parseChannelPayload(input, &decoded);
    try std.testing.expect(count <= decoded.len);
    for (decoded[0..count]) |pkg| {
        try std.testing.expect(pkg.body.len <= 512 * 1024);
    }
}

const package_corpus = [_][]const u8{
    "",
    &.{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff },
    &.{ 0, 0, 0 },
    &.{ 1, 0xff, 0xff, 0xff, 0xff },
    &.{ 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    // legacy set-block 14-byte form
    &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0 },
    // stock set-block: no user | count=1 | pos ref | entity | flags | raw | dmg | local
    &.{ 0, 1, 0, 1, 10, 0, 0, 0, 61, 0, 0, 0, 0x90, 1, 0, 0, 106, 0, 0, 0, 1, 13, 0, 0, 0, 0, 0, 106, 0, 0, 0 },
    // set-block change count max (claimed huge count, truncated stream)
    &.{ 0, 0xff, 0x7f },
    // chat: type | sender | 7bit-len "hi"
    &.{ 0, 106, 0, 0, 0, 2, 'h', 'i' },
    // chat: overlong 7-bit string length
    &.{ 0, 106, 0, 0, 0, 0xff, 0xff, 0xff, 0xff, 0x0f },
    // lock: locking | channel | count=0
    &.{ 1, 0, 0, 0, 0, 0, 0 },
    // explosion head: 3xf32 + 3xi32 + 4xf32 + blob_len=0 + entity + delay
    &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    // explosion with huge claimed blob_len
    &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 0xff, 0x7f, 0, 0, 0, 0, 0, 0, 0, 0 },
    // npc quest list: trader entity + count 0
    &.{ 1, 0, 0, 0, 0, 0 },
    // quest objective update minimal
    &.{ 0, 0, 0, 0, 0 },
    // storage TE: handle + xyz + block + empty-ish tail
    &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    // workstation TE truncated after outer header
    &.{ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    // console cmd: 7bit-len oversize
    &.{ 0x80, 0x80, 0x01, 'x' },
    // inv data request stock minimal
    &.{ 106, 0, 0, 0, 0 },
    // vehicle control: entity + op + 2xf32
    &.{ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    // trader trade minimal
    &.{ 1, 0, 0, 0, 1, 0, 1, 0, 0 },
    // entity attach: type + rider + vehicle + slot
    &.{ 0, 106, 0, 0, 0, 1, 0, 0, 0, 0, 0 },
    // entity attach mount request: slot -1 (EntityVehicle::EnterVehicle)
    &.{ 0, 106, 0, 0, 0, 1, 0, 0, 0, 0xFF, 0xFF },
    // entity attach dismount request: vehicle -1 and slot -1 (Entity::SendDetach)
    &.{ 2, 106, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF },
    // stock vehicle data sync: sender + vehicle + syncFlags + len + payload
    &.{ 106, 0, 0, 0, 63, 0, 0, 0, 1, 0, 2, 0, 0xAA, 0xBB },
    // land claim repair: xyz + begin
    &.{ 0, 0, 0, 0, 61, 0, 0, 0, 0, 0, 0, 0, 1 },
    // chunk body: cx,cz,pad + 256 heights zeros
    &([_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } ++ ([_]u8{0} ** 256)),
    // login: "Bot" + two null PUIDs + empty tokens + versions + discord u64
    &.{ 3, 'B', 'o', 't', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    // login: name + present Steam PUID (present, version, "Steam", "1")
    &.{ 1, 'a', 1, 1, 5, 'S', 't', 'e', 'a', 'm', 1, '1', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    // ally request: two null PUIDs + addAlly
    &.{ 0, 0, 1 },
    // ally request: present source, null target, addAlly
    &.{ 1, 1, 3, 'E', 'O', 'S', 2, 'i', 'd', 0, 0 },
    // PUID with an overlong 7-bit string length
    &.{ 1, 1, 0xff, 0xff, 0xff, 0xff, 0x0f },
};

test "fuzz variable-length C2S package decoders" {
    try std.testing.fuzz({}, fuzzPackageDecoders, .{ .corpus = &package_corpus });
}

fn fuzzPackageDecoders(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    var storage: [8192]u8 = undefined;
    const len: usize = smith.slice(&storage);
    const input = storage[0..len];

    var changes: [32]packages.BlockChange = undefined;
    if (packages.parseSetBlockChanges(input, &changes)) |count| {
        try std.testing.expect(count <= changes.len);
    } else |_| {}
    _ = packages.parseSetBlockBody(input) catch null;
    _ = packages.parseLockRequest(input) catch null;
    if (packages.parseStockChat(input)) |chat| {
        try std.testing.expect(chat.msg.len <= input.len);
    } else |_| {}
    _ = packages.parseExplosionInitiate(input) catch null;
    _ = packages.parseNpcQuestList(input) catch null;
    _ = packages.parseQuestObjectiveUpdate(input) catch null;
    _ = packages.parseQuestOp(input) catch null;
    _ = packages.parsePosAndRotBody(input) catch null;
    _ = packages.parseAliveFlagsBody(input) catch null;
    _ = packages.parseEntitySpeedsBody(input) catch null;
    _ = packages.parsePlayerDataEcdHead(input) catch null;
    _ = packages.parseDamageHead(input) catch null;
    _ = packages.parseChunkBody(input) catch null;
    _ = packages.parseRequestToSpawnPlayer(input) catch null;
    _ = packages.parseInventoryBodyNative(input) catch null;
    _ = packages.parseInvTxRequest(input) catch null;
    _ = packages.parseInvDataRequest(input) catch null;
    _ = packages.parseInvDataRequestStock(input) catch null;
    _ = packages.parseChunkRemoveBody(input) catch null;
    _ = packages.parseCollectBody(input) catch null;
    _ = packages.parseEntityAttach(input) catch null;
    _ = packages.parseLandClaimRepair(input) catch null;
    _ = packages.parseTraderTrade(input) catch null;
    _ = packages.parseVehicleControl(input) catch null;
    if (packages.parseVehicleDataSync(input)) |s| {
        try std.testing.expect(s.data.len + 12 <= input.len);
    } else |_| {}
    var cmd_buf: [256]u8 = undefined;
    const cmd = packages.parseConsoleCmd(input, &cmd_buf);
    try std.testing.expect(cmd.len <= cmd_buf.len);
    if (stock_te.parseStorageTeBody(input)) |te| {
        try std.testing.expect(te.item_count <= te.items.len);
        // Apply chain: client-declared grid geometry must stay within the
        // fixed container slot array and never shrink addressable slots.
        var cont: containers.Container = .{};
        const before = cont.slot_count;
        stock_te.applyParsedToContainer(&te, &cont, null, null);
        try std.testing.expect(cont.slot_count <= containers.max_container_slots);
        try std.testing.expect(cont.slot_count >= before);
    } else |_| {}
    if (stock_te.parseWorkstationTeBody(input)) |ws| {
        // The echo re-emits every count verbatim, so an accepted count that does
        // not fit our fixed store would read past it.
        try std.testing.expect(ws.fuel_n <= ws.fuel.len);
        try std.testing.expect(ws.input_n <= ws.input.len);
        try std.testing.expect(ws.tools_n <= ws.tools.len);
        try std.testing.expect(ws.output_n <= ws.output.len);
        try std.testing.expect(ws.last_input_n <= ws.last_input.len);
        try std.testing.expect(ws.queue_n <= ws.queue.len);
        try std.testing.expect(ws.craft_complete_n <= ws.craft_complete.len);
        try std.testing.expect(ws.melt_n <= ws.melt.len);
        for (ws.queue[0..ws.queue_n]) |q| try std.testing.expect(q.recipeBlob().len <= workstations.recipe_blob_max);
    } else |_| {}
    if (stock_te.parsePoweredTriggerTeBody(input)) |trig| {
        // Wires are copied into a fixed array; a client-declared count must
        // never make the parser report more than it stored.
        try std.testing.expect(trig.wire_n <= trig.wires.len);
        try std.testing.expect(trig.wire_n <= trig.wire_total);
    } else |_| {}
    _ = stock_te.parseWorkstationTeBody(input) catch null;

    // Identity-bearing bodies: a hostile login or ally request must never write
    // past the fixed platform/id buffers, and a null identity is a valid value.
    var plat_buf: [platform_user.max_platform_len]u8 = undefined;
    var puid_buf: [platform_user.max_id_len]u8 = undefined;
    var pr: binary.Reader = .{ .data = input };
    if (platform_user.read(&pr, &plat_buf, &puid_buf)) |maybe| {
        if (maybe) |id| {
            try std.testing.expect(id.platform.len <= plat_buf.len);
            try std.testing.expect(id.id.len <= puid_buf.len);
        }
    } else |_| {}
    var sr: binary.Reader = .{ .data = input };
    platform_user.skip(&sr) catch {};
    var login_name: [32]u8 = undefined;
    if (packages.parsePlayerLogin(input, &login_name)) |login| {
        try std.testing.expect(login.name.len <= login_name.len);
        if (login.internalId().get()) |id| try std.testing.expect(id.id.len <= platform_user.max_id_len);
    } else |_| {}
    _ = packages.parseAllyRequest(input) catch null;
}

const inv_corpus = [_][]const u8{
    "",
    &.{ 0, 0 }, // empty stack (count 0)
    &.{ 1, 0, 0 }, // count=1, empty ItemValue (ver 0)
    // count=1, ItemValue v9 empty-ish: ver=9, flags=0, type u16, use f32, quality, meta, meta_count=0, mods=0, cos=0, act, ammo, seed, tex=false
    &.{ 1, 0, 9, 0, 13, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    // holding: entity_id + stack(empty) + idx
    &.{ 106, 0, 0, 0, 0, 0, 0 },
    // drop: empty stack + lots of f32 + ids
    &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    // drop container: dropped_by | empty string | xyz | count 0
    &.{ 106, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    // huge claimed stack list count
    &.{ 0xff, 0xff },
    // nested mod explosion attempt: count=1, ver=9, flags, type, … mod_n=255
    &.{ 1, 0, 9, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff },
    // player inventory body: toolbelt present (0 stacks), no bag, no equipment
    &.{ 1, 0, 0, 0, 0 },
    // bag present: ver=1, count=0, no locks, touched, no prefs
    &.{ 0, 1, 1, 0, 0, 0, 1, 0, 0 },
    // bag with huge claimed stack count, truncated
    &.{ 0, 1, 0, 0xff, 0xff },
};

test "fuzz inventory item stack decoders" {
    try std.testing.fuzz({}, fuzzInventoryDecoders, .{ .corpus = &inv_corpus });
}

fn fuzzInventoryDecoders(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    var storage: [8192]u8 = undefined;
    const len: usize = smith.slice(&storage);
    const input = storage[0..len];

    _ = stock_inv.readHoldingItem(input) catch null;
    _ = stock_inv.readItemDrop(input) catch null;
    if (stock_inv.readDropItemsContainer(input)) |drop| {
        try std.testing.expect(drop.item_count <= drop.items.len);
    } else |_| {}
    var r: binary.Reader = .{ .data = input };
    _ = stock_inv.readItemStack(&r) catch null;
    r = .{ .data = input };
    _ = stock_inv.readItemValue(&r) catch null;
    r = .{ .data = input };
    var slots: [16]stock_inv.StockSlot = undefined;
    _ = stock_inv.readItemStackList(&r, &slots) catch null;

    // Full C2S inventory apply: toolbelt/bag/equipment/locks/prefs sections
    // parsed from an untrusted body must never write outside the fixed slots.
    var inv: components.Inventory = .{};
    stock_inv.applyPlayerInventoryBody(input, &inv, null, null) catch {};
}

const binary_corpus = [_][]const u8{
    "",
    &.{0},
    &.{ 2, 'o', 'k' },
    &.{ 0x80, 0x01 }, // 7-bit length 128 without payload
    &.{ 0xff, 0xff, 0xff, 0xff, 0x0f }, // max-ish 7-bit
    &.{ 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f }, // overlong / overflow shift
    &.{ 5, 'h', 'e', 'l', 'l', 'o' },
    &.{0x00}, // empty string
};

test "fuzz binary .NET string reader" {
    try std.testing.fuzz({}, fuzzBinaryReader, .{ .corpus = &binary_corpus });
}

fn fuzzBinaryReader(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    var storage: [4096]u8 = undefined;
    const len: usize = smith.slice(&storage);
    const input = storage[0..len];

    var r: binary.Reader = .{ .data = input };
    var sbuf: [512]u8 = undefined;
    if (r.readString(&sbuf)) |s| {
        try std.testing.expect(s.len <= sbuf.len);
        try std.testing.expect(s.len <= input.len);
    } else |_| {}

    r = .{ .data = input };
    _ = r.skipString() catch null;

    r = .{ .data = input };
    _ = binary.read7BitEncodedInt(&r) catch null;
}

const quest_corpus = [_][]const u8{
    "",
    &.{ 106, 0, 0, 0, 0 }, // share_quest event without tail
    &.{ 106, 0, 0, 0, 1, 7, 0, 0, 0 }, // remove_quest
    &.{ 106, 0, 0, 0, 0, 7, 0, 0, 0, 11, 't', 'i', 'e', 'r', '1', '_', 'c', 'l', 'e', 'a', 'r', 0 },
    &.{ 106, 0, 0, 0, 4 }, // invalid event (should reject)
    &.{ 106, 0, 0, 0, 2, 1, 0, 0, 0, 106, 0, 0, 0 },
};

test "fuzz shared quest head decoder" {
    try std.testing.fuzz({}, fuzzSharedQuest, .{ .corpus = &quest_corpus });
}

fn fuzzSharedQuest(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    var storage: [1024]u8 = undefined;
    const len: usize = smith.slice(&storage);
    const input = storage[0..len];
    if (stock_quest.parseSharedQuestHead(input)) |head| {
        try std.testing.expect(head.quest_id_len <= head.quest_id_storage.len);
        try std.testing.expect(@intFromEnum(head.event) <= 3);
    } else |_| {}
}

const quest_event_corpus = [_][]const u8{
    "",
    // TryRallyMarker: entity | pos | event | empty tags | questCode
    &.{ 171, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 39, 0, 0, 0 },
    // RallyMarkerLocked: same head + u64 extraData
    &.{ 171, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 0, 39, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    // LockPOI: questID string + SharedWithList with an overlong count
    &.{ 171, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 7, 0, 39, 0, 0, 0, 1, 'q', 200 },
    // eventType past ResetTraderQuests (should reject)
    &.{ 171, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 17, 0, 39, 0, 0, 0 },
    // truncated head
    &.{ 171, 0, 0, 0, 0, 0, 0 },
    // SetupRestorePower: two strings + two counted lists
    &.{ 171, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 13, 0, 39, 0, 0, 0, 0, 0, 0, 0 },
};

test "fuzz quest event head decoder" {
    try std.testing.fuzz({}, fuzzQuestEvent, .{ .corpus = &quest_event_corpus });
}

fn fuzzQuestEvent(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    var storage: [1024]u8 = undefined;
    const len: usize = smith.slice(&storage);
    const input = storage[0..len];
    if (stock_quest.parseQuestEventHead(input)) |head| {
        try std.testing.expect(@intFromEnum(head.event) <=
            @intFromEnum(stock_quest.QuestEventType.reset_trader_quests));
        // Anything the server can re-emit must round-trip through the builder.
        var out: [64]u8 = undefined;
        if (stock_quest.buildQuestEvent(&out, head)) |body| {
            const again = try stock_quest.parseQuestEventHead(body);
            try std.testing.expectEqual(head.event, again.event);
            try std.testing.expectEqual(head.entity_id, again.entity_id);
            try std.testing.expectEqual(head.quest_code, again.quest_code);
        } else |_| {}
    } else |_| {}
}

const admin_corpus = [_][]const u8{
    "",
    "help",
    "?",
    "status",
    "save",
    "list",
    "players",
    "kick 0",
    "kick notanumber",
    "ban 1",
    "unban deadbeef",
    "unban nothex",
    "give 0 1 5",
    "give 0",
    "tele 0 1.5 61 -10.25",
    "tele 0 a b c",
    "say hello world",
    "say",
    "kill 106",
    "inv 0",
    "gettime",
    "settime day",
    "settime night",
    "settime 8000",
    "settime 1 12 30",
    "version",
    // adversarial lengths / whitespace
    "kick ",
    "give 999999999999999999 1 1",
    "tele 0 1e39 0 0",
    "say " ++ ("x" ** 200),
    "\x00kick 0",
    "KICK 0",
    " help",
};

test "fuzz admin TCP command parser" {
    try std.testing.fuzz({}, fuzzAdminCommand, .{ .corpus = &admin_corpus });
}

fn fuzzAdminCommand(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    var storage: [1024]u8 = undefined;
    const len: usize = smith.slice(&storage);
    // Admin lines are text; still exercise arbitrary bytes from the fuzzer.
    _ = admin.parseCommand(storage[0..len]);
}

const map_xml_corpus = [_][]const u8{
    "",
    "<property name=\"HeightMapSize\" value=\"6144,6144\"/>",
    "<property name=\"HeightMapSize\" value=\"0,0\"/>",
    "<property name=\"HeightMapSize\" value=\"-1,10\"/>",
    "<property name=\"HeightMapSize\" value=\"abc,def\"/>",
    "HeightMapSize value=6144,6144",
    "<spawnpoint position=\"0,61,0\"/>",
    "<spawnpoint position=\"-100,10,200\"/>",
    "<spawnpoint position=\"1,2\"/>",
    "<spawnpoint position=\"1,2,3,4\"/>",
    // nested / truncated
    "<a><b position=\"1,2,3\"/></a>",
    "position=\"" ++ ("9" ** 40) ++ ",1,1\"",
    "HeightMapSize" ++ ("x" ** 100) ++ "value=\"1,1\"",
};

test "fuzz map XML size and spawn parsers" {
    try std.testing.fuzz({}, fuzzMapXml, .{ .corpus = &map_xml_corpus });
}

fn fuzzMapXml(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    var storage: [4096]u8 = undefined;
    const len: usize = smith.slice(&storage);
    const input = storage[0..len];
    if (dtm.parseMapInfoSize(input)) |sz| {
        try std.testing.expect(sz.w > 0);
        try std.testing.expect(sz.h > 0);
    } else |_| {}
    var pts: [16]dtm.SpawnPoint = undefined;
    const n = dtm.parseSpawnPoints(input, &pts);
    try std.testing.expect(n <= pts.len);
}

const toml_corpus = [_][]const u8{
    "",
    "[stream]\nmax_streamed_chunks = 100\nstream_radius_min = 5\n",
    "[authority]\nmode = \"observe\"\ninterest_range_blocks = 120.5\n",
    "[authority]\nmode = 'single'\n# comment\n",
    "[feature]\nwire_chunks = yes\n",
    "[feature]\ndeco_trees = off\n",
    "[feature]\ndeco_mirror = no\nblock_id_mapping = false\n",
    "[unclosed\n",
    "key_outside_section = 1\n",
    "[stream]\nmax_streamed_chunks = 999999999999999999999999\n",
    "[stream]\nmax_streamed_chunks = \"7\"\n",
    "[stream]\r\nstream_radius_min = -3\r\n",
    "[stream]\nchunk_adds_per_stream_tick = 1 # trailing comment\n",
    "[ authority ]\nmode=\n",
    "=\n[]\nx",
};

test {
    // Stateful peer fuzz targets (fragment reassembly, ack window) live in
    // peer.zig for private-fn access; reference pulls them into this build.
    _ = @import("litenet/peer.zig");
}

const mode_corpus = [_][]const u8{
    "",
    mode_pack.default_pack_toml,
    "name = \"x\"\nmax_spawned_zombies = 64\n",
    "[gameplay]\nblood_moon_frequency = 300\n",
    "max_spawned_zombies = -1\n",
    "bloodmoon_frequency = 99999999999999999999\n",
    "enable_sample_plugin = maybe\n",
    "name = \"unterminated\n[",
    "[section\n",
    "name=\n=\n# c\n",
    "[plugin]\nenable_sample_plugin = true # trailing\n",
};

test "fuzz mode pack TOML parser" {
    try std.testing.fuzz({}, fuzzModePack, .{ .corpus = &mode_corpus });
}

fn fuzzModePack(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    var storage: [4096]u8 = undefined;
    const len: usize = smith.slice(&storage);
    var p = mode_pack.parse(std.testing.allocator, storage[0..len]) catch return;
    defer p.deinit();
    // Name is either the "default" literal or an arena dupe from the input.
    try std.testing.expect(p.name.len <= @max(len, "default".len));
}

test "fuzz zdtd.toml config parser" {
    try std.testing.fuzz({}, fuzzTomlConfig, .{ .corpus = &toml_corpus });
}

fn fuzzTomlConfig(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    var storage: [4096]u8 = undefined;
    const len: usize = smith.slice(&storage);
    const input = storage[0..len];
    var f = zdtd_config.parse(std.testing.allocator, input) catch return;
    defer f.deinit();
    if (f.authority.mode) |m| try std.testing.expect(m.len <= input.len);
}

const asset_xml_corpus = [_][]const u8{
    "",
    "<quest id=\"a\" difficulty=\"1\"><property name=\"name_key\" value=\"v\"/></quest>",
    "<property force_prob=\"wrong\" name = 'ServerPort' value = \"27002\"/>",
    "<!-- unclosed comment",
    "<!-- c --><block name=\"stone\"/>",
    "<block name=\"a\">body</block>",
    "<block ><block /></block>",
    // truncated open tag / dangling quote / stray equals
    "<property name=\"x\"",
    "<property name='a' value='",
    "a = = \"v\" b=c d",
    "<property\x00name='a' value='b'/>",
    "<property name=\"65536\" value=\"1e39\"/>",
};

test "fuzz asset XML attribute scanner" {
    try std.testing.fuzz({}, fuzzAssetXml, .{ .corpus = &asset_xml_corpus });
}

fn fuzzAssetXml(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    var storage: [4096]u8 = undefined;
    const len: usize = smith.slice(&storage);
    const input = storage[0..len];

    const clean = xml_util.stripComments(std.testing.allocator, input) catch return;
    defer std.testing.allocator.free(clean);
    try std.testing.expect(clean.len <= input.len);

    if (xml_util.attr(input, 0, "name")) |v| {
        try std.testing.expect(v.len <= input.len);
    }
    if (xml_util.propertyValue(input, "value")) |v| {
        try std.testing.expect(v.len <= input.len);
    }
    var i: usize = 0;
    while (xml_util.nextElement(input, i, "<block", "</block>")) |el| {
        try std.testing.expect(el.next_i <= input.len);
        // Scan must always advance or the caller loops forever.
        try std.testing.expect(el.next_i > i);
        try std.testing.expect(el.body.len <= input.len);
        i = el.next_i;
    }
    _ = xml_util.parseU8(input);
    _ = xml_util.parseU16(input);
    _ = xml_util.parseU32(input);
    _ = xml_util.parseF32(input);
}

const cog_corpus = [_][]const u8{
    "",
    "II*\x00",
    "MM\x00*",
    // minimal TIFF LE header, IFD at 8, zero entries
    "II*\x00\x08\x00\x00\x00\x00\x00",
    // IFD with huge entry count (bounds check)
    "II*\x00\x08\x00\x00\x00\xff\xff" ++ ("\x00" ** 64),
    // zlib header only (decodeTile: truncated stream must reject, not hang)
    "\x78\x9c",
    // valid short zlib stream (decompresses to less than a full tile)
    &frame_zlib_hello,
    // zlib header followed by garbage
    "\x78\x9c" ++ ("\xff" ** 32),
};

// decodeTile output is tile_px^2 f32 (4 MiB); keep it off the fuzz stack and
// out of the per-iteration allocator churn.
var cog_tile_out: [dem.tile_px * dem.tile_px]f32 = undefined;

test "fuzz DEM COG TIFF header parser" {
    try std.testing.fuzz({}, fuzzCogHeader, .{ .corpus = &cog_corpus });
}

fn fuzzCogHeader(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    var storage: [8192]u8 = undefined;
    const len: usize = smith.slice(&storage);
    if (dem.parseCogHeader(storage[0..len])) |info| {
        try std.testing.expect(info.tile_n <= info.tile_offsets.len);
    } else |_| {}
    // Tile blobs are remote CDN range reads: zlib decode + float predictor
    // must reject truncated/garbage streams without hanging or overrunning.
    _ = dem.decodeTile(std.testing.allocator, storage[0..len], &cog_tile_out) catch {};
    // S3 key formatting must not panic on extreme lat/lon.
    var key_buf: [256]u8 = undefined;
    const lat = smith.value(i32);
    const lon = smith.value(i32);
    if (dem.tileKey(&key_buf, lat, lon)) |key| {
        try std.testing.expect(key.len <= key_buf.len);
        try std.testing.expect(key.len > 0);
    } else |_| {}
    _ = dem.elevToBlockY(smith.value(f32));
}

// Minimal base docs so patch apply exercises xpath match paths, not only reject.
const patch_base_blocks =
    \\<blocks>
    \\  <block name="stone"><property name="Material" value="Mstone"/></block>
    \\  <block name="air"><property name="Material" value="Mair"/></block>
    \\</blocks>
;

const xml_patch_corpus = [_][]const u8{
    "",
    "/blocks/block[@name='stone']/@Material",
    "/items/item[@name='x']",
    "/blocks/block[@name=\"stone\"]/property[@name='Material']/@value",
    // set by xpath
    \\<configs file="blocks.xml">
    \\  <set xpath="/blocks/block[@name='stone']/property[@name='Material']/@value">Mmetal</set>
    \\</configs>
    ,
    // remove
    \\<configs file="blocks.xml">
    \\  <remove xpath="/blocks/block[@name='air']"/>
    \\</configs>
    ,
    // append
    \\<configs>
    \\  <append xpath="/blocks"><block name="fuzz"/></append>
    \\</configs>
    ,
    // wrong target file filter
    \\<configs file="items.xml">
    \\  <set xpath="/items/item[@name='x']/@value">1</set>
    \\</configs>
    ,
    // adversarial xpath depth / empty segments / unclosed filters
    "//////////",
    "/blocks/block[@name='",
    "/blocks/block[@name='stone']/@" ++ ("a" ** 64),
    // nested ops + junk
    \\<set xpath="/blocks"><remove xpath="/"/></set>
    ,
    // huge claimed attribute value
    "<set xpath=\"/blocks/block[@name='stone']/@value\">" ++ ("Z" ** 200) ++ "</set>",
};

test "fuzz config XML patch xpath and apply" {
    try std.testing.fuzz({}, fuzzXmlPatch, .{ .corpus = &xml_patch_corpus });
}

fn fuzzXmlPatch(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    var storage: [4096]u8 = undefined;
    const len: usize = smith.slice(&storage);
    const input = storage[0..len];

    if (xml_patch.fileFromXPath(input)) |f| {
        try std.testing.expect(f.len > 0);
        try std.testing.expect(std.mem.endsWith(u8, f, ".xml"));
    }

    // Split input into base | patch when non-empty; otherwise use fixed base.
    const split = if (len == 0) 0 else smith.index(len + 1);
    const base: []const u8 = if (split == 0 or split >= len) patch_base_blocks else input[0..split];
    const patch: []const u8 = if (split >= len) input else input[split..];

    const targets = [_][]const u8{ "blocks.xml", "items.xml", "quests.xml" };
    const target = targets[smith.index(targets.len)];
    const out = xml_patch.applyPatchDoc(std.testing.allocator, base, patch, target) catch return;
    defer std.testing.allocator.free(out);
    // No-op apply is a base dupe; mutations may grow or shrink but stay finite.
    if (std.mem.eql(u8, target, "blocks.xml") and patch.len == 0) {
        try std.testing.expectEqualStrings(base, out);
    }
}

const weather_xml_corpus = [_][]const u8{
    "",
    "<weather/>",
    \\<weather name="default" prob="83" duration="6">
    \\  <Temperature range="76,80"/>
    \\  <CloudThickness range="0,0" prob="35"/>
    \\  <CloudThickness range="10,70" prob="65"/>
    \\</weather>
    \\<weather name="storm" prob="0" duration="1.1" delay="26,36">
    \\  <Wind range="40,40"/>
    \\</weather>
    ,
    // unclosed group / prefix collision / junk numbers / oversize name
    "<weather name=\"storm\"",
    "<weathermap name=\"x\"></weathermap>",
    "<weather prob=\"nan\" duration=\"-1\" delay=\"inf,nan\"><Fog min=\"nan\" max=\"1e40\"/></weather>",
    "<weather name=\"" ++ ("s" ** 80) ++ "\"><Wind range=\",\"/></weather>",
    "<weather/>" ** 40,
};

test "fuzz biomes.xml weather group parser" {
    try std.testing.fuzz({}, fuzzWeatherGroups, .{ .corpus = &weather_xml_corpus });
}

fn fuzzWeatherGroups(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    var storage: [4096]u8 = undefined;
    const len: usize = smith.slice(&storage);
    const set = biome_layers.parseWeatherGroups(storage[0..len]);
    try std.testing.expect(set.n <= biome_layers.max_weather_groups);
    var total: f32 = 0;
    var i: usize = 0;
    while (i < set.n) : (i += 1) {
        const g = &set.groups[i];
        // Every number the scheduler reads has to be finite and orderable: a NaN
        // probability would make the cumulative group walk pick nothing forever.
        try std.testing.expect(std.math.isFinite(g.prob) and g.prob >= 0);
        try std.testing.expect(g.duration >= 0);
        try std.testing.expect(g.delay_lo >= 0 and g.delay_hi >= 0);
        try std.testing.expect(g.name().len <= biome_layers.max_weather_name);
        total += g.prob;
        var pt: usize = 0;
        while (pt < biome_layers.prob_type_count) : (pt += 1) {
            const ranges = g.rangeSlice(pt);
            try std.testing.expect(ranges.len <= biome_layers.max_weather_ranges);
            for (ranges) |r| {
                try std.testing.expect(std.math.isFinite(r.lo) and std.math.isFinite(r.hi));
                try std.testing.expect(std.math.isFinite(r.weight) and r.weight >= 0);
            }
        }
    }
    // Normalization can only shrink the mass below 1 (prob /= total + 1e-6).
    try std.testing.expect(total <= 1.001);
}

const quest_xml_corpus = [_][]const u8{
    "",
    "<quests starter_quest=\"q1\" max_quest_tier=\"3\" quests_per_tier=\"2\"></quests>",
    \\<quests starter_quest="tier1_clear" max_quest_tier="6" quests_per_tier="10">
    \\  <quest id="tier1_clear" group_name_key="g" name_key="n" subtitle_key="s"
    \\         description_key="d" icon="i" category_key="c" difficulty="1">
    \\    <property name="completiontype" value="TurnIn"/>
    \\    <reward type="Exp" value="100"/>
    \\  </quest>
    \\  <quest_list id="trader_joel">
    \\    <quest id="tier1_clear"/>
    \\  </quest_list>
    \\</quests>
    ,
    // unclosed quest / huge tier attrs
    \\<quests starter_quest="x" max_quest_tier="999" quests_per_tier="0">
    \\  <quest id="a"
    ,
    // nested quest tags without close
    "<quest id=\"a\"><quest id=\"b\"></quest>",
    // many empty quest shells
    "<quest id=\"1\"/><quest id=\"2\"/><quest id=\"3\"/>",
    // null bytes / control
    "<quests\x00 starter_quest=\"x\">\x01</quests>",
    // comment + CDATA-ish noise
    "<!-- c --><quests><!-- q --><quest id=\"z\"/></quests>",
    // quest_list only
    "<quest_list id=\"L\"><quest id=\"missing\"/></quest_list>",
};

test "fuzz quests.xml catalog parser" {
    try std.testing.fuzz({}, fuzzQuestCatalog, .{ .corpus = &quest_xml_corpus });
}

fn fuzzQuestCatalog(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    var storage: [8192]u8 = undefined;
    const len: usize = smith.slice(&storage);
    var cat = quests_xml.parseCatalog(std.testing.allocator, storage[0..len]) catch return;
    defer cat.deinit();
    // Arena-owned slices must stay within catalog lifetime; just bound counts.
    try std.testing.expect(cat.defs.len < 100_000);
    try std.testing.expect(cat.lists.len < 100_000);
    try std.testing.expect(cat.starter_name.len <= len or cat.starter_name.len < 256);
}

const gsi_corpus = [_][]const u8{
    "",
    "zdtd",
    "name;with:colons\r\ninjection",
    "evil\nGameType:HACK;",
    "x" ** 128,
    "Navezgane",
    "127.0.0.1",
    "\x00\xff;Port:1;\r\n",
};

test "fuzz GSI info text builder" {
    try std.testing.fuzz({}, fuzzGsiText, .{ .corpus = &gsi_corpus });
}

fn fuzzGsiText(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    var storage: [512]u8 = undefined;
    const len: usize = smith.slice(&storage);
    const s = storage[0..len];

    var buf: [4096]u8 = undefined;
    const info: serverinfo.ServerInfo = .{
        .game_name = s,
        .game_host = s,
        .level_name = s,
        .ip = s,
        .server_version = s,
        .info_port = smith.value(u16),
        .max_players = smith.value(i32),
        .current_players = smith.value(i32),
        .world_size = smith.value(i32),
        .eac_enabled = smith.boolWeighted(1, 1),
        .password_protected = smith.boolWeighted(1, 1),
    };
    const text = serverinfo.buildInfoText(&buf, info) catch return;
    try std.testing.expect(text.len <= buf.len);
    try std.testing.expect(std.mem.startsWith(u8, text, "GameType:7DTD;\r\n"));
    try std.testing.expect(std.mem.endsWith(u8, text, "\r\n\r\n"));
    // gsiSafe must strip bare CR/LF from operator-supplied name fields so only
    // stock Key:Value;\r\n line endings remain.
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\n') try std.testing.expect(i > 0 and text[i - 1] == '\r');
        if (text[i] == '\r') try std.testing.expect(i + 1 < text.len and text[i + 1] == '\n');
    }
}

const serverconfig_corpus = [_][]const u8{
    "",
    \\<ServerSettings>
    \\  <property name="ServerPort" value="27002"/>
    \\  <property name="GameName" value="FuzzWorld"/>
    \\  <property name="ServerMaxPlayerCount" value="16"/>
    \\</ServerSettings>
    ,
    \\<ServerSettings>
    \\  <property name="ViewRadius" value="999"/>
    \\  <property name="LandClaimSize" value="40"/>
    \\  <property name="ZdtdAuthorityMode" value="observe"/>
    \\  <property name="ServerPasssword" value="typo"/>
    \\</ServerSettings>
    ,
    "<property name=\"ServerPort\" value=\"" ++ ("9" ** 40) ++ "\"/>",
    "<property name=\"GameName\" value=\"" ++ ("x" ** 200) ++ "\"/>",
    // truncated / nested noise
    "<property name=\"ServerPort\"",
    "property name=ServerPort value=1",
    "<property name=\"\x00\" value=\"\xff\"/>",
};

test "fuzz serverconfig.xml parser" {
    try std.testing.fuzz({}, fuzzServerconfig, .{ .corpus = &serverconfig_corpus });
}

fn fuzzServerconfig(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    var storage: [4096]u8 = undefined;
    const len: usize = smith.slice(&storage);
    var cfg = serverconfig.parse(std.testing.allocator, storage[0..len]) catch return;
    defer cfg.deinit();
    try std.testing.expect(cfg.port >= 0);
    try std.testing.expect(cfg.max_players <= 64);
    try std.testing.expect(cfg.view_radius >= 1 and cfg.view_radius <= 16);
    try std.testing.expect(cfg.world_name.len <= len or cfg.world_name.len <= 4);
}

const water_xml_corpus = [_][]const u8{
    "",
    \\<WaterSources>
    \\  <Water pos="1855, 77, 1406"/>
    \\  <Water pos="-192, 72, 1924"/>
    \\</WaterSources>
    ,
    "<Water pos=\"0,0,0\"/>",
    "pos=\"1, 2, 3\" pos=\"a,b,c\" pos=\"1\"",
    "pos=\"" ++ ("9" ** 20) ++ ",1,1\"",
    "pos=\"  -1 ,  61 ,  2 \"",
    "pos=\"\x00,1,2\"",
};

test "fuzz water_info.xml parser" {
    try std.testing.fuzz({}, fuzzWaterXml, .{ .corpus = &water_xml_corpus });
}

fn fuzzWaterXml(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    var storage: [4096]u8 = undefined;
    const len: usize = smith.slice(&storage);
    var src = water.parseXml(std.testing.allocator, storage[0..len]) catch return;
    defer src.deinit();
    try std.testing.expect(src.points.len <= len);
    // Point lookups must not panic on arbitrary coords.
    _ = src.waterYNear(smith.value(i32), smith.value(i32), 12);
}

const zct_corpus = [_][]const u8{
    "",
    "ZCT1",
    // empty store: magic + count 0
    &([_]u8{ 'Z', 'C', 'T', '1', 0, 0 }),
    // one container, 0 slots: pos(0,70,0) block 42, slots=0, touched, player
    &([_]u8{ 'Z', 'C', 'T', '1', 1, 0 } ++
        [_]u8{ 0, 0, 0, 0, 70, 0, 0, 0, 0, 0, 0, 0, 42, 0, 0, 0, 0, 0, 1, 1 }),
    // claimed huge count, truncated
    &([_]u8{ 'Z', 'C', 'T', '1', 0xff, 0xff }),
    // wrong magic
    &([_]u8{ 'Z', 'C', 'T', '0', 0, 0 }),
    // count=1 but slot_count huge
    &([_]u8{ 'Z', 'C', 'T', '1', 1, 0 } ++
        [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 0, 0 }),
};

test "fuzz containers.zct loader" {
    try std.testing.fuzz({}, fuzzContainersZct, .{ .corpus = &zct_corpus });
}

fn fuzzContainersZct(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    var storage: [4096]u8 = undefined;
    const len: usize = smith.slice(&storage);
    // Store is large (256 chests); keep off the fuzz stack.
    const s = try std.testing.allocator.create(containers.ContainerStore);
    defer std.testing.allocator.destroy(s);
    s.* = .{};
    s.loadFromSlice(storage[0..len]) catch return;
}

const png_sig = [_]u8{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a };
// 1x1 RGB white pixel; IDAT is a stored deflate block. Parser skips chunk CRCs.
const png_ihdr_1x1 = [_]u8{ 0, 0, 0, 13, 'I', 'H', 'D', 'R', 0, 0, 0, 1, 0, 0, 0, 1, 8, 2, 0, 0, 0, 0, 0, 0, 0 };
const png_iend = [_]u8{ 0, 0, 0, 0, 'I', 'E', 'N', 'D', 0, 0, 0, 0 };
const png_1x1_rgb = png_sig ++ png_ihdr_1x1 ++
    [_]u8{ 0, 0, 0, 15, 'I', 'D', 'A', 'T', 0x78, 0x01, 0x01, 0x04, 0x00, 0xfb, 0xff, 0, 0xff, 0xff, 0xff, 0x05, 0xfe, 0x02, 0xfe, 0, 0, 0, 0 } ++
    png_iend;

const biome_png_corpus = [_][]const u8{
    "",
    &png_sig,
    &png_1x1_rgb,
    // claimed max u32 dims (raw_len overflow guard must reject, not panic)
    &(png_sig ++ [_]u8{ 0, 0, 0, 13, 'I', 'H', 'D', 'R', 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 8, 2, 0, 0, 0, 0, 0, 0, 0 }),
    // invalid filter byte 5 in scanline (stored deflate of {5,0,0,0})
    &(png_sig ++ png_ihdr_1x1 ++
        [_]u8{ 0, 0, 0, 15, 'I', 'D', 'A', 'T', 0x78, 0x01, 0x01, 0x04, 0x00, 0xfb, 0xff, 5, 0, 0, 0, 0x00, 0x18, 0x00, 0x06, 0, 0, 0, 0 } ++
        png_iend),
    // truncated IDAT / garbage zlib
    &(png_sig ++ png_ihdr_1x1 ++ [_]u8{ 0, 0, 0, 2, 'I', 'D', 'A', 'T', 0x78, 0x9c }),
    // chunk length past EOF
    &(png_sig ++ [_]u8{ 0xff, 0xff, 0xff, 0xff, 'I', 'H', 'D', 'R' }),
    // IEND before IDAT
    &(png_sig ++ png_ihdr_1x1 ++ png_iend),
};

test "fuzz biomes.png decoder" {
    try std.testing.fuzz({}, fuzzBiomePng, .{ .corpus = &biome_png_corpus });
}

fn fuzzBiomePng(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    var storage: [4096]u8 = undefined;
    const len: usize = smith.slice(&storage);
    const input = storage[0..len];
    // Skip mid-size claimed dims: valid but each iteration would alloc MBs.
    // Tiny dims and the >max_png_dim reject path stay exercised.
    if (std.mem.indexOf(u8, input, "IHDR")) |at| {
        if (at + 12 <= input.len) {
            const w = std.mem.readInt(u32, input[at + 4 ..][0..4], .big);
            const h = std.mem.readInt(u32, input[at + 8 ..][0..4], .big);
            if ((w > 64 or h > 64) and w <= biomes.max_png_dim and h <= biomes.max_png_dim) return;
        }
    }
    var map = biomes.parsePng(std.testing.allocator, input, null) catch return;
    defer map.deinit();
    try std.testing.expect(map.width > 0 and map.height > 0);
    try std.testing.expect(map.r.len == @as(usize, @intCast(map.width)) * @as(usize, @intCast(map.height)));
    // Lookups must not panic on arbitrary world coords.
    _ = map.atWorld(smith.value(i32), smith.value(i32));
    _ = map.chunkDominant(smith.value(i32) >> 16, smith.value(i32) >> 16);
}

const prefab_xml_corpus = [_][]const u8{
    "",
    \\<prefabs>
    \\  <decoration type="model" name="house_old_bungalow_01" position="10, 40, -5" rotation="1" y_is_groundlevel="true"/>
    \\  <decoration type="model" name="part_driveway" position="0, 60, 0" rotation="0"/>
    \\</prefabs>
    ,
    "<decoration name=\"x\" position=\"1,2,3\"/>",
    "<decoration name=\"a\" position=\"1,2\"/>",
    "<decoration name=\"\" position=\"0,0,0\" rotation=\"99\"/>",
    "<decoration name=\"" ++ ("n" ** 64) ++ "\" position=\"-1,-2,-3\"/>",
    // unclosed tag / missing quotes
    "<decoration name=\"x\" position=\"1,2,3\"",
    "decoration name=x position=1,2,3",
};

test "fuzz prefabs.xml parser" {
    try std.testing.fuzz({}, fuzzPrefabsXml, .{ .corpus = &prefab_xml_corpus });
}

fn fuzzPrefabsXml(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    var storage: [4096]u8 = undefined;
    const len: usize = smith.slice(&storage);
    // No prefabs_data_dir: skip .tts size probes (I/O) in the fuzz loop.
    var idx = prefabs.parseXml(std.testing.allocator, storage[0..len], null) catch return;
    defer idx.deinit();
    try std.testing.expect(idx.items.len <= len);
    if (idx.items.len > 0) {
        var heights: [256]u8 = .{64} ** 256;
        idx.applyToChunkHeights(0, 0, &heights);
    }
}

// Minimal valid tiny .tts: magic, ver=5, size 1x1x1, one air block raw=0.
const tts_min = [_]u8{
    't', 't', 's', 0,
    5, 0, 0, 0, // version
    1, 0, // sx
    1, 0, // sy
    1, 0, // sz
    0, 0, 0, 0, // block raw
};

const tts_corpus = [_][]const u8{
    "",
    "tts\x00",
    &tts_min,
    // version too old
    &([_]u8{ 't', 't', 's', 0, 4, 0, 0, 0, 1, 0, 1, 0, 1, 0 }),
    // bad size zeros
    &([_]u8{ 't', 't', 's', 0, 5, 0, 0, 0, 0, 0, 0, 0, 0, 0 }),
    // claimed huge volume (harness skips full parse)
    &([_]u8{ 't', 't', 's', 0, 5, 0, 0, 0, 0xff, 0x7f, 0xff, 0x7f, 0xff, 0x7f }),
    // short after header
    &([_]u8{ 't', 't', 's', 0, 5, 0, 0, 0, 2, 0, 2, 0, 2, 0, 0, 0 }),
};

test "fuzz .tts block parser" {
    try std.testing.fuzz({}, fuzzTtsBlocks, .{ .corpus = &tts_corpus });
}

fn fuzzTtsBlocks(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    var storage: [8192]u8 = undefined;
    const len: usize = smith.slice(&storage);
    const input = storage[0..len];
    // Reject pathological volumes before allocating (count is sx*sy*sz).
    if (input.len >= 14 and std.mem.eql(u8, input[0..4], "tts\x00")) {
        const sx: i32 = std.mem.readInt(i16, input[8..10], .little);
        const sy: i32 = std.mem.readInt(i16, input[10..12], .little);
        const sz: i32 = std.mem.readInt(i16, input[12..14], .little);
        if (sx > 0 and sy > 0 and sz > 0) {
            const vol = @as(i64, sx) * @as(i64, sy) * @as(i64, sz);
            if (vol > 32 * 32 * 32) return;
        }
    }
    var blocks = tts.parseBlocks(std.testing.allocator, input) catch return;
    defer blocks.deinit();
    try std.testing.expect(blocks.types.len == blocks.blockCount());
    try std.testing.expect(blocks.density.len == 0 or blocks.density.len == blocks.types.len);
}

const zch_corpus = [_][]const u8{
    "",
    "ZCH3",
    // ZCH3 header pos(0,0), no planes, no heights (torn)
    &([_]u8{ 'Z', 'C', 'H', '3', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }),
    // ZCH3 heights-only for (0,0)
    &([_]u8{ 'Z', 'C', 'H', '3', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } ++ ([_]u8{64} ** 256)),
    // ZCH1 heights for (1,-1)
    &([_]u8{ 'Z', 'C', 'H', '1', 1, 0, 0, 0, 0xff, 0xff, 0xff, 0xff } ++ ([_]u8{50} ** 256)),
    // ZCH3 with blocks flag but truncated plane
    &([_]u8{ 'Z', 'C', 'H', '3', 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0 } ++ ([_]u8{0} ** 256)),
    // bad flag bytes
    &([_]u8{ 'Z', 'C', 'H', '3', 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0 } ++ ([_]u8{0} ** 256)),
    // wrong magic
    &([_]u8{ 'Z', 'C', 'H', '4', 0, 0, 0, 0, 0, 0, 0, 0 }),
};

test "fuzz ZCH chunk validator" {
    try std.testing.fuzz({}, fuzzZchValidate, .{ .corpus = &zch_corpus });
}

fn fuzzZchValidate(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    var storage: [8192]u8 = undefined;
    const len: usize = smith.slice(&storage);
    const pos: store.ChunkPos = .{
        .x = smith.value(i32),
        .z = smith.value(i32),
    };
    // Also try matching pos from header when present so valid seeds pass.
    const input = storage[0..len];
    _ = store.World.validateChunkBytes(input, pos) catch {};
    if (input.len >= 12 and input[0] == 'Z' and input[1] == 'C' and input[2] == 'H') {
        const hx = std.mem.readInt(i32, input[4..8], .little);
        const hz = std.mem.readInt(i32, input[8..12], .little);
        _ = store.World.validateChunkBytes(input, .{ .x = hx, .z = hz }) catch {};
    }
}

/// Terrain the A* fuzz target searches: a deterministic pseudo-random height
/// field with blocked columns, driven entirely by the fuzzer's seed bytes.
const FuzzTerrain = struct {
    seed: u32,
    blocked_mod: u32,

    fn hash(self: *const FuzzTerrain, x: i32, z: i32) u32 {
        const ux: u32 = @bitCast(x);
        const uz: u32 = @bitCast(z);
        return (ux *% 0x9e3779b1) ^ (uz *% 0x85ebca77) ^ (self.seed *% 0xc2b2ae35);
    }

    fn heightAt(self: *const FuzzTerrain, x: i32, z: i32) i32 {
        return 60 + @as(i32, @intCast((self.hash(x, z) >> 8) % 5));
    }

    fn step(ctx: ?*anyopaque, _: i32, _: i32, from_y: i32, tx: i32, tz: i32) ?i32 {
        const self: *const FuzzTerrain = @ptrCast(@alignCast(ctx.?));
        if (self.blocked_mod != 0 and self.hash(tx, tz) % self.blocked_mod == 0) return null;
        const h = self.heightAt(tx, tz);
        if (h > from_y + store.max_step_up or h < from_y - store.max_drop) return null;
        return h;
    }
};

test "fuzz grid A* invariants" {
    try std.testing.fuzz({}, fuzzAStar, .{});
}

fn fuzzAStar(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    var terrain: FuzzTerrain = .{
        .seed = smith.value(u32),
        // 0 = fully open; small values make most of the grid impassable.
        .blocked_mod = smith.value(u32) % 8,
    };
    // Bounded coordinates: the search span is derived from the start/goal
    // distance, and i32 extremes would only exercise overflow, not pathing.
    const sx: i32 = @rem(@as(i32, smith.value(i16)), 64);
    const sz: i32 = @rem(@as(i32, smith.value(i16)), 64);
    const gx: i32 = @rem(@as(i32, smith.value(i16)), 64);
    const gz: i32 = @rem(@as(i32, smith.value(i16)), 64);
    const budget: usize = smith.value(u8);
    const sy = terrain.heightAt(sx, sz);

    var p: path_mod.Path = .{};
    const expanded = path_mod.aStarToward(&p, sx, sz, sy, gx, gz, budget, &terrain, FuzzTerrain.step);
    try std.testing.expect(expanded <= budget);
    try std.testing.expect(p.len <= path_mod.max_path);

    // Every returned cell must be one grid step from the previous one, and must
    // be a move the predicate actually allowed from that predecessor.
    var px = sx;
    var pz = sz;
    var py = sy;
    for (p.points[0..p.len]) |pt| {
        const d = @abs(pt.x - px) + @abs(pt.z - pz);
        try std.testing.expectEqual(@as(u32, 1), d);
        const allowed = FuzzTerrain.step(&terrain, px, pz, py, pt.x, pt.z) orelse
            return error.PathCrossesBlockedCell;
        try std.testing.expectEqual(allowed, pt.y);
        px = pt.x;
        pz = pt.z;
        py = pt.y;
    }

    // Same inputs, same path: the sim runs A* on parallel workers and must not
    // depend on anything but its arguments.
    var q: path_mod.Path = .{};
    const again = path_mod.aStarToward(&q, sx, sz, sy, gx, gz, budget, &terrain, FuzzTerrain.step);
    try std.testing.expectEqual(expanded, again);
    try std.testing.expectEqualSlices(path_mod.Point, p.points[0..p.len], q.points[0..q.len]);
}

test "fuzz gamestages.xml parser" {
    try std.testing.fuzz({}, fuzzGameStages, .{ .corpus = &gamestages_xml_corpus });
}

fn fuzzGameStages(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    var storage: [8192]u8 = undefined;
    const len: usize = smith.slice(&storage);
    var t = gamestages_xml.loadFromSlice(std.testing.allocator, storage[0..len]) catch return;
    defer t.deinit();
    const probe = smith.value(i32);
    // Ladders must stay sorted and carry at least one spawn, else the sleeper
    // and director lookups would pick a stage stock would never pick.
    for (t.spawners) |s| {
        var prev: i32 = std.math.minInt(i32);
        for (s.stages) |st| {
            try std.testing.expect(st.stage_num >= prev);
            try std.testing.expect(st.spawns.len > 0);
            prev = st.stage_num;
        }
        if (s.getStage(probe)) |st| try std.testing.expect(st.stage_num <= probe);
    }
    var scratch = [_]i32{ probe, smith.value(i32), smith.value(i32) };
    _ = gamestages_xml.partyLevel(t.config, &scratch);
    _ = gamestages_xml.playerStage(t.config, .{ .level = smith.value(u16), .days_alive = smith.value(u16) });
    var name_buf: [gamestages_xml.max_name_len]u8 = undefined;
    _ = gamestages_xml.cleanName(&name_buf, storage[0..@min(len, gamestages_xml.max_name_len)]);
}

const gamestages_xml_corpus = [_][]const u8{
    "",
    "<gamestages/>",
    \\<gamestages>
    \\  <config difficultyBonus="1.2" startingWeight="1" diminishingReturns="0.5"/>
    \\  <group name="1GroupGenericZombie" spawner="SleeperGSList"/>
    \\  <spawner name="SleeperGSList">
    \\    <gamestage stage="1"><spawn group="ZombiesAll" num="300" maxAlive="8"/></gamestage>
    \\    <gamestage stage="14"><spawn group="ZombiesNight"/></gamestage>
    \\  </spawner>
    \\</gamestages>
    ,
    // unclosed spawner / gamestage
    "<gamestages><spawner name=\"a\"><gamestage stage=\"1\">",
    // stage numbers that do not parse, negative, and overflowing
    "<spawner name=\"a\"><gamestage stage=\"-5\"><spawn group=\"g\"/></gamestage>" ++
        "<gamestage stage=\"99999999999999\"><spawn group=\"g\"/></gamestage></spawner>",
    // thousands separators and absurd counts
    "<spawner name=\"a\"><gamestage stage=\"1\"><spawn group=\"g\" num=\"65,535\" maxAlive=\"9999999\"/></gamestage></spawner>",
    // group rows missing one half of the pair
    "<group name=\"x\"/><group spawner=\"y\"/><group name=\"\" spawner=\"z\"/>",
    // spawn with empty group name, self-closing spawner
    "<spawner name=\"a\"/><spawner name=\"b\"><gamestage stage=\"1\"><spawn group=\"\"/></gamestage></spawner>",
    // comments and control bytes
    "<!-- c --><gamestages>\x00<config daysAliveChangeWhenKilled=\"nan\"/>\x01</gamestages>",
    // very long group name (exceeds max_name_len, must be rejected not truncated silently)
    "<group name=\"" ++ ("S_" ** 200) ++ "\" spawner=\"s\"/>",
};
const buff_corpus = [_][]const u8{
    "",
    // entityId only
    &.{ 171, 0, 0, 0 },
    // entityId | "buffShocked" | -1.0f | adding | instigator -1 | Vector3i 0
    &.{
        171,  0,   0,    0,    11,  'b',  'u',  'f',
        'f',  'S', 'h',  'o',  'c', 'k',  'e',  'd',
        0,    0,   0x80, 0xbf, 1,   0xff, 0xff, 0xff,
        0xff, 0,   0,    0,    0,   0,    0,    0,
        0,    0,   0,    0,    0,
    },
    // huge 7-bit name length with no payload
    &.{ 0, 0, 0, 0, 0xff, 0xff, 0xff, 0xff, 0x0f },
    // NaN duration, adding byte outside {0,1}
    &.{ 0, 0, 0, 0, 0, 0xff, 0xff, 0xc0, 0x7f, 0x42, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
};

test "fuzz AddRemoveBuff body decoder" {
    try std.testing.fuzz({}, fuzzAddRemoveBuff, .{ .corpus = &buff_corpus });
}

fn fuzzAddRemoveBuff(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    var storage: [4096]u8 = undefined;
    const len: usize = smith.slice(&storage);
    const input = storage[0..len];

    var name_buf: [stock_buff.max_buff_name]u8 = undefined;
    if (stock_buff.parseAddRemoveBuff(input, &name_buf)) |v| {
        // The name must fit the caller's buffer and have come out of the body.
        try std.testing.expect(v.name.len <= name_buf.len);
        try std.testing.expect(v.name.len + 25 <= input.len);
    } else |_| {}
}

const loot_corpus = [_][]const u8{
    "",
    "<lootcontainer name=\"c\"><item name=\"x\"/></lootcontainer>",
    // Full-domain count ranges: the u16 span arithmetic in the roll path would
    // overflow on count="0,65535" (cmax-cmin+1 = 65536), so roll must not trap.
    "<lootcontainer name=\"c\"><item name=\"x\" count=\"0,65535\"/></lootcontainer>",
    "<lootgroup name=\"g\" count=\"0,255\"><item name=\"x\" count=\"0,65535\"/></lootgroup>",
    // Non-finite prob must fail closed at the gate: NaN fails both comparisons
    // and the NaN→int conversion in the gate is undefined behaviour.
    "<lootcontainer name=\"c\"><item name=\"a\"/><item name=\"x\" prob=\"nan\"/></lootcontainer>",
    "<lootprobtemplate name=\"t\"><loot level=\"0,99\" prob=\"inf\"/></lootprobtemplate>" ++
        "<lootcontainer name=\"c\"><item name=\"x\" loot_prob_template=\"t\"/></lootcontainer>",
    // Self-referential group: recursion depth must bound it, not blow the stack.
    "<lootgroup name=\"g\" count=\"2,2\"><item group=\"g\"/></lootgroup>",
    // Zero size / zero counts / negative prob
    "<lootcontainer name=\"c\" size=\"0,0\"><item name=\"a\" count=\"0,0\" prob=\"-1\"/></lootcontainer>",
    "<loot_settings poi_tier_mod=\"" ++ ("1.5," ** 12),
    // Truncations and junk
    "<lootcontainer name=\"c\"><item name=\"x\" count=\"",
    "<lootgroup",
    "<lootcontainer name=\"c\"><item name=\"x\" count=\"999999,999999999\"/></lootcontainer>",
};

test "fuzz loot.xml parser and roll path" {
    try std.testing.fuzz({}, fuzzLootXml, .{ .corpus = &loot_corpus });
}

fn fuzzLootXml(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    var storage: [8192]u8 = undefined;
    const len: usize = smith.slice(&storage);
    var t = loot.loadFromSlice(std.testing.allocator, storage[0..len]) catch return;
    defer t.deinit();

    // Fixed-array parsers must never report more entries than they hold.
    try std.testing.expect(t.groups.len <= loot.max_groups);
    try std.testing.expect(t.containers.len <= loot.max_containers);
    for (t.groups) |g| try std.testing.expect(g.entry_n <= loot.max_entries);
    for (t.containers) |c| try std.testing.expect(c.entry_n <= loot.max_entries);

    // Roll the first few containers at hostile stages/seeds: count span
    // arithmetic and the prob gate must never trap, and every stack keeps a
    // positive count that fits u16.
    const n_rolls = @min(t.containers.len, 4);
    var stacks: [loot.max_roll_stacks]loot.Stack = undefined;
    var ci: usize = 0;
    while (ci < n_rolls) : (ci += 1) {
        const n = t.rollContainer(t.containers[ci].name, smith.value(i32), smith.value(u32), &stacks);
        try std.testing.expect(n <= stacks.len);
        for (stacks[0..n]) |st| {
            try std.testing.expect(st.count >= 1);
            try std.testing.expect(st.count <= 65535);
        }
    }
}
