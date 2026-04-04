const std = @import("std");
const shared = @import("../shared/mod.zig");

pub const CacheError = error{
    NotFound,
};

pub const CacheConfig = struct {
    default_meta: ?shared.types.ExchangeMeta = null,
};

pub const CacheMetrics = struct {
    applied_events: u64 = 0,
    stale_events: u64 = 0,
};

pub const StateCache = struct {
    allocator: std.mem.Allocator,
    books: std.AutoHashMap(shared.types.AssetId, shared.types.L2Snapshot),
    accounts: std.AutoHashMap(shared.types.Address, shared.types.AccountState),
    api_wallet_owners: std.AutoHashMap(shared.types.Address, shared.types.Address),
    meta: shared.types.ExchangeMeta,
    all_mids: shared.types.AllMidsUpdate,
    metrics: CacheMetrics,

    pub fn init(cfg: CacheConfig, allocator: std.mem.Allocator) !StateCache {
        const meta = if (cfg.default_meta) |value|
            try shared.serialization.cloneExchangeMeta(allocator, value)
        else
            shared.types.ExchangeMeta{ .assets = &.{} };

        return .{
            .allocator = allocator,
            .books = std.AutoHashMap(shared.types.AssetId, shared.types.L2Snapshot).init(allocator),
            .accounts = std.AutoHashMap(shared.types.Address, shared.types.AccountState).init(allocator),
            .api_wallet_owners = std.AutoHashMap(shared.types.Address, shared.types.Address).init(allocator),
            .meta = meta,
            .all_mids = .{},
            .metrics = .{},
        };
    }

    pub fn deinit(self: *StateCache) void {
        shared.serialization.deinitExchangeMeta(self.allocator, &self.meta);
        self.all_mids.deinit(self.allocator);

        var accounts_it = self.accounts.iterator();
        while (accounts_it.next()) |entry| {
            shared.serialization.deinitAccountState(self.allocator, entry.value_ptr);
        }

        var books_it = self.books.iterator();
        while (books_it.next()) |entry| {
            shared.serialization.deinitL2Snapshot(self.allocator, entry.value_ptr);
        }

        self.api_wallet_owners.deinit();
        self.accounts.deinit();
        self.books.deinit();
    }

    pub fn applyEvent(self: *StateCache, event: shared.protocol.NodeEvent) !void {
        switch (event) {
            .l2_book_update => |update| {
                if (self.books.get(update.asset_id)) |current| {
                    if (update.seq <= current.seq) {
                        self.metrics.stale_events += 1;
                        return;
                    }
                }
                var cloned = try shared.serialization.cloneL2Snapshot(self.allocator, update);
                errdefer shared.serialization.deinitL2Snapshot(self.allocator, &cloned);

                const gop = try self.books.getOrPut(update.asset_id);
                if (gop.found_existing) {
                    shared.serialization.deinitL2Snapshot(self.allocator, gop.value_ptr);
                }
                gop.value_ptr.* = cloned;
            },
            .all_mids => |all_mids| {
                self.all_mids.deinit(self.allocator);
                self.all_mids = try shared.serialization.cloneAllMidsUpdate(self.allocator, all_mids);
            },
            .user_update => |account| {
                var cloned = try shared.serialization.cloneAccountState(self.allocator, account);
                errdefer shared.serialization.deinitAccountState(self.allocator, &cloned);

                const gop = try self.accounts.getOrPut(account.address);
                if (gop.found_existing) {
                    if (gop.value_ptr.api_wallet) |wallet| {
                        _ = self.api_wallet_owners.remove(wallet);
                    }
                    shared.serialization.deinitAccountState(self.allocator, gop.value_ptr);
                }
                gop.value_ptr.* = cloned;

                if (account.api_wallet) |wallet| {
                    try self.api_wallet_owners.put(wallet, account.address);
                }
            },
            else => {},
        }

        self.metrics.applied_events += 1;
    }

    pub fn getMeta(self: *const StateCache) shared.types.ExchangeMeta {
        return self.meta;
    }

    pub fn getAllMids(self: *const StateCache) shared.types.AllMidsUpdate {
        return self.all_mids;
    }

    pub fn getL2Book(self: *const StateCache, asset_id: shared.types.AssetId, depth: u32) CacheError!shared.types.L2Snapshot {
        _ = depth;
        return self.books.get(asset_id) orelse CacheError.NotFound;
    }

    pub fn getUserState(self: *const StateCache, user: shared.types.Address) CacheError!shared.types.UserStateView {
        return self.accounts.get(user) orelse CacheError.NotFound;
    }

    pub fn getOpenOrders(self: *const StateCache, user: shared.types.Address) CacheError![]const u64 {
        const account = self.accounts.get(user) orelse return CacheError.NotFound;
        return account.open_orders;
    }

    pub fn getApiWalletOwner(self: *const StateCache, signer: shared.types.Address) ?shared.types.Address {
        return self.api_wallet_owners.get(signer);
    }
};

test "stale book updates are counted and ignored" {
    var cache = try StateCache.init(.{}, std.testing.allocator);
    defer cache.deinit();

    const snapshot = shared.types.L2Snapshot{
        .asset_id = 0,
        .seq = 2,
        .bids = &.{},
        .asks = &.{},
        .is_snapshot = true,
    };
    const stale = shared.types.L2Snapshot{
        .asset_id = 0,
        .seq = 1,
        .bids = &.{},
        .asks = &.{},
        .is_snapshot = false,
    };

    try cache.applyEvent(.{ .l2_book_update = snapshot });
    try cache.applyEvent(.{ .l2_book_update = stale });

    try std.testing.expectEqual(@as(u64, 1), cache.metrics.stale_events);
}
