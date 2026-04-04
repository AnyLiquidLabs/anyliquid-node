# Module: Perp Engine

**File:** `src/node/engine/perp.zig`  
**Depends on:** `shared/types`, `oracle`

## Responsibilities

- Calculate and settle funding rates on a fixed cadence
- Maintain mark prices
- Maintain index prices sourced from the oracle layer
- Calculate unrealized PnL from mark prices

## Interface

```zig
pub const PerpEngine = struct {
    pub fn init(alloc: std.mem.Allocator) PerpEngine
    pub fn calcFundingRate(self: *PerpEngine, asset_id: u32, state: *GlobalState) FundingRate
    pub fn settleFunding(self: *PerpEngine, asset_id: u32, state: *GlobalState) !FundingEvent
    pub fn updateMarkPrice(self: *PerpEngine, asset_id: u32, state: *GlobalState) void
    pub fn unrealizedPnl(pos: *const Position, mark_px: Price) Quantity
};
```

## Funding Formula

```text
basis premium = (mark price - index price) / index price
funding rate = clamp(basis premium + interest basis (0.01%), -0.05%, 0.05%)

settlement:
  longs pay = position notional * funding rate      when rate > 0
  shorts pay = position notional * abs(funding rate) when rate < 0
```

## Mark Price

```zig
pub fn calcMarkPrice(book: *const OrderBook, index_px: Price) Price {
    const mid = bookMidPrice(book);
    const basis = mid - index_px;
    const max_dev = index_px * 0.005;
    const clamped = std.math.clamp(basis, -max_dev, max_dev);
    return index_px + clamped;
}
```

## Test Harness

```zig
test "positive funding means longs pay shorts" {
    const state = testStateWithPrices(.{ .mark = 50500, .index = 50000 });
    var perp = PerpEngine.init(alloc);

    const event = try perp.settleFunding(0, &state);
    try std.testing.expect(event.long_payment > 0);
}

test "funding rate is clamped at 0.05%" {
    const state = testStateWithPrices(.{ .mark = 60000, .index = 50000 });
    var perp = PerpEngine.init(alloc);

    const rate = perp.calcFundingRate(0, &state);
    try std.testing.expectApproxEqAbs(0.0005, rate.value, 1e-9);
}

test "mark price stays within +/-0.5% of index" {
    const book = testBook(.{ .best_bid = 50400, .best_ask = 50600 });
    const mark = calcMarkPrice(&book, 50000);
    try std.testing.expect(mark <= 50000 * 1.005);
    try std.testing.expect(mark >= 50000 * 0.995);
}
```
