//! Drone companion state machine (stock `EntityDrone`, 9 states).
//!
//! Grounded in `../../7dtd-engine-research/docs/entities/raycast-pathing.md`
//! section 6b: the state enum, the `SetState` single-mutator rule and the
//! transition diagram. This is the machine and its transition table only;
//! steering, pathing and persistence are separate concerns.
//!
//! Non-goals: `EntityDrone.SteeringMan` / `EntitySteering`, the raycast
//! pathfinders, and `NetPackageDroneDataSync` (all owned by other docs).

const std = @import("std");

/// `EntityDrone.State` (`raycast-pathing.md` 6b). `None` is the unset
/// sentinel, not a state the machine enters.
pub const State = enum(u8) {
    idle = 0,
    sentry = 1,
    follow = 2,
    heal = 3,
    attack = 4,
    shutdown = 5,
    /// Collision-free reposition.
    noclip = 6,
    /// Recovery hop when travel fails (`teleportState`).
    teleport = 7,
    /// Unset sentinel.
    none = 8,
};

/// The transition table from `raycast-pathing.md` 6b's diagram. A transition
/// the table does not list is refused: `SetState` is the single mutator and
/// the machine never invents an edge.
pub fn canTransition(from: State, to: State) bool {
    return switch (from) {
        .idle => to == .follow or to == .sentry or to == .heal or to == .noclip or to == .shutdown or to == .attack,
        .sentry => to == .follow or to == .attack or to == .shutdown,
        .follow => to == .idle or to == .attack or to == .teleport or to == .shutdown,
        .heal => to == .idle,
        .attack => to == .follow,
        .teleport => to == .idle,
        .noclip => to == .idle,
        .shutdown => to == .idle,
        // `None` is the unset sentinel; the machine starts at `Idle`.
        .none => to == .idle,
    };
}

/// The machine: state plus the time in it (`updateState` runs on a 0.05 s
/// cadence and advances `stateTime`).
pub const DroneState = struct {
    state: State = .idle,
    state_time: f32 = 0,

    /// `SetState(State next, bool sync)` is the single mutator. Returns false
    /// when the transition is not in the table, leaving the state unchanged.
    pub fn setState(self: *DroneState, next: State) bool {
        if (!canTransition(self.state, next)) return false;
        self.state = next;
        self.state_time = 0;
        return true;
    }

    /// `updateState` cadence: advance `stateTime` by one 0.05 s step.
    pub fn tick(self: *DroneState, dt: f32) void {
        self.state_time += dt;
    }
};

test "the drone machine follows the 9-state transition table" {
    var d = DroneState{};
    try std.testing.expectEqual(State.idle, d.state);
    // The table's edges.
    try std.testing.expect(d.setState(.follow));
    try std.testing.expect(d.setState(.attack));
    try std.testing.expect(d.setState(.follow));
    try std.testing.expect(d.setState(.teleport));
    try std.testing.expect(d.setState(.idle));
    try std.testing.expect(d.setState(.noclip));
    try std.testing.expect(d.setState(.idle));
    try std.testing.expect(d.setState(.sentry));
    try std.testing.expect(d.setState(.shutdown));
    try std.testing.expect(d.setState(.idle));
    try std.testing.expect(d.setState(.heal));
    try std.testing.expect(d.setState(.idle));
    // Idle to attack is stock: a drone at rest engages an enemy in range.
    // An edge the table does not list is still refused.
    try std.testing.expect(d.setState(.attack));
    try std.testing.expect(d.setState(.follow));
    try std.testing.expect(d.setState(.idle));
    try std.testing.expect(!d.setState(.teleport));
    try std.testing.expectEqual(State.idle, d.state);
    // `setState` resets the state clock.
    d.tick(0.05);
    try std.testing.expect(d.setState(.follow));
    try std.testing.expectEqual(@as(f32, 0), d.state_time);
}
