# Module: Risk Engine

**File:** `src/node/engine/risk.zig`  
**Depends on:** `shared/types`, `perp` (mark price)

## Responsibilities

- Check whether accounts have sufficient margin before new exposure is opened
- Update positions and unrealized PnL after fills
- Track maintenance margin requirements and enqueue liquidations
- Execute liquidation against the insurance fund
- Trigger ADL when the insurance fund is exhausted

## Interface

```zig
pub const RiskEngine = struct {
    allocator:      std.mem.Allocator,
    insurance_fund: Quantity,

    pub fn init(alloc: std.mem.Allocator) RiskEngine
    pub fn deinit(self: *RiskEngine) void

    pub fn onFill(
        self: *RiskEngine,
        taker: *const OrderEntry,
        maker: *const OrderEntry,
        fill_size: Quantity,
        fill_px: Price,
        state: *GlobalState,
    ) !void

    pub fn checkLiquidations(self: *RiskEngine, state: *GlobalState) ![]LiquidationEvent
    pub fn liquidate(self: *RiskEngine, event: LiquidationEvent, state: *GlobalState) !void
    pub fn adl(self: *RiskEngine, asset_id: u32, side: Side, state: *GlobalState) !void
    pub fn getAccountHealth(self: *RiskEngine, addr: Address, state: *GlobalState) AccountHealth
};
```

## Margin Calculation

```zig
pub fn crossMarginAvailable(account: *AccountState, state: *GlobalState) Quantity {
    const total_equity = account.balance + unrealizedPnl(account, state);
    const total_im = initialMarginRequired(account, state);
    return total_equity - total_im;
}

pub fn isolatedMarginAvailable(pos: *Position) Quantity {
    return pos.isolated_margin + pos.unrealized_pnl;
}

pub fn maintenanceMarginRequired(pos: *Position, mark_px: Price) Quantity {
    return pos.size * mark_px * MAINTENANCE_MARGIN_RATE;
}
```

## Liquidation Logic

```zig
pub fn checkLiquidations(self: *RiskEngine, state: *GlobalState) ![]LiquidationEvent {
    var events = std.ArrayList(LiquidationEvent).init(self.allocator);

    for (state.accounts.values()) |*account| {
        for (account.positions.values()) |*pos| {
            const mark_px = state.oracle_prices.get(pos.asset_id);
            const mm_req = maintenanceMarginRequired(pos, mark_px);
            const margin = availableMargin(account, pos);

            if (margin < mm_req) {
                try events.append(.{
                    .user = account.address,
                    .asset_id = pos.asset_id,
                    .size = pos.size,
                    .side = pos.side,
                    .mark_px = mark_px,
                });
            }
        }
    }
    return events.toOwnedSlice();
}

pub fn liquidate(self: *RiskEngine, event: LiquidationEvent, state: *GlobalState) !void {
    const close_px = event.mark_px;
    const pnl = calcPnl(event, close_px);

    if (pnl > 0) {
        self.insurance_fund += pnl;
    } else {
        if (self.insurance_fund >= -pnl) {
            self.insurance_fund += pnl;
        } else {
            try self.adl(event.asset_id, event.side.opposite(), state);
        }
    }

    state.accounts.removePosition(event.user, event.asset_id);
}
```

## ADL Ranking

```zig
pub fn adlRank(pos: *Position, mark_px: Price) f64 {
    const upnl = unrealizedPnl(pos, mark_px);
    const notional = pos.size * mark_px;
    const pnl_ratio = upnl / notional;
    const leverage = notional / pos.isolated_margin;
    return pnl_ratio * leverage;
}
```

## Harness Concerns

Risk tests need:

- controllable account snapshots and mark prices
- optional test configuration to record whether ADL fired
- readable insurance fund balances, liquidation outputs, and `adl_invocations`

## Test Harness

```zig
// src/node/engine/risk_test.zig

test "sufficient margin allows the order" {
    var state = testState(.{ .balance = 100_000 });
    var risk = RiskEngine.init(alloc);

    try risk.onFill(&taker_1btc_buy, &maker, 1, 50000, &state);
}

test "insufficient margin returns error.InsufficientMargin" {
    var state = testState(.{ .balance = 100 });
    var risk = RiskEngine.init(alloc);

    try std.testing.expectError(
        error.InsufficientMargin,
        risk.onFill(&taker_1btc_buy, &maker, 1, 50000, &state),
    );
}

test "maintenance breach produces a liquidation event" {
    var state = testState(.{
        .balance = 500,
        .position = .{ .asset_id = 0, .size = 1, .side = .long, .entry_price = 50000 },
        .mark_price = 47000,
    });
    var risk = RiskEngine.init(alloc);

    const events = try risk.checkLiquidations(&state);
    try std.testing.expectEqual(1, events.len);
    try std.testing.expectEqual(@as(u32, 0), events[0].asset_id);
}

test "liquidation surplus flows to the insurance fund" {
    var state = testState(.{
        .position = .{ .asset_id = 0, .size = 1, .side = .long, .entry_price = 50000 },
        .mark_price = 50500,
    });
    var risk = RiskEngine.init(alloc);
    risk.insurance_fund = 0;

    try risk.liquidate(.{
        .user = test_addr,
        .asset_id = 0,
        .size = 1,
        .side = .long,
        .mark_px = 50500,
    }, &state);

    try std.testing.expect(risk.insurance_fund > 0);
}

test "insurance fund exhaustion triggers ADL" {
    var state = testState(.{
        .position = .{ .asset_id = 0, .size = 10, .side = .long, .entry_price = 50000 },
        .mark_price = 30000,
    });
    var risk = try RiskEngine.initTest(.{ .record_adl = true }, alloc);
    risk.insurance_fund = 0;

    try risk.liquidate(.{
        .user = test_addr,
        .asset_id = 0,
        .size = 10,
        .side = .long,
        .mark_px = 30000,
    }, &state);

    try std.testing.expectEqual(@as(u64, 1), risk.metrics.adl_invocations);
}

test "higher profit ratio ranks earlier in ADL" {
    const pos_a = Position{ .size = 1, .entry_price = 45000, .isolated_margin = 5000, .side = .long };
    const pos_b = Position{ .size = 1, .entry_price = 49000, .isolated_margin = 10000, .side = .long };

    const rank_a = adlRank(&pos_a, 50000);
    const rank_b = adlRank(&pos_b, 50000);
    try std.testing.expect(rank_a > rank_b);
}
```
