//! Coverage-guided fuzz targets for remote wire parsing boundaries and
//! other untrusted-input surfaces (admin lines, map XML, COG headers,
//! config XML patches, quest catalogs, GSI text builders).

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
const serverinfo = @import("server/serverinfo_tcp.zig");
const xml_util = @import("assets/xml_util.zig");
const xml_patch = @import("assets/xml_patch.zig");
const quests_xml = @import("assets/quests.zig");
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
    // land claim repair: xyz + begin
    &.{ 0, 0, 0, 0, 61, 0, 0, 0, 0, 0, 0, 0, 1 },
    // chunk body: cx,cz,pad + 256 heights zeros
    &([_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } ++ ([_]u8{0} ** 256)),
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
