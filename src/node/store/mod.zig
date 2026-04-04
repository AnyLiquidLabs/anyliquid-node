const std = @import("std");
const shared = @import("../../shared/mod.zig");

pub const StoreConfig = struct {
    data_dir: []const u8 = "var/data",
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    cfg: StoreConfig,
    blocks: std.ArrayList(shared.types.Block),
    pending_txs: std.ArrayList(shared.types.Transaction),
    pending_log_path: []const u8,
    blocks_log_path: []const u8,
    latest_root: [32]u8 = [_]u8{0} ** 32,

    pub fn init(cfg: StoreConfig, allocator: std.mem.Allocator) !Store {
        try std.fs.cwd().makePath(cfg.data_dir);

        const pending_log_path = try std.fmt.allocPrint(allocator, "{s}/pending-txs.bin", .{cfg.data_dir});
        errdefer allocator.free(pending_log_path);
        const blocks_log_path = try std.fmt.allocPrint(allocator, "{s}/blocks.bin", .{cfg.data_dir});
        errdefer allocator.free(blocks_log_path);

        var store = Store{
            .allocator = allocator,
            .cfg = cfg,
            .blocks = .empty,
            .pending_txs = .empty,
            .pending_log_path = pending_log_path,
            .blocks_log_path = blocks_log_path,
        };
        errdefer store.deinit();

        try store.loadPendingLog();
        try store.loadBlocksLog();
        return store;
    }

    pub fn deinit(self: *Store) void {
        for (self.pending_txs.items) |*tx| {
            shared.serialization.deinitTransaction(self.allocator, tx);
        }
        for (self.blocks.items) |*block| {
            shared.serialization.deinitBlock(self.allocator, block);
        }
        self.pending_txs.deinit(self.allocator);
        self.blocks.deinit(self.allocator);
        self.allocator.free(self.pending_log_path);
        self.allocator.free(self.blocks_log_path);
    }

    pub fn appendPendingTransaction(self: *Store, tx: shared.types.Transaction) !void {
        const encoded = try shared.serialization.encodeTransaction(self.allocator, tx);
        defer self.allocator.free(encoded);
        try self.appendRecord(self.pending_log_path, encoded);

        var owned = try shared.serialization.cloneTransaction(self.allocator, tx);
        errdefer shared.serialization.deinitTransaction(self.allocator, &owned);
        try self.pending_txs.append(self.allocator, owned);
    }

    pub fn pendingTransactions(self: *const Store) []const shared.types.Transaction {
        return self.pending_txs.items;
    }

    pub fn removePendingTransactions(self: *Store, txs: []const shared.types.Transaction) !void {
        for (txs) |confirmed| {
            var idx: usize = 0;
            while (idx < self.pending_txs.items.len) {
                const candidate = self.pending_txs.items[idx];
                if (std.mem.eql(u8, candidate.user[0..], confirmed.user[0..]) and candidate.nonce == confirmed.nonce) {
                    var removed = self.pending_txs.swapRemove(idx);
                    shared.serialization.deinitTransaction(self.allocator, &removed);
                    break;
                }
                idx += 1;
            }
        }

        try self.rewritePendingLog();
    }

    pub fn commitBlock(self: *Store, block: shared.types.Block, state_diff: shared.types.StateDiff) !void {
        const encoded_block = try shared.serialization.encodeBlock(self.allocator, block);
        defer self.allocator.free(encoded_block);
        const encoded_diff = try shared.serialization.encodeStateDiff(self.allocator, state_diff);
        defer self.allocator.free(encoded_diff);

        var record = std.ArrayList(u8).empty;
        defer record.deinit(self.allocator);
        try appendLengthPrefixed(&record, self.allocator, encoded_block);
        try appendLengthPrefixed(&record, self.allocator, encoded_diff);
        const record_bytes = try record.toOwnedSlice(self.allocator);
        defer self.allocator.free(record_bytes);
        try self.appendRecord(self.blocks_log_path, record_bytes);

        var owned = try shared.serialization.cloneBlock(self.allocator, block);
        errdefer shared.serialization.deinitBlock(self.allocator, &owned);
        try self.blocks.append(self.allocator, owned);
        self.latest_root = block.state_root;
    }

    pub fn getBlock(self: *const Store, height: u64) !?shared.types.Block {
        for (self.blocks.items) |block| {
            if (block.height == height) {
                return block;
            }
        }
        return null;
    }

    pub fn getStateProof(self: *const Store, key: shared.types.StateKey) !shared.types.MerkleProof {
        _ = self;
        _ = key;
        return .{ .siblings = &.{} };
    }

    pub fn getFills(self: *const Store, user: shared.types.Address, since: i64) ![]const shared.types.Fill {
        _ = self;
        _ = user;
        _ = since;
        return &.{};
    }

    pub fn latestStateRoot(self: *const Store) [32]u8 {
        return self.latest_root;
    }

    pub fn latestHeight(self: *const Store) u64 {
        if (self.blocks.items.len == 0) return 0;
        return self.blocks.items[self.blocks.items.len - 1].height;
    }

    fn loadPendingLog(self: *Store) !void {
        const data = self.readFileIfPresent(self.pending_log_path) orelse return;
        defer self.allocator.free(data);

        var index: usize = 0;
        while (index < data.len) {
            const payload = try readLengthPrefixed(data, &index);
            var tx = try shared.serialization.decodeTransaction(self.allocator, payload);
            errdefer shared.serialization.deinitTransaction(self.allocator, &tx);
            try self.pending_txs.append(self.allocator, tx);
        }
    }

    fn loadBlocksLog(self: *Store) !void {
        const data = self.readFileIfPresent(self.blocks_log_path) orelse return;
        defer self.allocator.free(data);

        var index: usize = 0;
        while (index < data.len) {
            const record = try readLengthPrefixed(data, &index);
            var record_index: usize = 0;
            const block_payload = try readLengthPrefixed(record, &record_index);
            _ = try readLengthPrefixed(record, &record_index);

            var block = try shared.serialization.decodeBlock(self.allocator, block_payload);
            errdefer shared.serialization.deinitBlock(self.allocator, &block);
            try self.blocks.append(self.allocator, block);
            self.latest_root = block.state_root;
        }
    }

    fn appendRecord(_: *Store, path: []const u8, payload: []const u8) !void {
        var file = try std.fs.cwd().createFile(path, .{ .truncate = false, .read = true });
        defer file.close();
        try file.seekFromEnd(0);

        var prefix: [4]u8 = undefined;
        std.mem.writeInt(u32, &prefix, @intCast(payload.len), .little);
        try file.writeAll(prefix[0..]);
        try file.writeAll(payload);
    }

    fn readFileIfPresent(self: *Store, path: []const u8) ?[]u8 {
        var file = std.fs.cwd().openFile(path, .{}) catch return null;
        defer file.close();
        return file.readToEndAlloc(self.allocator, std.math.maxInt(usize)) catch null;
    }

    fn rewritePendingLog(self: *Store) !void {
        var file = try std.fs.cwd().createFile(self.pending_log_path, .{ .truncate = true, .read = true });
        defer file.close();

        for (self.pending_txs.items) |tx| {
            const encoded = try shared.serialization.encodeTransaction(self.allocator, tx);
            defer self.allocator.free(encoded);

            var prefix: [4]u8 = undefined;
            std.mem.writeInt(u32, &prefix, @intCast(encoded.len), .little);
            try file.writeAll(prefix[0..]);
            try file.writeAll(encoded);
        }
    }
};

fn appendLengthPrefixed(list: *std.ArrayList(u8), allocator: std.mem.Allocator, payload: []const u8) !void {
    var prefix: [4]u8 = undefined;
    std.mem.writeInt(u32, &prefix, @intCast(payload.len), .little);
    try list.appendSlice(allocator, prefix[0..]);
    try list.appendSlice(allocator, payload);
}

fn readLengthPrefixed(bytes: []const u8, index: *usize) ![]const u8 {
    if (index.* + 4 > bytes.len) return error.UnexpectedEndOfStream;
    const len = std.mem.readInt(u32, bytes[index.* ..][0..4], .little);
    index.* += 4;
    if (index.* + len > bytes.len) return error.UnexpectedEndOfStream;
    defer index.* += len;
    return bytes[index.* ..][0..len];
}
