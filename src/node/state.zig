const shared = @import("../shared/mod.zig");

pub const GlobalState = struct {
    block_height: u64 = 0,
    state_root: [32]u8 = [_]u8{0} ** 32,
    timestamp: i64 = 0,

    pub fn init() GlobalState {
        return .{};
    }

    pub fn bumpBlock(self: *GlobalState) void {
        self.block_height += 1;
        self.timestamp += 1;
        self.state_root[0] +%= 1;
    }
};
