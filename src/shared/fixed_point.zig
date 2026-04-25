const std = @import("std");
const types = @import("types.zig");

pub const PRICE_DECIMALS: types.Price = types.PRICE_SCALE;
pub const QUANTITY_DECIMALS: types.Quantity = 1;

pub fn priceFromWhole(value: i64) types.Price {
    return value * PRICE_DECIMALS;
}

pub fn quantityFromWhole(value: u64) types.Quantity {
    return value;
}

pub fn mulPriceQty(price: types.Price, qty: types.Quantity) types.Quantity {
    std.debug.assert(price >= 0);
    const result = @as(u128, @intCast(price)) * @as(u128, qty);
    return @intCast(result / @as(u128, @intCast(PRICE_DECIMALS)));
}

test "fixed-point helpers preserve scaling expectations" {
    try std.testing.expectEqual(types.PRICE_SCALE * 3, priceFromWhole(3));
    try std.testing.expectEqual(@as(types.Quantity, 2), quantityFromWhole(2));
    try std.testing.expectEqual(@as(types.Quantity, 6), mulPriceQty(priceFromWhole(3), quantityFromWhole(2)));
}
