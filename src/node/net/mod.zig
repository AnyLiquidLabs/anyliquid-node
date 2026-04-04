const std = @import("std");
const shared = @import("../../shared/mod.zig");

pub const NetConfig = struct {
    fanout: usize = 8,
};

pub const PeerId = u64;

pub const ReceivedMsg = struct {
    from: PeerId,
    msg: P2pMsg,
};

pub const P2pMsg = union(enum) {
    tx: shared.types.Transaction,
    oracle_price: shared.types.Price,
    consensus: []const u8,
    block_req: struct { from_height: u64, to_height: u64 },
    block_resp: []const shared.types.Block,
};

pub const P2pNet = struct {
    allocator: std.mem.Allocator,
    cfg: NetConfig,

    pub fn init(cfg: NetConfig, allocator: std.mem.Allocator) !P2pNet {
        return .{
            .allocator = allocator,
            .cfg = cfg,
        };
    }

    pub fn deinit(self: *P2pNet) void {
        _ = self;
    }

    pub fn broadcast(self: *P2pNet, msg: P2pMsg) void {
        _ = self;
        _ = msg;
    }

    pub fn sendTo(self: *P2pNet, peer: PeerId, msg: P2pMsg) !void {
        _ = self;
        _ = peer;
        _ = msg;
    }

    pub fn recv(self: *P2pNet) []const ReceivedMsg {
        _ = self;
        return &.{};
    }

    pub fn connectedPeers(self: *P2pNet) []const PeerId {
        _ = self;
        return &.{};
    }

    pub fn syncBlocks(self: *P2pNet, from_height: u64, to_height: u64) ![]const shared.types.Block {
        _ = self;
        _ = from_height;
        _ = to_height;
        return &.{};
    }
};
