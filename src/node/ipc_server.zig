const std = @import("std");
const shared = @import("../shared/mod.zig");
const state_mod = @import("state.zig");
const mempool_mod = @import("mempool.zig");

pub const IpcConfig = struct {
    socket_path: []const u8 = "/tmp/anyliquid-node.sock",
};

pub const IpcServer = struct {
    cfg: IpcConfig,
    state: *state_mod.GlobalState,
    mempool: *mempool_mod.Mempool,

    pub fn init(cfg: IpcConfig, state: *state_mod.GlobalState, mempool: *mempool_mod.Mempool) !IpcServer {
        return .{
            .cfg = cfg,
            .state = state,
            .mempool = mempool,
        };
    }

    pub fn deinit(self: *IpcServer) void {
        _ = self;
    }

    pub fn tick(self: *IpcServer) void {
        _ = self;
    }

    pub fn broadcastEvents(self: *IpcServer, events: []const shared.protocol.NodeEvent) void {
        _ = self;
        _ = events;
    }
};
