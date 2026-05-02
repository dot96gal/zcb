//! allow / done を使った Two-Step パターンの例。
//! リクエスト開始と完了が分離している場合（HTTP ミドルウェア等）に使用する。
const std = @import("std");
const zcb = @import("zcb");

const call_count = struct {
    var value: u32 = 0;
};

fn sendRequest() bool {
    call_count.value += 1;
    // 最初の 2 回は失敗（HTTP 5xx 相当）、それ以降は成功
    return call_count.value > 2;
}

pub fn main(env: std.process.Init) !void {
    const io = env.io;

    var buf: [4096]u8 = undefined;
    var file_writer = std.Io.File.Writer.init(.stdout(), io, &buf);
    const stdout = &file_writer.interface;

    var cb = zcb.CircuitBreaker.init(.{
        .name = "http-backend",
        .ready_to_trip = struct {
            fn call(counts: zcb.Counts) bool {
                return counts.consecutive_failures >= 2;
            }
        }.call,
    });

    // 1回目: allow → 失敗 → done(false)
    {
        const token = cb.allow(io) catch |err| {
            try stdout.print("request 1 blocked: {}\n", .{err});
            try stdout.flush();
            return;
        };
        const ok = sendRequest();
        token.done(io, ok);
        try stdout.print("request 1: success={}\n", .{ok});
    }
    try stdout.print("state: {s}\n\n", .{@tagName(cb.getState(io))});

    // 2回目: allow → 失敗 → done(false) → ready_to_trip 発火 → Open 遷移
    {
        const token = cb.allow(io) catch |err| {
            try stdout.print("request 2 blocked: {}\n", .{err});
            try stdout.flush();
            return;
        };
        const ok = sendRequest();
        token.done(io, ok);
        try stdout.print("request 2: success={}\n", .{ok});
    }
    try stdout.print("state: {s}\n\n", .{@tagName(cb.getState(io))});

    // 3〜5回目: Open 状態なので allow が error.OpenState を返す（サービスを呼ばない）
    var i: u32 = 3;
    while (i <= 5) : (i += 1) {
        const token = cb.allow(io) catch |err| {
            try stdout.print("request {d} blocked: {}\n", .{ i, err });
            continue;
        };
        const ok = sendRequest();
        token.done(io, ok);
        try stdout.print("request {d}: success={}\n", .{ i, ok });
    }
    try stdout.print("state: {s}\n\n", .{@tagName(cb.getState(io))});

    // call_count はサービスが実際に呼ばれた回数（Open 中は呼ばれない）
    try stdout.print("actual service calls: {d}\n", .{call_count.value});

    try stdout.flush();
}
