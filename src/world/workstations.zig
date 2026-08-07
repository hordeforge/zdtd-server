//! World-position keyed workstation state (forge/campfire/workbench TE 12).
//! Slots mirror TileEntityWorkstation arrays; craft tick advances the queue.
//!
//! Domain types (`QueueItem`, `CraftComplete`, slot/queue caps) live here so
//! `wire/stock_te` can import them without a world → wire cycle. Wire imports
//! these types only.

const std = @import("std");
const components = @import("../ecs/components.zig");

/// Game embeds WorkstationStore on the heap; 256 covers a long-lived base.
pub const max_workstations: usize = 256;
/// Widest stock workstation array we accept. The ctor sizes are fuel 3, tools 3,
/// output 6, input 3, lastInput 3 (asm.il ~1330158) and OnSetLocalChunkPosition
/// grows input to 3 + InputMaterials for a forge (asm.il ~1330219).
pub const max_ws_slots: usize = 12;
/// Stock RecipeQueueItem array cap on a workstation TE.
pub const max_ws_queue: usize = 4;
/// currentMeltTimesLeft is allocated once in the ctor at input.Length and never
/// regrown, so it can never exceed the widest input array we accept.
pub const max_ws_melt: usize = max_ws_slots;
/// Verbatim Recipe.Write bytes kept per queue slot so the S2C echo can re-emit
/// them. 320 covers a recipe with ten ingredients plus the craftingArea string.
pub const recipe_blob_max: usize = 320;
/// lastInput is server-opaque: it rides through as the ItemStack bytes the client
/// sent. 384 covers the widest array we accept (a non-empty stack is 22 bytes).
pub const last_input_blob_max: usize = 384;
/// Craft-complete records held per station between client acknowledgements.
pub const max_craft_complete: usize = 4;
/// Stock item / recipe names are well under this; longer ones are truncated.
pub const craft_name_max: usize = 64;
pub const slots_per_group: usize = max_ws_slots;

/// Stock TileEntityWorkstation ctor array lengths (asm.il ~1330158). These are
/// the counts the client expects back: both `readItemStackArray` and
/// `readRecipeStackArray` reallocate their target array to the received count
/// before the discard gate, so a short count shrinks the client's grid.
pub const stock_fuel_len: u8 = 3;
pub const stock_input_len: u8 = 3;
pub const stock_tools_len: u8 = 3;
pub const stock_output_len: u8 = 6;
pub const stock_last_input_len: u8 = 3;
pub const stock_queue_len: u8 = 4;
pub const stock_melt_len: u8 = 3;

/// One client write must not be able to burst a whole queue into the output.
const max_crafts_per_tick: usize = 64;
/// Largest craft backlog a client-supplied CraftingTimeLeft may carry (seconds).
const max_craft_backlog: f32 = 60;

/// Recipe queue cell shared by sim state and TE wire (stock RecipeQueueItem fields).
pub const QueueItem = struct {
    multiplier: i16 = 0,
    is_crafting: bool = false,
    craft_time_left: f32 = 0,
    one_item_craft_time: f32 = 0,
    quality: u8 = 0,
    /// RecipeQueueItem.StartingEntityId: whom the craft-complete XP belongs to.
    starting_entity_id: i32 = -1,
    /// Recipe output ItemValue.type (absolute); 0 = no recipe.
    output_type: i32 = 0,
    output_count: i32 = 0,
    crafting_time: f32 = 0,
    craft_exp_gain: i32 = 0,
    /// Recipe.Write bytes exactly as the client sent them. A peer that never
    /// queued this recipe has a null Recipe object, and `RecipeQueueItem::Read`
    /// leaves it null when hasRecipe is false (asm.il ~272880 IL_0084), which
    /// `HandleRecipeQueue` then dereferences (asm.il ~1331756 IL_006c).
    recipe: [recipe_blob_max]u8 = [_]u8{0} ** recipe_blob_max,
    recipe_len: u16 = 0,

    pub fn recipeBlob(self: *const QueueItem) []const u8 {
        return self.recipe[0..self.recipe_len];
    }

    /// Stores the blob when it fits. On overflow the slot keeps `recipe_len` 0
    /// and the echo writes hasRecipe = false, which is lossless for the sender
    /// (its own Recipe object is untouched) and only costs third-party peers
    /// the recipe name in the queue UI.
    pub fn setRecipeBlob(self: *QueueItem, blob: []const u8) void {
        if (blob.len > self.recipe.len) {
            self.recipe_len = 0;
            return;
        }
        @memcpy(self.recipe[0..blob.len], blob);
        self.recipe_len = @intCast(blob.len);
    }

    pub fn hasRecipe(self: *const QueueItem) bool {
        return self.output_type != 0 or self.recipe_len != 0;
    }

    /// Stock `cycleRecipeQueue` copies the mutable fields and leaves a fresh
    /// entry behind (asm.il ~1331557 IL_0093-IL_0139).
    fn clear(self: *QueueItem) void {
        self.* = .{};
    }
};

/// Stock CraftCompleteData: one finished craft awaiting the crafter's client.
/// `item_type` is the absolute stock ItemValue.type of what was crafted.
pub const CraftComplete = struct {
    crafter_entity_id: i32 = 0,
    item_type: i32 = 0,
    item_count: u16 = 0,
    exp_gain: i32 = 0,
    /// `EntityPlayerLocal::GiveExp` divides by (craftCount + RecipeUsedCount)
    /// (asm.il ~528534), so this must never reach the wire as 0.
    used_count: u16 = 1,
    recipe_name: [craft_name_max]u8 = [_]u8{0} ** craft_name_max,
    recipe_name_len: u8 = 0,
    scrapped: [craft_name_max]u8 = [_]u8{0} ** craft_name_max,
    scrapped_len: u8 = 0,

    pub fn recipeName(self: *const CraftComplete) []const u8 {
        return self.recipe_name[0..self.recipe_name_len];
    }

    pub fn scrappedName(self: *const CraftComplete) []const u8 {
        return self.scrapped[0..self.scrapped_len];
    }

    pub fn setRecipeName(self: *CraftComplete, name: []const u8) void {
        const n = @min(name.len, self.recipe_name.len);
        @memcpy(self.recipe_name[0..n], name[0..n]);
        self.recipe_name_len = @intCast(n);
    }

    pub fn setScrappedName(self: *CraftComplete, name: []const u8) void {
        const n = @min(name.len, self.scrapped.len);
        @memcpy(self.scrapped[0..n], name[0..n]);
        self.scrapped_len = @intCast(n);
    }
};

/// Stock output type resolved to sim state plus the name the client derives from
/// `Recipe::GetName()` (asm.il ~274245: the output ItemClass name).
pub const ResolvedOutput = struct {
    item_id: u16 = 0,
    stock_name: []const u8 = "",
};

/// Game supplies the items-table reverse lookup; null in unit tests → the craft
/// still advances but nothing is materialized.
pub const OutputResolver = *const fn (ctx: ?*anyopaque, stock_type: i32) ResolvedOutput;

pub const Workstation = struct {
    x: i32 = 0,
    y: i32 = 0,
    z: i32 = 0,
    /// BlockValue.type the client last reported. `NetPackageTileEntity::ProcessPackage`
    /// drops the whole package when it disagrees with the world block (asm.il ~842882).
    block_id: i32 = 0,
    fuel: [slots_per_group]components.InvSlot = [_]components.InvSlot{.{}} ** slots_per_group,
    input: [slots_per_group]components.InvSlot = [_]components.InvSlot{.{}} ** slots_per_group,
    tools: [slots_per_group]components.InvSlot = [_]components.InvSlot{.{}} ** slots_per_group,
    output: [slots_per_group]components.InvSlot = [_]components.InvSlot{.{}} ** slots_per_group,
    /// lastInput is display-only on the client (melt timer reset) and the server
    /// never reads it, so it rides through as the exact ItemStack bytes received.
    last_input: [last_input_blob_max]u8 = [_]u8{0} ** last_input_blob_max,
    last_input_blob_len: u16 = 0,
    queue: [max_ws_queue]QueueItem = [_]QueueItem{.{}} ** max_ws_queue,
    craft_complete: [max_craft_complete]CraftComplete = [_]CraftComplete{.{}} ** max_craft_complete,
    craft_complete_n: u8 = 0,
    melt: [max_ws_melt]f32 = [_]f32{0} ** max_ws_melt,
    /// On-wire array lengths, not used prefixes. Defaults are the stock ctor sizes.
    fuel_len: u8 = stock_fuel_len,
    input_len: u8 = stock_input_len,
    tools_len: u8 = stock_tools_len,
    output_len: u8 = stock_output_len,
    last_input_len: u8 = stock_last_input_len,
    queue_len: u8 = stock_queue_len,
    melt_len: u8 = stock_melt_len,
    is_burning: bool = false,
    burn_time_left: f32 = 0,
    is_player_placed: bool = true,
    /// Set once a client write has told us this station's real geometry. Echoing
    /// guessed array lengths would resize the client's grids, so nothing is sent
    /// before that.
    geometry_known: bool = false,
    /// Set when tick changes state; Game re-broadcasts then clears.
    dirty: bool = false,

    /// Advance burn + craft; completed crafts land in output[] when the
    /// resolver maps the recipe's stock output type to a sim item.
    pub fn tick(self: *Workstation, dt: f32) void {
        self.tickResolved(dt, null, null);
    }

    pub fn tickResolved(self: *Workstation, dt: f32, resolve: ?OutputResolver, ctx: ?*anyopaque) void {
        if (dt <= 0) return;
        self.handleFuel(dt);
        self.handleRecipeQueue(dt, resolve, ctx);
    }

    /// Stock `HandleFuel` (asm.il ~1331911): burn down, then consume one fuel item.
    fn handleFuel(self: *Workstation, dt: f32) void {
        // Timers arrive from the client TE write, so they can be non-finite or far
        // negative; the catch-up loop below only terminates promptly when a timer
        // starts within one period of zero.
        if (!std.math.isFinite(self.burn_time_left) or self.burn_time_left < 0) self.burn_time_left = 0;
        if (!self.is_burning) return;
        self.burn_time_left -= dt;
        while (self.burn_time_left <= 0) {
            // consume one fuel item = 10s burn (ponytail: flat rate; per-item
            // fuel values from items.xml when the loader grows them)
            if (takeOne(self.fuel[0..self.fuel_len])) {
                self.burn_time_left += 10.0;
            } else {
                self.is_burning = false;
                self.burn_time_left = 0;
                self.dirty = true;
                break; // burn_time_left == 0 still satisfies the loop guard
            }
        }
    }

    /// Stock `HandleRecipeQueue` (asm.il ~1331686): the active entry is the last
    /// slot, a full output array stalls the craft, and each finished item records
    /// a CraftCompleteData before the multiplier drops.
    fn handleRecipeQueue(self: *Workstation, dt: f32, resolve: ?OutputResolver, ctx: ?*anyopaque) void {
        if (self.queue_len == 0) return;
        if (!self.is_burning) return;
        const last: usize = self.queue_len - 1;
        var active = &self.queue[last];
        // A client-written CraftingTimeLeft of -inf (or a huge backlog) would let
        // one packet drain the whole multiplier in a single tick.
        if (!std.math.isFinite(active.craft_time_left) or active.craft_time_left < -max_craft_backlog) {
            active.craft_time_left = 0;
        }
        if (!std.math.isFinite(active.one_item_craft_time) or active.one_item_craft_time < 0) {
            active.one_item_craft_time = 0;
        }
        if (active.craft_time_left >= 0) active.craft_time_left -= dt;
        var steps: usize = 0;
        while (active.craft_time_left < 0 and self.hasRecipeInQueue()) {
            // Stock has no step bound here: OneItemCraftTime 0 with a large
            // Multiplier would otherwise craft the whole entry in one tick.
            if (steps >= max_crafts_per_tick) break;
            steps += 1;
            if (active.multiplier > 0) {
                if (!self.completeOneCraft(active, resolve, ctx)) return; // output full → stall
                active.multiplier -= 1;
                active.craft_time_left += active.one_item_craft_time;
                self.dirty = true;
            }
            if (active.multiplier > 0) continue;
            const carry = active.craft_time_left;
            self.cycleRecipeQueue();
            active = &self.queue[last];
            active.craft_time_left += if (carry < 0) carry else 0;
            self.dirty = true;
        }
    }

    /// Materialize one crafted item and record the CraftCompleteData. Returns
    /// false when the output array has no room (stock's AddToItemStackArray == -1).
    fn completeOneCraft(
        self: *Workstation,
        q: *const QueueItem,
        resolve: ?OutputResolver,
        ctx: ?*anyopaque,
    ) bool {
        if (q.output_type == 0 or q.output_count <= 0) return true;
        const count: u16 = @intCast(@min(q.output_count, std.math.maxInt(u16)));
        const res: ResolvedOutput = if (resolve) |rv| rv(ctx, q.output_type) else .{};
        if (res.item_id != 0 and !addOutput(self.output[0..self.output_len], res.item_id, count)) return false;
        self.addCraftComplete(q, res.stock_name, count);
        return true;
    }

    /// Stock `AddCraftComplete` (asm.il ~1333793): merge into the entry for the
    /// same crafted item, else append. A full list drops the oldest entry so a
    /// client that never acknowledges cannot pin new crafts out of the record.
    fn addCraftComplete(self: *Workstation, q: *const QueueItem, name: []const u8, count: u16) void {
        for (self.craft_complete[0..self.craft_complete_n]) |*cc| {
            if (cc.item_type != q.output_type) continue;
            if (cc.scrapped_len != 0) continue;
            cc.item_count +|= count;
            return;
        }
        if (self.craft_complete_n == self.craft_complete.len) {
            std.mem.copyForwards(
                CraftComplete,
                self.craft_complete[0 .. self.craft_complete.len - 1],
                self.craft_complete[1..],
            );
            self.craft_complete_n -= 1;
        }
        var cc: CraftComplete = .{
            .crafter_entity_id = q.starting_entity_id,
            .item_type = q.output_type,
            .item_count = count,
            .exp_gain = q.craft_exp_gain,
            .used_count = 1,
        };
        cc.setRecipeName(name);
        self.craft_complete[self.craft_complete_n] = cc;
        self.craft_complete_n += 1;
    }

    /// Replace the record list with what the client acknowledged: entries its
    /// `CheckForCraftComplete` consumed come back removed (asm.il ~1333883).
    pub fn setCraftComplete(self: *Workstation, list: []const CraftComplete) void {
        const n = @min(list.len, self.craft_complete.len);
        @memcpy(self.craft_complete[0..n], list[0..n]);
        self.craft_complete_n = @intCast(n);
    }

    /// Stock `hasRecipeInQueue` (asm.il ~1332461).
    fn hasRecipeInQueue(self: *const Workstation) bool {
        for (self.queue[0..self.queue_len]) |q| {
            if (q.multiplier > 0 and q.hasRecipe()) return true;
        }
        return false;
    }

    /// Stock `cycleRecipeQueue` (asm.il ~1331491): shift every entry one slot
    /// toward the end (index 0 is newest, the last index is being crafted),
    /// clearing the vacated slot, then arm the new active entry.
    fn cycleRecipeQueue(self: *Workstation) void {
        if (self.queue_len == 0) return;
        const last: usize = self.queue_len - 1;
        if (self.queue[last].multiplier > 0) return;
        var pass: usize = 0;
        while (pass < self.queue_len) : (pass += 1) {
            if (self.queue[last].multiplier != 0) break;
            var j: usize = last;
            while (j > 0) : (j -= 1) {
                var src = self.queue[j - 1];
                if (src.multiplier < 0) src.multiplier = 0;
                self.queue[j] = src;
                self.queue[j - 1].clear();
            }
        }
        const active = &self.queue[last];
        if (active.hasRecipe() and !active.is_crafting and active.multiplier != 0) active.is_crafting = true;
    }

    /// Stock `ItemStack::AddToItemStackArray` (asm.il ~614393): merge into the
    /// first stackable slot, else take the first empty one, else fail. The u16
    /// room check is ours (stock counts are i32).
    fn addOutput(slots: []components.InvSlot, item_id: u16, count: u16) bool {
        for (slots) |*s| {
            if (s.item_id != item_id or s.count == 0) continue;
            if (std.math.maxInt(u16) - s.count < count) continue;
            s.count += count;
            return true;
        }
        for (slots) |*s| {
            if (s.count != 0) continue;
            s.* = .{ .item_id = item_id, .count = count };
            return true;
        }
        return false;
    }

    fn takeOne(slots: []components.InvSlot) bool {
        for (slots) |*s| {
            if (s.count > 0 and s.item_id != 0) {
                s.count -= 1;
                if (s.count == 0) s.* = .{};
                return true;
            }
        }
        return false;
    }
};

pub const WorkstationStore = struct {
    items: [max_workstations]Workstation = undefined,
    used: [max_workstations]bool = .{false} ** max_workstations,

    pub fn get(self: *WorkstationStore, x: i32, y: i32, z: i32) ?*Workstation {
        for (self.items[0..], self.used[0..]) |*w, u| {
            if (u and w.x == x and w.y == y and w.z == z) return w;
        }
        return null;
    }

    pub fn getOrCreate(self: *WorkstationStore, x: i32, y: i32, z: i32) ?*Workstation {
        if (self.get(x, y, z)) |w| return w;
        for (self.items[0..], self.used[0..], 0..) |*w, u, i| {
            if (u) continue;
            w.* = .{ .x = x, .y = y, .z = z };
            self.used[i] = true;
            return w;
        }
        return null;
    }

    pub fn tickAll(self: *WorkstationStore, dt: f32) void {
        self.tickAllResolved(dt, null, null);
    }

    pub fn tickAllResolved(self: *WorkstationStore, dt: f32, resolve: ?OutputResolver, ctx: ?*anyopaque) void {
        for (self.items[0..], self.used[0..]) |*w, u| {
            if (u) w.tickResolved(dt, resolve, ctx);
        }
    }
};

/// Test resolver: any stock type maps to sim item 9 named "outputItem".
fn testResolve(_: ?*anyopaque, _: i32) ResolvedOutput {
    return .{ .item_id = 9, .stock_name = "outputItem" };
}

/// A station with one queued recipe in the stock active slot (the last one).
fn testStation(multiplier: i16, one_item: f32) Workstation {
    var w: Workstation = .{ .is_burning = true, .burn_time_left = 100, .queue_len = stock_queue_len };
    w.queue[w.queue_len - 1] = .{
        .multiplier = multiplier,
        .is_crafting = true,
        .craft_time_left = one_item,
        .one_item_craft_time = one_item,
        .output_type = 70000,
        .output_count = 3,
        .craft_exp_gain = 12,
        .starting_entity_id = 171,
    };
    return w;
}

test "workstation crafts the last queue slot and empties it" {
    var w = testStation(2, 1.0);
    const last = w.queue_len - 1;
    w.tick(0.5);
    try std.testing.expectEqual(@as(i16, 2), w.queue[last].multiplier);
    w.tick(0.6); // crosses 0 → one crafted
    try std.testing.expectEqual(@as(i16, 1), w.queue[last].multiplier);
    w.tick(1.1); // second crafted, entry cycles out
    try std.testing.expectEqual(@as(i16, 0), w.queue[last].multiplier);
    try std.testing.expectEqual(@as(u8, stock_queue_len), w.queue_len);
    try std.testing.expect(w.dirty);
}

test "workstation store holds past the old 64 cap (GAP 12)" {
    var s: WorkstationStore = .{};
    var i: usize = 0;
    var created: usize = 0;
    while (i < 100) : (i += 1) {
        if (s.getOrCreate(@intCast(i), 70, @intCast(i * 2)) != null) created += 1;
    }
    try std.testing.expectEqual(@as(usize, 100), created);
}

test "workstation craft materializes output and records a craft complete" {
    var w = testStation(2, 0.4);
    w.tickResolved(0.5, testResolve, null); // first craft
    try std.testing.expectEqual(@as(u16, 9), w.output[0].item_id);
    try std.testing.expectEqual(@as(u16, 3), w.output[0].count);
    try std.testing.expectEqual(@as(u8, 1), w.craft_complete_n);
    try std.testing.expectEqual(@as(i32, 171), w.craft_complete[0].crafter_entity_id);
    try std.testing.expectEqual(@as(i32, 12), w.craft_complete[0].exp_gain);
    try std.testing.expectEqualStrings("outputItem", w.craft_complete[0].recipeName());
    w.tickResolved(0.5, testResolve, null); // second craft merges
    try std.testing.expectEqual(@as(u16, 6), w.output[0].count);
    try std.testing.expectEqual(@as(u8, 1), w.craft_complete_n);
    try std.testing.expectEqual(@as(u16, 6), w.craft_complete[0].item_count);
}

test "workstation stalls instead of dropping a craft when the output is full" {
    var w = testStation(3, 0.4);
    w.output_len = 1;
    w.output[0] = .{ .item_id = 8, .count = 5 }; // different item, no room to merge
    const last = w.queue_len - 1;
    w.tickResolved(0.5, testResolve, null);
    try std.testing.expectEqual(@as(i16, 3), w.queue[last].multiplier);
    try std.testing.expectEqual(@as(u8, 0), w.craft_complete_n);
    w.output[0] = .{}; // room again → the stalled craft lands
    w.tickResolved(0.1, testResolve, null);
    try std.testing.expectEqual(@as(i16, 2), w.queue[last].multiplier);
}

test "workstation cycle shifts entries toward the end and carries the overrun" {
    var w = testStation(1, 1.0);
    const last = w.queue_len - 1;
    w.queue[last - 1] = .{
        .multiplier = 2,
        .craft_time_left = 0,
        .one_item_craft_time = 4.0,
        .output_type = 70001,
        .output_count = 1,
    };
    w.tickResolved(2.5, testResolve, null); // finishes slot `last`, cycles
    try std.testing.expectEqual(@as(i32, 70001), w.queue[last].output_type);
    try std.testing.expect(w.queue[last].is_crafting);
    try std.testing.expectEqual(@as(i32, 0), w.queue[last - 1].output_type);
    // The 0.5s overrun carries into the new active entry, which is already due,
    // so it crafts once immediately and restarts at 4.0 - 0.5.
    try std.testing.expectEqual(@as(i16, 1), w.queue[last].multiplier);
    try std.testing.expectApproxEqAbs(@as(f32, 3.5), w.queue[last].craft_time_left, 0.01);
}

test "workstation burn consumes fuel then stops" {
    var w: Workstation = .{ .is_burning = true, .burn_time_left = 0.4 };
    w.fuel[0] = .{ .item_id = 7, .count = 1 };
    w.tick(0.5); // burn ends, consumes the one fuel → +10s
    try std.testing.expect(w.is_burning);
    try std.testing.expectEqual(@as(u16, 0), w.fuel[0].count);
    w.burn_time_left = 0.1;
    w.tick(0.2); // no fuel left → stops
    try std.testing.expect(!w.is_burning);
}

test "workstation catches up multiple crafts and fuel units after a delayed tick" {
    var w = testStation(3, 1.0);
    w.burn_time_left = 1;
    w.fuel[0] = .{ .item_id = 7, .count = 3 };
    const last = w.queue_len - 1;
    w.tick(21.5);
    try std.testing.expectEqual(@as(u16, 0), w.fuel[0].count);
    try std.testing.expectEqual(@as(i16, 0), w.queue[last].multiplier);
}

test "client-written timers cannot stall or burst the tick" {
    var w = testStation(32767, 0);
    w.burn_time_left = -1e9;
    w.queue[w.queue_len - 1].craft_time_left = -std.math.inf(f32);
    w.fuel[0] = .{ .item_id = 7, .count = 60000 };
    w.tick(0.05);
    try std.testing.expect(w.burn_time_left > 0);
    try std.testing.expectEqual(@as(u16, 59999), w.fuel[0].count);
    // Bounded per tick rather than draining the whole multiplier at once.
    const crafted = 32767 - w.queue[w.queue_len - 1].multiplier;
    try std.testing.expect(crafted <= @as(i16, @intCast(max_crafts_per_tick)));
}

test "craft complete list drains to what the client acknowledged" {
    var w = testStation(2, 0.4);
    w.tickResolved(0.5, testResolve, null);
    try std.testing.expectEqual(@as(u8, 1), w.craft_complete_n);
    w.setCraftComplete(&.{});
    try std.testing.expectEqual(@as(u8, 0), w.craft_complete_n);
}

test "craft complete list evicts the oldest instead of growing" {
    var w = testStation(0, 1.0);
    var q: QueueItem = .{ .output_count = 1, .craft_exp_gain = 1 };
    var i: i32 = 0;
    while (i < @as(i32, @intCast(max_craft_complete)) + 2) : (i += 1) {
        q.output_type = 70000 + i;
        w.addCraftComplete(&q, "n", 1);
    }
    try std.testing.expectEqual(@as(u8, @intCast(max_craft_complete)), w.craft_complete_n);
    try std.testing.expectEqual(@as(i32, 70002), w.craft_complete[0].item_type);
}

test "recipe blob over the cap degrades to no blob rather than truncating" {
    var q: QueueItem = .{};
    const big = [_]u8{7} ** (recipe_blob_max + 1);
    q.setRecipeBlob(big[0..]);
    try std.testing.expectEqual(@as(usize, 0), q.recipeBlob().len);
    q.setRecipeBlob(big[0..8]);
    try std.testing.expectEqual(@as(usize, 8), q.recipeBlob().len);
}
