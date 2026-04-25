const std = @import("std");
const shared = @import("../../shared/mod.zig");
const state_mod = @import("../state.zig");

pub const LiquidationOutcome = struct {
    pnl: shared.types.SignedAmount,
    insurance_fund: shared.types.SignedAmount,
    adl_triggered: bool,
};

pub const LiquidationCenter = struct {
    allocator: std.mem.Allocator,
    queue: std.ArrayList(shared.types.LiquidationEvent),
    insurance_fund: shared.types.SignedAmount = 0,
    adl_invocations: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) LiquidationCenter {
        return .{
            .allocator = allocator,
            .queue = .empty,
        };
    }

    pub fn deinit(self: *LiquidationCenter) void {
        self.queue.deinit(self.allocator);
    }

    pub fn enqueue(self: *LiquidationCenter, event: shared.types.LiquidationEvent) !void {
        for (self.queue.items) |existing| {
            if (std.mem.eql(u8, existing.user[0..], event.user[0..]) and existing.asset_id == event.asset_id) {
                return;
            }
        }
        try self.queue.append(self.allocator, event);
    }

    pub fn queued(self: *const LiquidationCenter) []const shared.types.LiquidationEvent {
        return self.queue.items;
    }

    pub fn clear(self: *LiquidationCenter) void {
        self.queue.clearRetainingCapacity();
    }

    pub fn execute(
        self: *LiquidationCenter,
        event: shared.types.LiquidationEvent,
        entry_price: shared.types.Price,
    ) LiquidationOutcome {
        const pnl = PerpEngine.unrealizedPnl(&.{
            .asset_id = event.asset_id,
            .side = event.side,
            .size = event.size,
            .entry_price = entry_price,
        }, event.mark_px);

        var adl_triggered = false;
        if (pnl >= 0) {
            self.insurance_fund += pnl;
        } else if (self.insurance_fund + pnl >= 0) {
            self.insurance_fund += pnl;
        } else {
            self.adl_invocations += 1;
            adl_triggered = true;
            self.insurance_fund = 0;
        }

        return .{
            .pnl = pnl,
            .insurance_fund = self.insurance_fund,
            .adl_triggered = adl_triggered,
        };
    }
};

const OpenInterest = struct {
    long_notional: shared.types.Price = 0,
    short_notional: shared.types.Price = 0,
};

pub const PerpEngine = struct {
    allocator: std.mem.Allocator,
    index_prices: std.AutoHashMap(shared.types.AssetId, shared.types.Price),
    mark_prices: std.AutoHashMap(shared.types.AssetId, shared.types.Price),
    open_interest: std.AutoHashMap(shared.types.AssetId, OpenInterest),
    liquidation_center: LiquidationCenter,

    pub fn init(allocator: std.mem.Allocator) PerpEngine {
        return .{
            .allocator = allocator,
            .index_prices = std.AutoHashMap(shared.types.AssetId, shared.types.Price).init(allocator),
            .mark_prices = std.AutoHashMap(shared.types.AssetId, shared.types.Price).init(allocator),
            .open_interest = std.AutoHashMap(shared.types.AssetId, OpenInterest).init(allocator),
            .liquidation_center = LiquidationCenter.init(allocator),
        };
    }

    pub fn deinit(self: *PerpEngine) void {
        self.liquidation_center.deinit();
        self.open_interest.deinit();
        self.mark_prices.deinit();
        self.index_prices.deinit();
    }

    pub fn setIndexPrice(self: *PerpEngine, asset_id: shared.types.AssetId, price: shared.types.Price) !void {
        try self.index_prices.put(asset_id, price);
    }

    pub fn setMarkPrice(self: *PerpEngine, asset_id: shared.types.AssetId, price: shared.types.Price) !void {
        try self.mark_prices.put(asset_id, price);
    }

    pub fn setOpenInterest(
        self: *PerpEngine,
        asset_id: shared.types.AssetId,
        long_notional: shared.types.Price,
        short_notional: shared.types.Price,
    ) !void {
        try self.open_interest.put(asset_id, .{
            .long_notional = long_notional,
            .short_notional = short_notional,
        });
    }

    pub fn markPrice(self: *const PerpEngine, asset_id: shared.types.AssetId) ?shared.types.Price {
        return self.mark_prices.get(asset_id);
    }

    pub fn indexPrice(self: *const PerpEngine, asset_id: shared.types.AssetId) ?shared.types.Price {
        return self.index_prices.get(asset_id);
    }

    pub fn calcFundingRate(
        self: *PerpEngine,
        asset_id: shared.types.AssetId,
        state: *state_mod.GlobalState,
    ) shared.types.FundingRate {
        _ = state;
        const index_px = self.index_prices.get(asset_id) orelse return .{ .value = 0.0 };
        const mark_px = self.mark_prices.get(asset_id) orelse index_px;

        const index_f = priceToF64(index_px);
        const mark_f = priceToF64(mark_px);
        if (index_f == 0.0) return .{ .value = 0.0 };

        const premium = (mark_f - index_f) / index_f;
        const rate = std.math.clamp(premium + 0.0001, -0.0005, 0.0005);
        return .{ .value = rate };
    }

    pub fn settleFunding(
        self: *PerpEngine,
        asset_id: shared.types.AssetId,
        state: *state_mod.GlobalState,
    ) !shared.types.FundingEvent {
        const rate = self.calcFundingRate(asset_id, state).value;
        const exposure = self.open_interest.get(asset_id) orelse .{};

        const long_payment = fundingPayment(exposure.long_notional, rate);
        const short_payment = fundingPayment(exposure.short_notional, -rate);
        return .{
            .asset_id = asset_id,
            .rate_bps = @intFromFloat(rate * 10_000.0),
            .long_payment = long_payment,
            .short_payment = short_payment,
        };
    }

    pub fn updateMarkPrice(self: *PerpEngine, asset_id: shared.types.AssetId, state: *state_mod.GlobalState) void {
        _ = state;
        const index_px = self.index_prices.get(asset_id) orelse return;
        const current = self.mark_prices.get(asset_id) orelse index_px;
        self.mark_prices.put(asset_id, current) catch {};
    }

    pub fn updateMarkPriceFromBook(
        self: *PerpEngine,
        asset_id: shared.types.AssetId,
        best_bid: ?shared.types.Price,
        best_ask: ?shared.types.Price,
        state: *state_mod.GlobalState,
    ) void {
        _ = state;
        const index_px = self.index_prices.get(asset_id) orelse best_bid orelse best_ask orelse return;
        const mid = calcBookMid(best_bid, best_ask) orelse index_px;
        const mark = calcMarkPrice(mid, index_px);
        self.mark_prices.put(asset_id, mark) catch {};
    }

    pub fn unrealizedPnl(pos: *const shared.types.Position, mark_px: shared.types.Price) shared.types.SignedAmount {
        const price_delta: i128 = switch (pos.side) {
            .long => @as(i128, mark_px) - @as(i128, pos.entry_price),
            .short => @as(i128, pos.entry_price) - @as(i128, mark_px),
        };
        const pnl = @divTrunc(
            price_delta * @as(i128, @intCast(pos.size)),
            @as(i128, shared.types.PRICE_SCALE),
        );
        return @intCast(pnl);
    }
};

fn calcBookMid(best_bid: ?shared.types.Price, best_ask: ?shared.types.Price) ?shared.types.Price {
    return if (best_bid != null and best_ask != null)
        @intCast(@divTrunc(@as(i128, best_bid.?) + @as(i128, best_ask.?), 2))
    else
        best_bid orelse best_ask;
}

fn calcMarkPrice(mid: shared.types.Price, index_px: shared.types.Price) shared.types.Price {
    const max_dev: shared.types.Price = @intCast(@divTrunc(@as(i128, index_px) * 5, 1000));
    if (mid > index_px) {
        const diff = mid - index_px;
        return index_px + @min(diff, max_dev);
    }
    const diff = index_px - mid;
    return index_px - @min(diff, max_dev);
}

fn priceToF64(price: shared.types.Price) f64 {
    return @as(f64, @floatFromInt(price)) / @as(f64, @floatFromInt(shared.types.PRICE_SCALE));
}

fn fundingPayment(notional: shared.types.Price, rate: f64) shared.types.SignedAmount {
    const payment = @as(f64, @floatFromInt(notional)) * rate / @as(f64, @floatFromInt(shared.types.PRICE_SCALE));
    return @intFromFloat(payment);
}
