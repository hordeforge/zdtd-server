//! Coverage-guided fuzz targets for remote wire parsing boundaries and
//! other untrusted-input surfaces (admin lines, map XML, COG headers).

const std = @import("std");
const packet = @import("litenet/packet.zig");
const frame = @import("wire/frame.zig");
const binary = @import("wire/binary.zig");
const packages = @import("wire/packages.zig");
const stock_te = @import("wire/stock_te.zig");
const stock_inv = @import("wire/stock_inv.zig");
const stock_quest = @import("wire/stock_quest.zig");
const admin = @import("server/admin.zig");
const zdtd_config = @import("server/zdtd_config.zig");
const xml_util = @import("assets/xml_util.zig");
const dtm = @import("world/dtm.zig");
const dem = @import("world/dem.zig");

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

const frame_corpus = [_][]const u8{
    "",
    &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    &.{ 0, 6, 0, 0, 0, 0, 0, 1, 0, 2, 0, 0, 0, 1, 0 },
    &.{ 0, 2, 0, 0, 0, 1, 0, 1, 0, 0x78, 0x9c },
    // claimed large package body truncated mid-stream
    &.{ 0, 0xff, 0xff, 0x00, 0x00, 0, 0, 1, 0 },
    // multi-package envelope with empty bodies
    &.{ 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0 },
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
    // chat: type | sender | 7bit-len "hi"
    &.{ 0, 106, 0, 0, 0, 2, 'h', 'i' },
    // lock: locking | channel | count=0
    &.{ 1, 0, 0, 0, 0, 0, 0 },
    // explosion head: 3xf32 + 3xi32 + 4xf32 + blob_len=0 + entity + delay
    &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    // npc quest list: trader entity + count 0
    &.{ 1, 0, 0, 0, 0, 0 },
    // quest objective update minimal
    &.{ 0, 0, 0, 0, 0 },
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
    var cmd_buf: [256]u8 = undefined;
    const cmd = packages.parseConsoleCmd(input, &cmd_buf);
    try std.testing.expect(cmd.len <= cmd_buf.len);
    _ = stock_te.parseStorageTeBody(input) catch null;
    _ = stock_te.parseWorkstationTeBody(input) catch null;
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
    var slots: [16]stock_inv.StockSlot = undefined;
    _ = stock_inv.readItemStackList(&r, &slots) catch null;
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
        try std.testing.expect(head.quest_id.len <= head.quest_id_storage.len);
        try std.testing.expect(@intFromEnum(head.event) <= 3);
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
    "[unclosed\n",
    "key_outside_section = 1\n",
    "[stream]\nmax_streamed_chunks = 999999999999999999999999\n",
    "[stream]\nmax_streamed_chunks = \"7\"\n",
    "[stream]\r\nstream_radius_min = -3\r\n",
    "[stream]\nchunk_adds_per_stream_tick = 1 # trailing comment\n",
    "[ authority ]\nmode=\n",
    "=\n[]\nx",
};

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
};

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
}
