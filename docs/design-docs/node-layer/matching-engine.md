# Module: Matching Engine

**File:** `src/node/engine/matching.zig`  
**Depends on:** `shared/types`, `store` (read-only), `risk` (pre-fill hook)

## Responsibilities

- Maintain a bid and ask order book per asset
- Match limit and market-style orders using price-time priority
- Implement `post-only`, `IOC`, and `FOK` semantics
- Manage trigger orders such as stop-market, stop-limit, and TP/SL variants
- Invoke `RiskEngine` before every fill

## Interface

```zig
pub const MatchingEngine = struct {
    allocator: std.mem.Allocator,
    books:     []OrderBook,
    risk:      *RiskEngine,

    pub fn init(asset_count: u32, risk: *RiskEngine, alloc: std.mem.Allocator) !MatchingEngine
    pub fn deinit(self: *MatchingEngine) void
    pub fn placeOrder(self: *MatchingEngine, order: Order, state: *GlobalState) ![]Fill
    pub fn cancelOrder(self: *MatchingEngine, cancel: CancelRequest, state: *GlobalState) !void
    pub fn cancelByCloid(self: *MatchingEngine, req: CancelByCloidRequest, state: *GlobalState) !void
    pub fn checkTriggers(self: *MatchingEngine, asset_id: u32, price: Price, state: *GlobalState) ![]Fill
    pub fn getL2Snapshot(self: *MatchingEngine, asset_id: u32, depth: u32) L2Snapshot
};
```

## Order Book Structures

```zig
pub const OrderBook = struct {
    asset_id:  u32,
    bids:      PriceLevelTree,
    asks:      PriceLevelTree,
    orders:    OrderMap,
    cloid_map: CloidMap,
    seq:       u64,
};

pub const PriceLevel = struct {
    price:      Price,
    orders:     std.DoublyLinkedList(OrderEntry),
    total_size: Quantity,
};

pub const PriceLevelTree = std.TreeMap(Price, PriceLevel, priceComparator);

pub const OrderEntry = struct {
    id:         u64,
    user:       Address,
    asset_id:   u32,
    is_buy:     bool,
    price:      Price,
    orig_size:  Quantity,
    remaining:  Quantity,
    order_type: OrderType,
    cloid:      ?[16]u8,
    placed_at:  i64,
};
```

## Matching Loop

```zig
fn matchAgainstBook(
    book: *OrderBook,
    taker: *OrderEntry,
    state: *GlobalState,
    fills: *FillList,
) !void {
    const maker_side = if (taker.is_buy) &book.asks else &book.bids;

    while (taker.remaining > 0) {
        const best = maker_side.min() orelse break;

        if (taker.is_buy and taker.price < best.price) break;
        if (!taker.is_buy and taker.price > best.price) break;

        var it = best.orders.first;
        while (it) |node| : (it = node.next) {
            const maker = &node.data;
            const fill_size = @min(taker.remaining, maker.remaining);

            try risk.onFill(taker, maker, fill_size, best.price, state);

            fills.append(Fill{
                .taker_order_id = taker.id,
                .maker_order_id = maker.id,
                .asset_id = taker.asset_id,
                .price = best.price,
                .size = fill_size,
                .timestamp = state.timestamp,
                .taker_addr = taker.user,
                .maker_addr = maker.user,
                .fee = 0,
            });

            taker.remaining -= fill_size;
            maker.remaining -= fill_size;

            if (maker.remaining == 0) {
                removeOrder(book, maker);
            }

            if (taker.remaining == 0) break;
        }

        if (best.orders.len == 0) {
            maker_side.remove(best.price);
        }
    }
}
```

## Order Types

```zig
pub const OrderType = union(enum) {
    limit: struct {
        tif: TimeInForce,
    },
    trigger: struct {
        trigger_px: Price,
        is_market:  bool,
        tpsl:       TpslType,
    },
};

fn handleAlo(book: *OrderBook, order: *OrderEntry) !void {
    if (wouldCrossSpread(book, order)) {
        return error.WouldTakeNotPost;
    }
    insertIntoBook(book, order);
}
```

## Test Harness

```zig
// src/node/engine/matching_test.zig

test "crossing limit orders produce a fill" {
    var engine = try MatchingEngine.initTest(alloc);
    defer engine.deinit();

    _ = try engine.placeOrder(makeSell(.{ .price = 100, .size = 1 }), &state);
    const fills = try engine.placeOrder(makeBuy(.{ .price = 100, .size = 1 }), &state);

    try std.testing.expectEqual(1, fills.len);
    try std.testing.expectEqual(100, fills[0].price);
    try std.testing.expectEqual(1, fills[0].size);
}

test "price-time priority fills the older maker first" {
    var engine = try MatchingEngine.initTest(alloc);
    defer engine.deinit();

    const maker1_id = 1001;
    const maker2_id = 1002;
    _ = try engine.placeOrder(makeSell(.{ .id = maker1_id, .price = 100, .size = 1, .time = 1000 }), &state);
    _ = try engine.placeOrder(makeSell(.{ .id = maker2_id, .price = 100, .size = 1, .time = 2000 }), &state);

    const fills = try engine.placeOrder(makeBuy(.{ .price = 100, .size = 1 }), &state);
    try std.testing.expectEqual(1, fills.len);
    try std.testing.expectEqual(maker1_id, fills[0].maker_order_id);
}

test "post-only order that would cross is rejected" {
    var engine = try MatchingEngine.initTest(alloc);
    defer engine.deinit();

    _ = try engine.placeOrder(makeSell(.{ .price = 100, .size = 1 }), &state);

    try std.testing.expectError(
        error.WouldTakeNotPost,
        engine.placeOrder(makeBuy(.{ .price = 100, .size = 1, .tif = .Alo }), &state),
    );
}

test "IOC partial fill cancels the remainder" {
    var engine = try MatchingEngine.initTest(alloc);
    defer engine.deinit();

    _ = try engine.placeOrder(makeSell(.{ .price = 100, .size = 0.5 }), &state);
    const fills = try engine.placeOrder(makeBuy(.{ .price = 100, .size = 1, .tif = .Ioc }), &state);

    try std.testing.expectEqual(1, fills.len);
    try std.testing.expectEqual(0.5, fills[0].size);
    try std.testing.expectEqual(0, engine.books[0].bids.size());
}

test "cancel removes a resting order from the book" {
    var engine = try MatchingEngine.initTest(alloc);
    defer engine.deinit();

    const resting_id = 2001;
    _ = try engine.placeOrder(makeSell(.{ .id = resting_id, .price = 100, .size = 1 }), &state);
    try engine.cancelOrder(.{ .order_id = resting_id }, &state);

    const snapshot = engine.getL2Snapshot(0, 10);
    try std.testing.expectEqual(0, snapshot.asks.len);
}

test "stop-market trigger fires after crossing the trigger price" {
    var engine = try MatchingEngine.initTest(alloc);
    defer engine.deinit();

    _ = try engine.placeOrder(makeStopMarket(.{ .trigger_px = 95, .size = 1, .is_buy = false }), &state);
    const fills = try engine.checkTriggers(0, 94, &state);

    try std.testing.expectEqual(1, fills.len);
}
```

## Performance Notes

- `PriceLevelTree` uses a red-black tree for `O(log n)` inserts and deletes.
- The hot matching path stays on the stack while fills are written into an arena.
- `OrderMap` should use an open-addressed hash table to minimize pointer chasing.
