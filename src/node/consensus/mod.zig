const std = @import("std");
const net_mod = @import("../net/mod.zig");
const mempool_mod = @import("../mempool.zig");
const store_mod = @import("../store/mod.zig");

pub const ConsensusConfig = struct {
    round_timeout_ms: u64 = 500,
};

pub const Consensus = struct {
    cfg: ConsensusConfig,
    net: *net_mod.P2pNet,
    mempool: *mempool_mod.Mempool,
    store: *store_mod.Store,
    current_round: u64 = 0,
    current_height: u64 = 0,

    pub fn init(
        cfg: ConsensusConfig,
        net: *net_mod.P2pNet,
        mempool: *mempool_mod.Mempool,
        store: *store_mod.Store,
    ) !Consensus {
        return .{
            .cfg = cfg,
            .net = net,
            .mempool = mempool,
            .store = store,
        };
    }

    pub fn deinit(self: *Consensus) void {
        _ = self;
    }

    pub fn tick(self: *Consensus, now_ms: i64) !?u64 {
        _ = now_ms;
        return self.current_height;
    }

    pub fn onMessage(self: *Consensus, msg: []const u8, from: net_mod.PeerId) !void {
        _ = self;
        _ = msg;
        _ = from;
    }

    pub fn isLeader(self: *const Consensus) bool {
        return self.current_round % 2 == 0;
    }

    pub fn currentRound(self: *const Consensus) u64 {
        return self.current_round;
    }

    pub fn currentHeight(self: *const Consensus) u64 {
        return self.current_height;
    }
};
