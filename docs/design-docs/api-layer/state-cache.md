# Module: Local State Cache

**File:** `src/api/state_cache.zig`  
**Depends on:** `shared/types`, `shared/protocol`

## Responsibilities

- Maintain a local read-only state replica for `/info` queries and WebSocket bootstrap snapshots
- Consume `NodeEvent` updates and apply them to in-memory indexes
- Preserve monotonic sequencing for asset and user views so clients can detect missed updates
- Provide query methods only, with no business validation and no write forwarding

## Interface

```zig
pub const StateCache = struct {
    allocator: std.mem.Allocator,
    books:     std.AutoHashMap(u32, BookView),
    accounts:  std.AutoHashMap(Address, AccountView),
    meta:      ExchangeMeta,
    all_mids:  AllMidsView,
    metrics:   CacheMetrics,

    pub fn init(cfg: CacheConfig, alloc: std.mem.Allocator) !StateCache
    pub fn deinit(self: *StateCache) void
    pub fn applyEvent(self: *StateCache, event: NodeEvent) !void

    pub fn getMeta(self: *const StateCache) ExchangeMeta
    pub fn getAllMids(self: *const StateCache) AllMidsView
    pub fn getL2Book(self: *const StateCache, asset_id: u32, depth: u32) !L2Snapshot
    pub fn getUserState(self: *const StateCache, user: Address) !UserStateView
    pub fn getOpenOrders(self: *const StateCache, user: Address) ![]const RestingOrderView
    pub fn getApiWalletOwner(self: *const StateCache, signer: Address) ?Address
};

pub const CacheMetrics = struct {
    applied_events: u64,
    stale_events:   u64,
};
```

## Consistency Rules

- `StateCache` consumes only Node-originated events and never reads internal engine state directly.
- `l2_book_update.seq` must increase strictly per `asset_id`. Stale updates are dropped and counted.
- User-account views should be versioned by event sequence or block height to avoid out-of-order overwrites.
- `/info` requests should return explicit cache-miss errors instead of silently falling back to Node.

## Event Application Model

```zig
pub fn applyEvent(self: *StateCache, event: NodeEvent) !void {
    switch (event) {
        .l2_book_update => |upd| {
            const current = self.books.getPtr(upd.asset_id);
            if (current != null and upd.seq <= current.?.seq) {
                self.metrics.stale_events += 1;
                return;
            }
            try self.books.put(upd.asset_id, BookView.fromUpdate(upd));
        },
        .trade => |fill| {
            try self.appendRecentTrade(fill.asset_id, fill);
        },
        .user_update => |acct| {
            try self.accounts.put(acct.address, AccountView.fromAccountState(acct));
        },
        .all_mids => |mids| self.all_mids = AllMidsView.fromUpdate(mids),
        else => {},
    }
}
```

## Harness Concerns

The cache module should support:

- `cache_seed` for direct construction of queryable snapshots
- `inject_event` for incremental-update and out-of-order tests
- readable counters such as `stale_events`, `applied_events`, and last-seen sequences
- direct `applyEvent` tests without starting a real Gateway

## Test Harness

```zig
// src/api/state_cache_test.zig

test "seeded l2 book query returns local snapshot" {
    var cache = try StateCache.init(.{
        .seed = .{ .books = &.{sample_btc_book} },
    }, alloc);
    defer cache.deinit();

    const book = try cache.getL2Book(0, 10);
    try std.testing.expectEqual(@as(usize, 1), book.bids.len);
}

test "newer l2 update replaces the previous snapshot" {
    var cache = try StateCache.init(.{}, alloc);
    defer cache.deinit();

    try cache.applyEvent(.{ .l2_book_update = sample_book_seq_10 });
    try cache.applyEvent(.{ .l2_book_update = sample_book_seq_11 });

    const book = try cache.getL2Book(0, 10);
    try std.testing.expectEqual(@as(u64, 11), book.seq);
}

test "stale l2 update is ignored and counted" {
    var cache = try StateCache.init(.{}, alloc);
    defer cache.deinit();

    try cache.applyEvent(.{ .l2_book_update = sample_book_seq_11 });
    try cache.applyEvent(.{ .l2_book_update = sample_book_seq_10 });

    try std.testing.expectEqual(@as(u64, 1), cache.metrics.stale_events);
}

test "user update makes API wallet ownership queryable" {
    var cache = try StateCache.init(.{}, alloc);
    defer cache.deinit();

    try cache.applyEvent(.{ .user_update = sample_account_with_api_wallet });
    try std.testing.expectEqual(owner_addr, cache.getApiWalletOwner(api_wallet_addr).?);
}
```
