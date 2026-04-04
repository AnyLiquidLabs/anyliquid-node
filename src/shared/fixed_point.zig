const std = @import("std");
const types = @import("types.zig");

pub const PRICE_DECIMALS: types.Price = types.PRICE_SCALE;
pub const QUANTITY_DECIMALS: types.Quantity = 1;

pub fn priceFromWhole(value: u128) types.Price {
    return @as(types.Price, value) * PRICE_DECIMALS;
}

pub fn quantityFromWhole(value: u128) types.Quantity {
    return @as(types.Quantity, value);
}

pub fn mulPriceQty(price: types.Price, qty: types.Quantity) types.Quantity {
    const result = @as(u512, price) * @as(u512, qty);
    return @intCast(result / PRICE_DECIMALS);
}

test "fixed-point helpers preserve scaling expectations" {
    try std.testing.expectEqual(types.PRICE_SCALE * 3, priceFromWhole(3));
    try std.testing.expectEqual(@as(types.Quantity, 2), quantityFromWhole(2));
    try std.testing.expectEqual(@as(types.Quantity, 6), mulPriceQty(priceFromWhole(3), quantityFromWhole(2)));
}
