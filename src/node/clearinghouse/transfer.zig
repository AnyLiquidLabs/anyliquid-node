const std = @import("std");
const shared = @import("../../shared/mod.zig");
const types = @import("types.zig");
const account = @import("account.zig");
const margin_mod = @import("margin.zig");

/// TransferEngine handles all collateral movements: intra-master transfers, deposits, withdrawals.
pub const TransferEngine = struct {
    allocator: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) TransferEngine {
        return .{
            .allocator = alloc,
        };
    }

    /// Execute intra-master transfer between sub-accounts.
    pub fn executeIntraMaster(
        self: *TransferEngine,
        margin_engine: *const margin_mod.MarginEngine,
        from_index: u8,
        to_index: u8,
        asset_id: types.AssetId,
        amount: shared.types.Quantity,
        master: *account.MasterAccount,
        state: *const margin_mod.GlobalState,
    ) !types.TransferEvent {
        if (from_index == to_index) return error.SameAccount;
        if (from_index >= types.MAX_SUB_ACCOUNTS) return error.InvalidSubAccountIndex;
        if (to_index >= types.MAX_SUB_ACCOUNTS) return error.InvalidSubAccountIndex;

        _ = self;
        const from_sub = master.subAccountByIndex(from_index) orelse return error.SubAccountNotFound;
        const to_sub = master.subAccountByIndex(to_index) orelse return error.SubAccountNotFound;

        // Check source has sufficient balance
        if (from_sub.collateral.rawBalance(asset_id) < amount) return error.InsufficientBalance;

        // Check transfer would not breach maintenance margin
        try margin_engine.checkTransferMargin(from_sub, asset_id, amount, state);

        // Execute transfer atomically
        try from_sub.collateral.withdraw(asset_id, amount);
        to_sub.collateral.credit(asset_id, amount);

        return .{
            .from_addr = from_sub.address,
            .to_addr = to_sub.address,
            .asset_id = asset_id,
            .amount = amount,
            .timestamp = state.now_ms,
        };
    }

    /// Execute deposit to a sub-account.
    pub fn executeDeposit(
        self: *TransferEngine,
        to_index: u8,
        asset_id: types.AssetId,
        amount: shared.types.Quantity,
        master: *account.MasterAccount,
        state: *const margin_mod.GlobalState,
    ) !types.TransferEvent {
        _ = self;
        if (to_index >= types.MAX_SUB_ACCOUNTS) return error.InvalidSubAccountIndex;

        const to_sub = master.subAccountByIndex(to_index) orelse return error.SubAccountNotFound;

        // Credit the deposit
        to_sub.collateral.credit(asset_id, amount);

        return .{
            .from_addr = [_]u8{0} ** 20, // External source
            .to_addr = to_sub.address,
            .asset_id = asset_id,
            .amount = amount,
            .timestamp = state.now_ms,
        };
    }

    /// Execute withdrawal from a sub-account.
    pub fn executeWithdrawal(
        self: *TransferEngine,
        margin_engine: *const margin_mod.MarginEngine,
        from_index: u8,
        asset_id: types.AssetId,
        amount: shared.types.Quantity,
        destination: shared.types.Address,
        master: *account.MasterAccount,
        state: *const margin_mod.GlobalState,
    ) !types.TransferEvent {
        if (from_index >= types.MAX_SUB_ACCOUNTS) return error.InvalidSubAccountIndex;

        _ = self;
        const from_sub = master.subAccountByIndex(from_index) orelse return error.SubAccountNotFound;

        // Check source has sufficient balance
        if (from_sub.collateral.rawBalance(asset_id) < amount) return error.InsufficientBalance;

        // Check withdrawal would not breach transfer margin floor
        try margin_engine.checkTransferMargin(from_sub, asset_id, amount, state);

        // Execute withdrawal
        try from_sub.collateral.withdraw(asset_id, amount);

        return .{
            .from_addr = from_sub.address,
            .to_addr = destination,
            .asset_id = asset_id,
            .amount = amount,
            .timestamp = state.now_ms,
        };
    }
};

pub const GlobalState = struct {
    now_ms: i64,
};

const test_btc_mark = shared.fixed_point.priceFromWhole(100_000 * types.USDC);

fn testBtcMark(_: types.InstrumentId) ?shared.types.Price {
    return test_btc_mark;
}

test "intra-master transfer - moves asset between sub-accounts" {
    const alloc = std.testing.allocator;
    const master_addr = [_]u8{0xAA} ** 20;
    var master = account.MasterAccount.init(alloc, master_addr, 0);
    defer master.deinit();

    _ = try master.openSubAccount(0, null, 0);
    _ = try master.openSubAccount(1, null, 0);

    const sub0 = master.subAccountByIndex(0).?;
    const sub1 = master.subAccountByIndex(1).?;

    try sub0.collateral.deposit(types.USDC_ID, 10_000 * types.USDC, &types.defaultCollateralRegistry);

    const state = margin_mod.GlobalState{
        .markPriceFn = struct {
            fn mark(_: types.InstrumentId) ?shared.types.Price {
                return null;
            }
        }.mark,
        .now_ms = 0,
    };

    const margin_engine = margin_mod.MarginEngine.init(.{});
    var engine = TransferEngine.init(alloc);

    const event = try engine.executeIntraMaster(&margin_engine, 0, 1, types.USDC_ID, 3_000 * types.USDC, &master, &state);

    try std.testing.expect(std.mem.eql(u8, &event.from_addr, &sub0.address));
    try std.testing.expect(std.mem.eql(u8, &event.to_addr, &sub1.address));
    try std.testing.expect(event.amount == 3_000 * types.USDC);

    try std.testing.expectEqual(7_000 * types.USDC, sub0.collateral.rawBalance(types.USDC_ID));
    try std.testing.expectEqual(3_000 * types.USDC, sub1.collateral.rawBalance(types.USDC_ID));
}

test "intra-master transfer - rejected if would breach maintenance margin" {
    const alloc = std.testing.allocator;
    const master_addr = [_]u8{0xAA} ** 20;
    var master = account.MasterAccount.init(alloc, master_addr, 0);
    defer master.deinit();

    _ = try master.openSubAccount(0, null, 0);
    _ = try master.openSubAccount(1, null, 0);

    const sub0 = master.subAccountByIndex(0).?;
    try sub0.collateral.deposit(types.USDC_ID, 3_000 * types.USDC, &types.defaultCollateralRegistry);

    // Create a position that requires margin
    try sub0.positions.put(1, .{
        .instrument_id = 1,
        .kind = .{ .perp = .{
            .tick_size = 1,
            .lot_size = 1,
            .max_leverage = 50,
            .funding_interval_ms = 3_600_000,
            .mark_method = .oracle,
            .isolated_only = false,
        } },
        .user = sub0.address,
        .size = 1,
        .side = .long,
        .entry_price = test_btc_mark,
        .realized_pnl = 0,
        .leverage = 10,
        .margin_mode = .cross,
        .isolated_margin = 0,
        .funding_index = 0,
        .delta = 0,
        .gamma = 0,
        .vega = 0,
        .theta = 0,
    });

    const state = margin_mod.GlobalState{
        .markPriceFn = testBtcMark,
        .now_ms = 0,
    };

    const margin_engine = margin_mod.MarginEngine.init(.{});
    var engine = TransferEngine.init(alloc);

    try std.testing.expectError(
        error.TransferWouldBreachMarginFloor,
        engine.executeIntraMaster(&margin_engine, 0, 1, types.USDC_ID, 200 * types.USDC, &master, &state),
    );

    // Atomic rollback: source balance unchanged
    try std.testing.expectEqual(3_000 * types.USDC, sub0.collateral.rawBalance(types.USDC_ID));
}

test "withdrawal - rejected if would breach transfer margin floor" {
    const alloc = std.testing.allocator;
    const master_addr = [_]u8{0xAA} ** 20;
    var master = account.MasterAccount.init(alloc, master_addr, 0);
    defer master.deinit();

    _ = try master.openSubAccount(0, null, 0);

    const sub0 = master.subAccountByIndex(0).?;
    try sub0.collateral.deposit(types.USDC_ID, 3_000 * types.USDC, &types.defaultCollateralRegistry);

    // Create a position
    try sub0.positions.put(1, .{
        .instrument_id = 1,
        .kind = .{ .perp = .{
            .tick_size = 1,
            .lot_size = 1,
            .max_leverage = 50,
            .funding_interval_ms = 3_600_000,
            .mark_method = .oracle,
            .isolated_only = false,
        } },
        .user = sub0.address,
        .size = 1,
        .side = .long,
        .entry_price = test_btc_mark,
        .realized_pnl = 0,
        .leverage = 10,
        .margin_mode = .cross,
        .isolated_margin = 0,
        .funding_index = 0,
        .delta = 0,
        .gamma = 0,
        .vega = 0,
        .theta = 0,
    });

    const state = margin_mod.GlobalState{
        .markPriceFn = testBtcMark,
        .now_ms = 0,
    };

    const margin_engine = margin_mod.MarginEngine.init(.{});
    var engine = TransferEngine.init(alloc);

    try std.testing.expectError(
        error.TransferWouldBreachMarginFloor,
        engine.executeWithdrawal(&margin_engine, 0, types.USDC_ID, 200 * types.USDC, [_]u8{0xBB} ** 20, &master, &state),
    );
}

test "deposit - credits sub-account balance" {
    const alloc = std.testing.allocator;
    const master_addr = [_]u8{0xAA} ** 20;
    var master = account.MasterAccount.init(alloc, master_addr, 0);
    defer master.deinit();

    _ = try master.openSubAccount(0, null, 0);
    const sub0 = master.subAccountByIndex(0).?;

    const state = margin_mod.GlobalState{
        .markPriceFn = struct {
            fn mark(_: types.InstrumentId) ?shared.types.Price {
                return null;
            }
        }.mark,
        .now_ms = 0,
    };

    const margin_engine = margin_mod.MarginEngine.init(.{});
    var engine = TransferEngine.init(alloc);

    const event = try engine.executeDeposit(0, types.USDC_ID, 5_000 * types.USDC, &master, &state);

    try std.testing.expect(std.mem.eql(u8, &event.to_addr, &sub0.address));
    try std.testing.expect(event.amount == 5_000 * types.USDC);
    try std.testing.expectEqual(5_000 * types.USDC, sub0.collateral.rawBalance(types.USDC_ID));
    _ = margin_engine;
}
