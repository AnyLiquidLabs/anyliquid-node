const std = @import("std");
const types = @import("types.zig");

pub const IpcFrameHeader = packed struct {
    len: u32,
    msg_id: u32,
    msg_type: u8,
};

pub const MsgType = enum(u8) {
    action_req = 0x01,
    query_req = 0x02,

    action_ack = 0x81,
    query_resp = 0x82,
    error_resp = 0x8F,

    event_l2_book = 0xA1,
    event_trades = 0xA2,
    event_all_mids = 0xA3,
    event_order_upd = 0xA4,
    event_user = 0xA5,
    event_fill = 0xA6,
    event_liquidation = 0xA7,
    event_funding = 0xA8,
};

pub const ActionRequest = struct {
    action: types.ActionPayload,
    nonce: u64,
    signature: types.EIP712Signature,
    user: types.Address,
};

pub const QueryRequest = union(enum) {
    user_state: types.Address,
    open_orders: types.Address,
    l2_book: struct { asset_id: types.AssetId, depth: u32 },
    all_mids: void,
};

pub const ActionAck = struct {
    status: types.OrderStatus,
    order_id: ?u64,
    error_msg: ?[]const u8,
};

pub const QueryResponse = union(enum) {
    user_state: types.AccountState,
    open_orders: []const u64,
    l2_book: types.L2Snapshot,
    all_mids: types.AllMidsUpdate,
    not_found: void,
};

pub const NodeEvent = union(enum) {
    l2_book_update: types.L2BookUpdate,
    trade: types.Fill,
    all_mids: types.AllMidsUpdate,
    order_update: types.OrderUpdate,
    user_update: types.AccountState,
    liquidation: types.LiquidationEvent,
    funding: types.FundingEvent,
};

test "frame header carries protocol metadata" {
    const header = IpcFrameHeader{
        .len = 64,
        .msg_id = 7,
        .msg_type = @intFromEnum(MsgType.action_req),
    };

    try std.testing.expectEqual(@as(u32, 64), header.len);
    try std.testing.expectEqual(@as(u32, 7), header.msg_id);
}
