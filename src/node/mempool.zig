const std = @import("std");
const shared = @import("../shared/mod.zig");

pub const MempoolError = error{
    DuplicateTx,
    MempoolFull,
    PersistenceFailed,
};

pub const Error = MempoolError || std.mem.Allocator.Error;

pub const MempoolConfig = struct {
    max_size: usize = 4096,
    persist_ctx: ?*anyopaque = null,
    persist_fn: ?*const fn (?*anyopaque, shared.types.Transaction) anyerror!void = null,
    confirm_ctx: ?*anyopaque = null,
    confirm_fn: ?*const fn (?*anyopaque, []const shared.types.Transaction) anyerror!void = null,
};

const TxKey = struct {
    user: shared.types.Address,
    nonce: u64,
};

pub const Mempool = struct {
    allocator: std.mem.Allocator,
    cfg: MempoolConfig,
    txs: std.ArrayList(shared.types.Transaction),
    keys: std.AutoHashMap(TxKey, void),

    pub fn init(cfg: MempoolConfig, allocator: std.mem.Allocator) Mempool {
        return .{
            .allocator = allocator,
            .cfg = cfg,
            .txs = .empty,
            .keys = std.AutoHashMap(TxKey, void).init(allocator),
        };
    }

    pub fn deinit(self: *Mempool) void {
        for (self.txs.items) |*tx| {
            shared.serialization.deinitTransaction(self.allocator, tx);
        }
        self.keys.deinit();
        self.txs.deinit(self.allocator);
    }

    pub fn add(self: *Mempool, tx: shared.types.Transaction) Error!void {
        if (self.txs.items.len >= self.cfg.max_size) {
            return MempoolError.MempoolFull;
        }

        const key = TxKey{ .user = tx.user, .nonce = tx.nonce };
        if (self.keys.contains(key)) {
            return MempoolError.DuplicateTx;
        }

        if (self.cfg.persist_fn) |persist_fn| {
            persist_fn(self.cfg.persist_ctx, tx) catch return MempoolError.PersistenceFailed;
        }

        var owned_tx = try shared.serialization.cloneTransaction(self.allocator, tx);
        errdefer shared.serialization.deinitTransaction(self.allocator, &owned_tx);

        try self.keys.put(key, {});
        try self.txs.append(self.allocator, owned_tx);
    }

    pub fn peek(self: *const Mempool, max_txs: usize) []const shared.types.Transaction {
        const end = @min(self.txs.items.len, max_txs);
        return self.txs.items[0..end];
    }

    pub fn removeConfirmed(self: *Mempool, txs: []const shared.types.Transaction) void {
        self.removeConfirmedPersisted(txs) catch {};
    }

    pub fn removeConfirmedPersisted(self: *Mempool, txs: []const shared.types.Transaction) anyerror!void {
        if (self.cfg.confirm_fn) |confirm_fn| {
            try confirm_fn(self.cfg.confirm_ctx, txs);
        }

        for (txs) |confirmed| {
            const key = TxKey{ .user = confirmed.user, .nonce = confirmed.nonce };
            _ = self.keys.remove(key);

            var idx: usize = 0;
            while (idx < self.txs.items.len) : (idx += 1) {
                const candidate = self.txs.items[idx];
                if (std.mem.eql(u8, &candidate.user, &confirmed.user) and candidate.nonce == confirmed.nonce) {
                    var removed = self.txs.swapRemove(idx);
                    shared.serialization.deinitTransaction(self.allocator, &removed);
                    break;
                }
            }
        }
    }

    pub fn size(self: *const Mempool) usize {
        return self.txs.items.len;
    }

    pub fn setPersistence(
        self: *Mempool,
        ctx: ?*anyopaque,
        persist_fn: ?*const fn (?*anyopaque, shared.types.Transaction) anyerror!void,
    ) void {
        self.cfg.persist_ctx = ctx;
        self.cfg.persist_fn = persist_fn;
    }

    pub fn setConfirmation(
        self: *Mempool,
        ctx: ?*anyopaque,
        confirm_fn: ?*const fn (?*anyopaque, []const shared.types.Transaction) anyerror!void,
    ) void {
        self.cfg.confirm_ctx = ctx;
        self.cfg.confirm_fn = confirm_fn;
    }
};

test "duplicate nonce for the same user is rejected" {
    var mempool = Mempool.init(.{}, std.testing.allocator);
    defer mempool.deinit();

    const tx = shared.types.Transaction{
        .action = .{ .withdraw = .{ .amount = 1, .destination = [_]u8{0} ** 20 } },
        .nonce = 1,
        .signature = .{ .r = [_]u8{0} ** 32, .s = [_]u8{0} ** 32, .v = 27 },
        .user = [_]u8{9} ** 20,
    };

    try mempool.add(tx);
    try std.testing.expectError(MempoolError.DuplicateTx, mempool.add(tx));
}
