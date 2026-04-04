# Module: Oracle Aggregator

**File:** `src/node/oracle/`  
**Depends on:** `net`, `shared/types`, `shared/crypto`

## Responsibilities

- Collect external price submissions from validators
- Aggregate prices with a median-based approach that resists manipulation
- Maintain the latest index price per asset
- Refresh prices at least once per block

## Interface

```zig
pub const Oracle = struct {
    submissions:   std.AutoHashMap(Address, OracleSubmission),
    validator_set: *ValidatorSet,

    pub fn init(validator_set: *ValidatorSet, alloc: std.mem.Allocator) Oracle
    pub fn submitPrices(self: *Oracle, from: Address, prices: []AssetPrice, sig: BlsSignature) !void
    pub fn aggregate(self: *Oracle) ![]AssetPrice
    pub fn hasSubmitted(self: *Oracle, validator: Address) bool
};

pub const OracleSubmission = struct {
    validator: Address,
    prices:    []AssetPrice,
    timestamp: i64,
    signature: BlsSignature,
};

pub const AssetPrice = struct {
    asset_id: u32,
    price:    Price,
};
```

## Aggregation Algorithm

```zig
pub fn aggregate(self: *Oracle) ![]AssetPrice {
    // 1. only keep assets with at least 2/3 validator participation
    // 2. sort prices per asset
    // 3. compute a weighted median by validator voting weight
    // 4. drop outliers that deviate by more than 2% from the median

    for (asset_ids) |asset_id| {
        var prices_for_asset: []f64 = ...;
        std.sort.sort(f64, prices_for_asset, {}, std.sort.asc(f64));
        result[asset_id] = weightedMedian(prices_for_asset, weights);
    }
}
```

## Test Harness

```zig
test "five validator submissions produce the median" {
    var oracle = Oracle.init(&test_validator_set, alloc);

    oracle.submitPrices(v1, &.{.{ .asset_id = 0, .price = 50100 }}, sig1);
    oracle.submitPrices(v2, &.{.{ .asset_id = 0, .price = 50000 }}, sig2);
    oracle.submitPrices(v3, &.{.{ .asset_id = 0, .price = 49900 }}, sig3);
    oracle.submitPrices(v4, &.{.{ .asset_id = 0, .price = 50050 }}, sig4);
    oracle.submitPrices(v5, &.{.{ .asset_id = 0, .price = 50000 }}, sig5);

    const result = try oracle.aggregate();
    try std.testing.expectEqual(50000, result[0].price);
}

test "outlier submission is filtered before the median" {
    var oracle = Oracle.init(&test_validator_set, alloc);

    oracle.submitPrices(v1, &.{.{ .asset_id = 0, .price = 50000 }}, sig1);
    oracle.submitPrices(v2, &.{.{ .asset_id = 0, .price = 50000 }}, sig2);
    oracle.submitPrices(v3, &.{.{ .asset_id = 0, .price = 50000 }}, sig3);
    oracle.submitPrices(v4, &.{.{ .asset_id = 0, .price = 99999 }}, sig4);
    oracle.submitPrices(v5, &.{.{ .asset_id = 0, .price = 50000 }}, sig5);

    const result = try oracle.aggregate();
    try std.testing.expect(result[0].price < 51000);
}

test "invalid signature rejects the submission" {
    var oracle = Oracle.init(&test_validator_set, alloc);

    try std.testing.expectError(
        error.InvalidSignature,
        oracle.submitPrices(v1, &sample_prices, bad_signature),
    );
}
```
