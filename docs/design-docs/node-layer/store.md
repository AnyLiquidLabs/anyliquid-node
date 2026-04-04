# Module: Store

**File:** `src/node/store/`  
**Depends on:** `shared/types`

## Responsibilities

- Persist committed blocks in an append-only WAL
- Maintain a sparse Merkle tree for account and position state
- Maintain indexed history for fills, funding, and orders
- Recover memory state from persistent data after restart

## Interface

```zig
pub const Store = struct {
    pub fn init(cfg: StoreConfig, alloc: std.mem.Allocator) !Store
    pub fn deinit(self: *Store) void
    pub fn commitBlock(self: *Store, block: Block, state_diff: StateDiff) !void
    pub fn getBlock(self: *Store, height: u64) !?Block
    pub fn getStateProof(self: *Store, key: StateKey) !MerkleProof
    pub fn getFills(self: *Store, user: Address, since: i64) ![]Fill
    pub fn latestStateRoot(self: *Store) [32]u8
    pub fn latestHeight(self: *Store) u64
};
```

## Sparse Merkle Tree

```zig
pub const SMT = struct {
    pub fn update(self: *SMT, key: [32]u8, value: []u8) !void
    pub fn root(self: *SMT) [32]u8
    pub fn proof(self: *SMT, key: [32]u8) !MerkleProof
};
```

Leaf keys are `hash(address ++ asset_id)`. Leaf values are the encoded account or position state.

## Test Harness

```zig
test "committed block is retrievable by height" {
    var store = try Store.initTemp(alloc);
    defer store.deinit();

    try store.commitBlock(sample_block_1, sample_diff_1);
    const got = try store.getBlock(1);
    try std.testing.expectEqual(sample_block_1.hash(), got.?.hash());
}

test "state root changes after an update" {
    var store = try Store.initTemp(alloc);
    defer store.deinit();

    const root_before = store.latestStateRoot();
    try store.commitBlock(sample_block_with_trades, sample_diff);
    const root_after = store.latestStateRoot();

    try std.testing.expect(!std.mem.eql(u8, &root_before, &root_after));
}

test "Merkle proof verifies correctly" {
    var store = try Store.initTemp(alloc);
    defer store.deinit();

    try store.commitBlock(sample_block, sample_diff);
    const proof = try store.getStateProof(test_account_key);
    try std.testing.expect(smt.verifyProof(store.latestStateRoot(), test_account_key, proof));
}

test "restart recovery restores state from the WAL" {
    const tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    {
        var store = try Store.init(.{ .dir = tmp_dir.path }, alloc);
        try store.commitBlock(sample_block_1, sample_diff_1);
        try store.commitBlock(sample_block_2, sample_diff_2);
        store.deinit();
    }

    var store2 = try Store.init(.{ .dir = tmp_dir.path }, alloc);
    defer store2.deinit();
    try std.testing.expectEqual(2, store2.latestHeight());
}
```
