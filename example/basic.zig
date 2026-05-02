//! execute を使ったサーキットブレーカーの基本例。
//! 外部サービス呼び出しを CircuitBreaker.execute でラップする。
const std = @import("std");
const zcb = @import("zcb");

const call_count = struct {
    var value: u32 = 0;
};

fn callExternalService() anyerror![]const u8 {
    call_count.value += 1;
    // 最初の 3 回は失敗、それ以降は成功するダミー実装
    if (call_count.value <= 3) return error.ServiceUnavailable;
    return "OK";
}

const FetchReq = struct {
    pub fn call(self: *@This()) anyerror![]const u8 {
        _ = self;
        return callExternalService();
    }
};

pub fn main(env: std.process.Init) !void {
    const io = env.io;

    var buf: [4096]u8 = undefined;
    var file_writer = std.Io.File.Writer.init(.stdout(), io, &buf);
    const stdout = &file_writer.interface;

    var cb = zcb.CircuitBreaker.init(.{
        .name = "external-service",
        .ready_to_trip = struct {
            fn call(counts: zcb.Counts) bool {
                return counts.consecutive_failures >= 2;
            }
        }.call,
    });

    var req = FetchReq{};

    // 1回目: 失敗（consecutive_failures=1、まだ Closed）
    if (cb.execute(io, []const u8, &req)) |result| {
        try stdout.print("attempt 1: {s}\n", .{result});
    } else |err| {
        try stdout.print("attempt 1 error: {}\n", .{err});
    }
    try stdout.print("state: {s}\n\n", .{@tagName(cb.getState(io))});

    // 2回目: 失敗 → ready_to_trip 発火 → Open 遷移
    if (cb.execute(io, []const u8, &req)) |result| {
        try stdout.print("attempt 2: {s}\n", .{result});
    } else |err| {
        try stdout.print("attempt 2 error: {}\n", .{err});
    }
    try stdout.print("state: {s}\n\n", .{@tagName(cb.getState(io))});

    // 3〜5回目: Open 状態なので即 error.OpenState（サービスを呼ばない）
    var i: u32 = 3;
    while (i <= 5) : (i += 1) {
        if (cb.execute(io, []const u8, &req)) |result| {
            try stdout.print("attempt {d}: {s}\n", .{ i, result });
        } else |err| {
            try stdout.print("attempt {d} error: {}\n", .{ i, err });
        }
    }
    try stdout.print("state: {s}\n\n", .{@tagName(cb.getState(io))});

    // call_count はサービスが実際に呼ばれた回数（Open 中は呼ばれない）
    try stdout.print("actual service calls: {d}\n", .{call_count.value});

    try stdout.flush();
}
