const std = @import("std");

/// デフォルトの連続失敗閾値。ready_to_trip が null の場合、consecutive_failures がこの値を超えたとき Open に遷移する。
pub const default_consecutive_failures_threshold: u32 = 5;

/// 時刻取得の抽象インターフェース。Clock.system（本番）と TestClock（テスト）で差し替えて使用する。
pub const Clock = struct {
    context: ?*anyopaque,
    now_fn: *const fn (context: ?*anyopaque, io: std.Io) std.Io.Timestamp,

    /// システム時刻を使うデフォルト実装。
    pub const system: Clock = .{
        .context = null,
        .now_fn = struct {
            fn now(_: ?*anyopaque, io: std.Io) std.Io.Timestamp {
                return std.Io.Clock.awake.now(io);
            }
        }.now,
    };

    pub fn now(self: Clock, io: std.Io) std.Io.Timestamp {
        return self.now_fn(self.context, io);
    }
};

pub const State = enum {
    closed,
    half_open,
    open,
};

pub const Counts = struct {
    requests: u64 = 0,
    total_successes: u64 = 0,
    total_failures: u64 = 0,
    consecutive_successes: u32 = 0,
    consecutive_failures: u32 = 0,
};

pub const Error = error{
    OpenState,
    TooManyRequests,
};

pub const StateChangeCallback = struct {
    context: ?*anyopaque = null,
    call_fn: *const fn (context: ?*anyopaque, name: []const u8, from: State, to: State) void,

    pub fn call(self: StateChangeCallback, name: []const u8, from: State, to: State) void {
        self.call_fn(self.context, name, from, to);
    }
};

pub const Config = struct {
    name: []const u8 = "",
    /// 0 指定時は init() 内で 1 に正規化される。
    max_requests: u32 = 1,
    /// 0 で無効（Closed 状態でカウンターをリセットしない）。
    interval_ns: u64 = 0,
    /// 0 で即時 Half-Open 遷移。
    timeout_ns: u64 = 60 * std.time.ns_per_s,
    /// null 時は consecutive_failures > default_consecutive_failures_threshold をデフォルト条件として使用する。
    ready_to_trip: ?*const fn (counts: Counts) bool = null,
    /// null 時はすべてのエラーを失敗と判定する。
    is_successful: ?*const fn (err: anyerror) bool = null,
    on_state_change: ?StateChangeCallback = null,
    clock: Clock = Clock.system,
};

/// allow() の呼び出し後にリクエスト結果を報告するためのトークン。
/// リクエスト開始と完了の分離が不要な場合は execute() を優先すること。
pub const AllowToken = struct {
    cb: *CircuitBreaker,
    generation: u64,

    /// リクエスト結果を報告する。success = true で成功、false で失敗として記録する。
    /// allow() の後に必ず 1 回呼ぶこと（`defer token.done(io, false)` パターン推奨）。
    /// 二重呼び出しは generation 不一致でスキップされる（べき等）。
    pub fn done(self: AllowToken, io: std.Io, success: bool) void {
        self.cb.afterRequest(io, self.generation, success);
    }
};

/// 外部サービス呼び出しの障害伝播を防ぐサーキットブレーカー。
pub const CircuitBreaker = struct {
    config: Config,
    mutex: std.Io.Mutex = .init,
    state: State = .closed,
    generation: u64 = 0,
    counts: Counts = .{},
    expiry: std.Io.Timestamp = .{ .nanoseconds = 0 },

    pub fn init(config: Config) CircuitBreaker {
        var cfg = config;
        if (cfg.max_requests == 0) cfg.max_requests = 1;
        return .{ .config = cfg };
    }

    pub fn getName(self: *const CircuitBreaker) []const u8 {
        return self.config.name;
    }

    /// 現在の状態を返す。Open 状態でタイムアウトが経過している場合は Half-Open へ遷移させる（副作用あり）。スレッドセーフ。
    pub fn getState(self: *CircuitBreaker, io: std.Io) State {
        var cr = TransitionResult{};
        const state = lock_blk: {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            cr = self.currentState(io);
            break :lock_blk self.state;
        };
        self.notifyStateChange(cr.prev_state, cr.next_state);
        return state;
    }

    /// スレッドセーフ。
    pub fn getCounts(self: *CircuitBreaker, io: std.Io) Counts {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.counts;
    }

    /// リクエストをサーキットブレーカー経由で実行する。スレッドセーフ。
    /// req は `pub fn call(self: *@This()) anyerror!T` を実装していること。
    pub fn execute(
        self: *CircuitBreaker,
        io: std.Io,
        comptime T: type,
        req: anytype,
    ) anyerror!T {
        if (!@hasDecl(@TypeOf(req.*), "call")) {
            @compileError("req must have pub fn call(self: *@This()) anyerror!T");
        }

        const br = before_req: {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            break :before_req self.beforeRequest(io);
        };
        const gen = br.generation;

        self.notifyStateChange(br.prev_state, br.next_state);

        if (br.err) |err| return err;

        const result = req.call();

        const ar = after_req: {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            const success = if (result) |_| true else |err| is_success: {
                if (self.config.is_successful) |f| break :is_success f(err);
                break :is_success false;
            };
            break :after_req self.afterRequestLocked(io, gen, success);
        };

        self.notifyStateChange(ar.prev_state, ar.next_state);

        return result;
    }

    /// Two-Step パターンでリクエスト許可を判定し、結果報告用トークンを返す。スレッドセーフ。
    /// リクエスト開始と完了の分離が不要な場合は execute() を優先すること。
    pub fn allow(self: *CircuitBreaker, io: std.Io) Error!AllowToken {
        const br = before_req: {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            break :before_req self.beforeRequest(io);
        };

        self.notifyStateChange(br.prev_state, br.next_state);

        if (br.err) |err| return err;
        return AllowToken{ .cb = self, .generation = br.generation };
    }

    // --- 内部ヘルパー ---

    fn notifyStateChange(self: *CircuitBreaker, prev_state: ?State, next_state: ?State) void {
        if (next_state) |ns| {
            if (prev_state) |ps| {
                if (self.config.on_state_change) |cb| {
                    cb.call(self.config.name, ps, ns);
                }
            }
        }
    }

    const TransitionResult = struct {
        prev_state: ?State = null,
        next_state: ?State = null,
    };

    // mutex 保持中に呼ぶこと
    fn currentState(self: *CircuitBreaker, io: std.Io) TransitionResult {
        switch (self.state) {
            .closed => {
                if (self.config.interval_ns > 0) {
                    const now = self.config.clock.now(io);
                    if (self.expiry.nanoseconds == 0) {
                        // init 時に io がないため初回アクセス時に expiry を初期化する
                        // std.Io.Timestamp.nanoseconds が i96 のため演算も i96 を使う。
                        const ns: i96 = @as(i96, @intCast(self.config.interval_ns));
                        self.expiry = .{ .nanoseconds = now.nanoseconds + ns };
                    } else if (now.nanoseconds >= self.expiry.nanoseconds) {
                        self.toNewGeneration(io);
                    }
                }
                return .{};
            },
            .open => {
                const now = self.config.clock.now(io);
                if (now.nanoseconds >= self.expiry.nanoseconds) {
                    const prev = self.state;
                    self.state = .half_open;
                    self.toNewGeneration(io);
                    return .{ .prev_state = prev, .next_state = .half_open };
                }
                return .{};
            },
            .half_open => return .{},
        }
    }

    // mutex 保持中に呼ぶこと
    fn toNewGeneration(self: *CircuitBreaker, io: std.Io) void {
        self.generation +%= 1;
        self.counts = .{};
        const now = self.config.clock.now(io);
        switch (self.state) {
            .closed => {
                if (self.config.interval_ns == 0) {
                    self.expiry = .{ .nanoseconds = 0 };
                } else {
                    const ns: i96 = @as(i96, @intCast(self.config.interval_ns));
                    self.expiry = .{ .nanoseconds = now.nanoseconds + ns };
                }
            },
            .open, .half_open => {
                const ns: i96 = @as(i96, @intCast(self.config.timeout_ns));
                self.expiry = .{ .nanoseconds = now.nanoseconds + ns };
            },
        }
    }

    const BeforeRequestResult = struct {
        generation: u64,
        err: ?Error = null,
        prev_state: ?State = null,
        next_state: ?State = null,
    };

    // mutex 保持中に呼ぶこと
    fn beforeRequest(self: *CircuitBreaker, io: std.Io) BeforeRequestResult {
        const cr = self.currentState(io);
        switch (self.state) {
            .open => {
                return .{
                    .generation = self.generation,
                    .err = error.OpenState,
                    .prev_state = cr.prev_state,
                    .next_state = cr.next_state,
                };
            },
            .half_open => {
                if (self.counts.requests >= self.config.max_requests) {
                    return .{
                        .generation = self.generation,
                        .err = error.TooManyRequests,
                        .prev_state = cr.prev_state,
                        .next_state = cr.next_state,
                    };
                }
            },
            .closed => {},
        }
        self.counts.requests += 1;
        return .{
            .generation = self.generation,
            .prev_state = cr.prev_state,
            .next_state = cr.next_state,
        };
    }

    // mutex を持たずに呼ぶ（AllowToken.done から使用）
    fn afterRequest(self: *CircuitBreaker, io: std.Io, generation: u64, success: bool) void {
        const ar = after_req: {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            break :after_req self.afterRequestLocked(io, generation, success);
        };
        self.notifyStateChange(ar.prev_state, ar.next_state);
    }

    // mutex 保持中に呼ぶこと
    fn afterRequestLocked(self: *CircuitBreaker, io: std.Io, generation: u64, success: bool) TransitionResult {
        if (self.generation != generation) return .{};
        if (success) {
            self.counts.total_successes += 1;
            self.counts.consecutive_successes += 1;
            self.counts.consecutive_failures = 0;
        } else {
            self.counts.total_failures += 1;
            self.counts.consecutive_failures += 1;
            self.counts.consecutive_successes = 0;
        }
        return self.onRequest(io, success);
    }

    // mutex 保持中に呼ぶこと
    fn onRequest(self: *CircuitBreaker, io: std.Io, success: bool) TransitionResult {
        switch (self.state) {
            .closed => {
                if (!success) {
                    const should_trip = if (self.config.ready_to_trip) |f|
                        f(self.counts)
                    else
                        self.counts.consecutive_failures > default_consecutive_failures_threshold;
                    if (should_trip) {
                        const prev = self.state;
                        self.state = .open;
                        self.toNewGeneration(io);
                        return .{ .prev_state = prev, .next_state = .open };
                    }
                }
                return .{};
            },
            .half_open => {
                if (success) {
                    if (self.counts.consecutive_successes >= self.config.max_requests) {
                        const prev = self.state;
                        self.state = .closed;
                        self.toNewGeneration(io);
                        return .{ .prev_state = prev, .next_state = .closed };
                    }
                } else {
                    const prev = self.state;
                    self.state = .open;
                    self.toNewGeneration(io);
                    return .{ .prev_state = prev, .next_state = .open };
                }
                return .{};
            },
            .open => return .{},
        }
    }
};

/// テスト専用。本番コードでは使用しないこと。
pub const TestClock = struct {
    nanoseconds: i96 = 0,

    /// Config.clock に渡す Clock インターフェースを返す。
    pub fn clock(self: *TestClock) Clock {
        return .{
            .context = self,
            .now_fn = struct {
                fn now(ctx: ?*anyopaque, _: std.Io) std.Io.Timestamp {
                    const tc: *TestClock = @ptrCast(@alignCast(ctx.?));
                    return .{ .nanoseconds = tc.nanoseconds };
                }
            }.now,
        };
    }

    /// 現在時刻をナノ秒だけ進める。
    pub fn advance(self: *TestClock, ns: u64) void {
        self.nanoseconds += @as(i96, @intCast(ns));
    }
};

// --- テスト ---

test "init state is closed" {
    var tc = TestClock{};
    var cb = CircuitBreaker.init(.{ .clock = tc.clock() });
    try std.testing.expectEqual(State.closed, cb.getState(std.testing.io));
}

test "closed counts requests" {
    var tc = TestClock{};
    var cb = CircuitBreaker.init(.{ .clock = tc.clock() });
    const io = std.testing.io;

    const Req = struct {
        pub fn call(self: *@This()) anyerror!void {
            _ = self;
        }
    };
    var req = Req{};
    try cb.execute(io, void, &req);

    const counts = cb.getCounts(io);
    try std.testing.expectEqual(@as(u64, 1), counts.requests);
    try std.testing.expectEqual(@as(u64, 1), counts.total_successes);
}

test "closed to open on ready to trip" {
    var tc = TestClock{};
    var cb = CircuitBreaker.init(.{
        .clock = tc.clock(),
        .ready_to_trip = struct {
            fn f(counts: Counts) bool {
                return counts.consecutive_failures >= 2;
            }
        }.f,
    });
    const io = std.testing.io;

    const Req = struct {
        pub fn call(self: *@This()) anyerror!void {
            _ = self;
            return error.SomeError;
        }
    };
    var req = Req{};
    try std.testing.expectError(error.SomeError, cb.execute(io, void, &req));
    try std.testing.expectError(error.SomeError, cb.execute(io, void, &req));

    try std.testing.expectEqual(State.open, cb.getState(io));
}

test "open returns error.OpenState" {
    var tc = TestClock{};
    var cb = CircuitBreaker.init(.{
        .clock = tc.clock(),
        .ready_to_trip = struct {
            fn f(_: Counts) bool {
                return true;
            }
        }.f,
    });
    const io = std.testing.io;

    const Req = struct {
        pub fn call(self: *@This()) anyerror!void {
            _ = self;
            return error.SomeError;
        }
    };
    var req = Req{};
    try std.testing.expectError(error.SomeError, cb.execute(io, void, &req));

    try std.testing.expectEqual(State.open, cb.getState(io));
    try std.testing.expectError(error.OpenState, cb.execute(io, void, &req));
}

test "open to half-open after timeout" {
    var tc = TestClock{};
    var cb = CircuitBreaker.init(.{
        .clock = tc.clock(),
        .timeout_ns = 1000,
        .ready_to_trip = struct {
            fn f(_: Counts) bool {
                return true;
            }
        }.f,
    });
    const io = std.testing.io;

    const FailReq = struct {
        pub fn call(self: *@This()) anyerror!void {
            _ = self;
            return error.SomeError;
        }
    };
    var fail_req = FailReq{};
    try std.testing.expectError(error.SomeError, cb.execute(io, void, &fail_req));
    try std.testing.expectEqual(State.open, cb.getState(io));

    tc.advance(1001);
    try std.testing.expectEqual(State.half_open, cb.getState(io));
}

test "half-open to closed on max successes" {
    var tc = TestClock{};
    var cb = CircuitBreaker.init(.{
        .clock = tc.clock(),
        .timeout_ns = 1000,
        .max_requests = 2,
        .ready_to_trip = struct {
            fn f(_: Counts) bool {
                return true;
            }
        }.f,
    });
    const io = std.testing.io;

    const FailReq = struct {
        pub fn call(self: *@This()) anyerror!void {
            _ = self;
            return error.SomeError;
        }
    };
    const OkReq = struct {
        pub fn call(self: *@This()) anyerror!void {
            _ = self;
        }
    };

    var fail_req = FailReq{};
    try std.testing.expectError(error.SomeError, cb.execute(io, void, &fail_req));
    tc.advance(1001);

    var ok_req = OkReq{};
    try cb.execute(io, void, &ok_req);
    try std.testing.expectEqual(State.half_open, cb.getState(io));
    try cb.execute(io, void, &ok_req);
    try std.testing.expectEqual(State.closed, cb.getState(io));
}

test "half-open to open on failure" {
    var tc = TestClock{};
    var cb = CircuitBreaker.init(.{
        .clock = tc.clock(),
        .timeout_ns = 1000,
        .ready_to_trip = struct {
            fn f(_: Counts) bool {
                return true;
            }
        }.f,
    });
    const io = std.testing.io;

    const FailReq = struct {
        pub fn call(self: *@This()) anyerror!void {
            _ = self;
            return error.SomeError;
        }
    };
    var fail_req = FailReq{};
    try std.testing.expectError(error.SomeError, cb.execute(io, void, &fail_req));
    tc.advance(1001);

    try std.testing.expectEqual(State.half_open, cb.getState(io));
    try std.testing.expectError(error.SomeError, cb.execute(io, void, &fail_req));
    try std.testing.expectEqual(State.open, cb.getState(io));
}

test "half-open rejects excess requests" {
    var tc = TestClock{};
    var cb = CircuitBreaker.init(.{
        .clock = tc.clock(),
        .timeout_ns = 1000,
        .max_requests = 1,
        .ready_to_trip = struct {
            fn f(_: Counts) bool {
                return true;
            }
        }.f,
    });
    const io = std.testing.io;

    const FailReq = struct {
        pub fn call(self: *@This()) anyerror!void {
            _ = self;
            return error.SomeError;
        }
    };
    var fail_req = FailReq{};
    try std.testing.expectError(error.SomeError, cb.execute(io, void, &fail_req));
    tc.advance(1001);

    var token = try cb.allow(io);
    try std.testing.expectError(error.TooManyRequests, cb.allow(io));
    token.done(io, true);
}

test "closed interval resets counts" {
    var tc = TestClock{};
    var cb = CircuitBreaker.init(.{
        .clock = tc.clock(),
        .interval_ns = 1000,
    });
    const io = std.testing.io;

    const FailReq = struct {
        pub fn call(self: *@This()) anyerror!void {
            _ = self;
            return error.SomeError;
        }
    };
    var fail_req = FailReq{};
    try std.testing.expectError(error.SomeError, cb.execute(io, void, &fail_req));

    const counts_before = cb.getCounts(io);
    try std.testing.expectEqual(@as(u64, 1), counts_before.total_failures);

    tc.advance(1001);
    try std.testing.expectError(error.SomeError, cb.execute(io, void, &fail_req));
    const counts_after = cb.getCounts(io);
    try std.testing.expectEqual(@as(u64, 1), counts_after.total_failures);
}

test "custom ready to trip" {
    var tc = TestClock{};
    var cb = CircuitBreaker.init(.{
        .clock = tc.clock(),
        .ready_to_trip = struct {
            fn f(counts: Counts) bool {
                return counts.total_failures >= 3;
            }
        }.f,
    });
    const io = std.testing.io;

    const FailReq = struct {
        pub fn call(self: *@This()) anyerror!void {
            _ = self;
            return error.SomeError;
        }
    };
    var fail_req = FailReq{};
    try std.testing.expectError(error.SomeError, cb.execute(io, void, &fail_req));
    try std.testing.expectError(error.SomeError, cb.execute(io, void, &fail_req));
    try std.testing.expectEqual(State.closed, cb.getState(io));
    try std.testing.expectError(error.SomeError, cb.execute(io, void, &fail_req));
    try std.testing.expectEqual(State.open, cb.getState(io));
}

test "custom is successful" {
    var tc = TestClock{};
    var cb = CircuitBreaker.init(.{
        .clock = tc.clock(),
        .ready_to_trip = struct {
            fn f(_: Counts) bool {
                return true;
            }
        }.f,
        .is_successful = struct {
            fn f(err: anyerror) bool {
                return err == error.NotFound;
            }
        }.f,
    });
    const io = std.testing.io;

    const Req = struct {
        pub fn call(self: *@This()) anyerror!void {
            _ = self;
            return error.NotFound;
        }
    };
    var req = Req{};
    try std.testing.expectError(error.NotFound, cb.execute(io, void, &req));
    try std.testing.expectEqual(State.closed, cb.getState(io));
}

test "on state change called" {
    const Ctx = struct {
        called: bool = false,
        from: State = .closed,
        to: State = .closed,
    };
    var ctx = Ctx{};

    var tc = TestClock{};
    var cb = CircuitBreaker.init(.{
        .clock = tc.clock(),
        .ready_to_trip = struct {
            fn f(_: Counts) bool {
                return true;
            }
        }.f,
        .on_state_change = .{
            .context = &ctx,
            .call_fn = struct {
                fn f(context: ?*anyopaque, _: []const u8, from: State, to: State) void {
                    const c: *Ctx = @ptrCast(@alignCast(context.?));
                    c.called = true;
                    c.from = from;
                    c.to = to;
                }
            }.f,
        },
    });
    const io = std.testing.io;

    const FailReq = struct {
        pub fn call(self: *@This()) anyerror!void {
            _ = self;
            return error.SomeError;
        }
    };
    var fail_req = FailReq{};
    try std.testing.expectError(error.SomeError, cb.execute(io, void, &fail_req));
    try std.testing.expectEqual(State.open, cb.getState(io));
    try std.testing.expect(ctx.called);
    try std.testing.expectEqual(State.closed, ctx.from);
    try std.testing.expectEqual(State.open, ctx.to);
}

test "allow token done success" {
    var tc = TestClock{};
    var cb = CircuitBreaker.init(.{ .clock = tc.clock() });
    const io = std.testing.io;

    const token = try cb.allow(io);
    token.done(io, true);

    const counts = cb.getCounts(io);
    try std.testing.expectEqual(@as(u64, 1), counts.total_successes);
}

test "allow token done failure" {
    var tc = TestClock{};
    var cb = CircuitBreaker.init(.{ .clock = tc.clock() });
    const io = std.testing.io;

    const token = try cb.allow(io);
    token.done(io, false);

    const counts = cb.getCounts(io);
    try std.testing.expectEqual(@as(u64, 1), counts.total_failures);
}

test "default ready to trip" {
    var tc = TestClock{};
    var cb = CircuitBreaker.init(.{ .clock = tc.clock() });
    const io = std.testing.io;

    const FailReq = struct {
        pub fn call(self: *@This()) anyerror!void {
            _ = self;
            return error.SomeError;
        }
    };
    var fail_req = FailReq{};
    var i: u32 = 0;
    while (i <= default_consecutive_failures_threshold) : (i += 1) {
        try std.testing.expectError(error.SomeError, cb.execute(io, void, &fail_req));
    }
    try std.testing.expectEqual(State.open, cb.getState(io));
}

test "timeout zero transitions immediately" {
    var tc = TestClock{};
    var cb = CircuitBreaker.init(.{
        .clock = tc.clock(),
        .timeout_ns = 0,
        .ready_to_trip = struct {
            fn f(_: Counts) bool {
                return true;
            }
        }.f,
    });
    const io = std.testing.io;

    const FailReq = struct {
        pub fn call(self: *@This()) anyerror!void {
            _ = self;
            return error.SomeError;
        }
    };
    var fail_req = FailReq{};
    try std.testing.expectError(error.SomeError, cb.execute(io, void, &fail_req));

    try std.testing.expectEqual(State.half_open, cb.getState(io));
}

test "allow token done idempotent" {
    // 1回目の done() が Half-Open → Closed 遷移を起こし generation が変わる。
    // 2回目の done() は generation 不一致のためスキップされることを検証する。
    var tc = TestClock{};
    var cb = CircuitBreaker.init(.{
        .clock = tc.clock(),
        .timeout_ns = 1000,
        .max_requests = 1,
        .ready_to_trip = struct {
            fn f(_: Counts) bool {
                return true;
            }
        }.f,
    });
    const io = std.testing.io;

    const FailReq = struct {
        pub fn call(self: *@This()) anyerror!void {
            _ = self;
            return error.SomeError;
        }
    };
    var fail_req = FailReq{};
    try std.testing.expectError(error.SomeError, cb.execute(io, void, &fail_req));
    tc.advance(1001);

    // Half-Open 状態でトークンを取得（generation = A）
    const token = try cb.allow(io);
    // 1回目 done: Closed 遷移 → toNewGeneration → generation が A+1 に変化・counts リセット
    token.done(io, true);
    try std.testing.expectEqual(State.closed, cb.getState(io));
    // 2回目 done: generation 不一致のためスキップされる（counts に影響しない）
    token.done(io, true);
    // Closed 遷移後の新 generation では counts はリセット済みで total_successes = 0
    const counts = cb.getCounts(io);
    try std.testing.expectEqual(@as(u64, 0), counts.total_successes);
}

test "on state change callback fires" {
    const Ctx = struct {
        called: bool = false,
    };
    var ctx = Ctx{};

    var tc = TestClock{};
    var cb = CircuitBreaker.init(.{
        .clock = tc.clock(),
        .ready_to_trip = struct {
            fn f(_: Counts) bool {
                return true;
            }
        }.f,
        .on_state_change = .{
            .context = &ctx,
            .call_fn = struct {
                fn f(context: ?*anyopaque, _: []const u8, _: State, _: State) void {
                    const c: *Ctx = @ptrCast(@alignCast(context.?));
                    c.called = true;
                }
            }.f,
        },
    });
    const io = std.testing.io;

    const FailReq = struct {
        pub fn call(self: *@This()) anyerror!void {
            _ = self;
            return error.SomeError;
        }
    };
    var fail_req = FailReq{};
    try std.testing.expectError(error.SomeError, cb.execute(io, void, &fail_req));
    try std.testing.expect(ctx.called);
}

test "generation skips stale result" {
    var tc = TestClock{};
    var cb = CircuitBreaker.init(.{
        .clock = tc.clock(),
        .ready_to_trip = struct {
            fn f(_: Counts) bool {
                return true;
            }
        }.f,
    });
    const io = std.testing.io;

    const token = try cb.allow(io);

    // 別スレッドの失敗で Open 遷移 → generation が変わる
    const FailReq = struct {
        pub fn call(self: *@This()) anyerror!void {
            _ = self;
            return error.SomeError;
        }
    };
    var fail_req = FailReq{};
    try std.testing.expectError(error.SomeError, cb.execute(io, void, &fail_req));
    try std.testing.expectEqual(State.open, cb.getState(io));

    // 古い token の done は無視されること
    token.done(io, true);
    const counts = cb.getCounts(io);
    try std.testing.expectEqual(@as(u64, 0), counts.total_successes);
}

test "closed interval expiry initialized on first access" {
    // intervalNs > 0 かつ TestClock が非ゼロ時刻で開始した場合、
    // 初回アクセス時に expiry = now + interval_ns で初期化されることを検証する。
    var tc = TestClock{};
    tc.advance(500); // t=500
    var cb = CircuitBreaker.init(.{
        .clock = tc.clock(),
        .interval_ns = 1000,
    });
    const io = std.testing.io;

    const FailReq = struct {
        pub fn call(self: *@This()) anyerror!void {
            _ = self;
            return error.SomeError;
        }
    };
    var fail_req = FailReq{};

    // 初回アクセス: expiry = 500 + 1000 = 1500 に初期化される
    try std.testing.expectError(error.SomeError, cb.execute(io, void, &fail_req));
    try std.testing.expectEqual(@as(u64, 1), cb.getCounts(io).total_failures);

    // t=1499: expiry 未到達 → カウントリセットなし
    tc.advance(999); // t=1499
    try std.testing.expectError(error.SomeError, cb.execute(io, void, &fail_req));
    try std.testing.expectEqual(@as(u64, 2), cb.getCounts(io).total_failures);

    // t=1500: expiry 到達 → カウントリセット
    tc.advance(1); // t=1500
    try std.testing.expectError(error.SomeError, cb.execute(io, void, &fail_req));
    try std.testing.expectEqual(@as(u64, 1), cb.getCounts(io).total_failures);
}

test "half-open allows up to max requests" {
    // maxRequests > 1 の Half-Open 状態で、上限まで allow が成功し、
    // 上限超過で TooManyRequests を返すことを検証する。
    // また、maxRequests 分の成功で Closed に遷移することも確認する。
    var tc = TestClock{};
    var cb = CircuitBreaker.init(.{
        .clock = tc.clock(),
        .timeout_ns = 1000,
        .max_requests = 2,
        .ready_to_trip = struct {
            fn f(_: Counts) bool {
                return true;
            }
        }.f,
    });
    const io = std.testing.io;

    const FailReq = struct {
        pub fn call(self: *@This()) anyerror!void {
            _ = self;
            return error.SomeError;
        }
    };
    var fail_req = FailReq{};
    try std.testing.expectError(error.SomeError, cb.execute(io, void, &fail_req));
    tc.advance(1001);
    try std.testing.expectEqual(State.half_open, cb.getState(io));

    // max_requests=2 まで allow が通る
    var token1 = try cb.allow(io);
    var token2 = try cb.allow(io);
    // 3 つ目は超過
    try std.testing.expectError(error.TooManyRequests, cb.allow(io));

    // 2 件とも成功 → Closed へ遷移
    token1.done(io, true);
    token2.done(io, true);
    try std.testing.expectEqual(State.closed, cb.getState(io));
}

test "init maxRequests zero normalized to one" {
    var tc = TestClock{};
    var cb = CircuitBreaker.init(.{
        .clock = tc.clock(),
        .timeout_ns = 1000,
        .max_requests = 0,
        .ready_to_trip = struct {
            fn f(_: Counts) bool {
                return true;
            }
        }.f,
    });
    const io = std.testing.io;

    const FailReq = struct {
        pub fn call(self: *@This()) anyerror!void {
            _ = self;
            return error.SomeError;
        }
    };
    var fail_req = FailReq{};
    try std.testing.expectError(error.SomeError, cb.execute(io, void, &fail_req));
    tc.advance(1001);
    try std.testing.expectEqual(State.half_open, cb.getState(io));

    // max_requests=0 は 1 に正規化されているため、1 つ目は通り 2 つ目は拒否される
    const token = try cb.allow(io);
    try std.testing.expectError(error.TooManyRequests, cb.allow(io));
    token.done(io, true);
}

test "on state change called on open to half-open" {
    const Ctx = struct {
        called: bool = false,
        from: State = .closed,
        to: State = .closed,
    };
    var ctx = Ctx{};

    var tc = TestClock{};
    var cb = CircuitBreaker.init(.{
        .clock = tc.clock(),
        .timeout_ns = 1000,
        .ready_to_trip = struct {
            fn f(_: Counts) bool {
                return true;
            }
        }.f,
        .on_state_change = .{
            .context = &ctx,
            .call_fn = struct {
                fn f(context: ?*anyopaque, _: []const u8, from: State, to: State) void {
                    const c: *Ctx = @ptrCast(@alignCast(context.?));
                    c.called = true;
                    c.from = from;
                    c.to = to;
                }
            }.f,
        },
    });
    const io = std.testing.io;

    const FailReq = struct {
        pub fn call(self: *@This()) anyerror!void {
            _ = self;
            return error.SomeError;
        }
    };
    var fail_req = FailReq{};
    try std.testing.expectError(error.SomeError, cb.execute(io, void, &fail_req));
    ctx.called = false;

    tc.advance(1001);
    _ = cb.getState(io);
    try std.testing.expect(ctx.called);
    try std.testing.expectEqual(State.open, ctx.from);
    try std.testing.expectEqual(State.half_open, ctx.to);
}

test "on state change called on half-open to closed" {
    const Ctx = struct {
        called: bool = false,
        from: State = .closed,
        to: State = .closed,
    };
    var ctx = Ctx{};

    var tc = TestClock{};
    var cb = CircuitBreaker.init(.{
        .clock = tc.clock(),
        .timeout_ns = 1000,
        .ready_to_trip = struct {
            fn f(_: Counts) bool {
                return true;
            }
        }.f,
        .on_state_change = .{
            .context = &ctx,
            .call_fn = struct {
                fn f(context: ?*anyopaque, _: []const u8, from: State, to: State) void {
                    const c: *Ctx = @ptrCast(@alignCast(context.?));
                    c.called = true;
                    c.from = from;
                    c.to = to;
                }
            }.f,
        },
    });
    const io = std.testing.io;

    const FailReq = struct {
        pub fn call(self: *@This()) anyerror!void {
            _ = self;
            return error.SomeError;
        }
    };
    const OkReq = struct {
        pub fn call(self: *@This()) anyerror!void {
            _ = self;
        }
    };

    var fail_req = FailReq{};
    try std.testing.expectError(error.SomeError, cb.execute(io, void, &fail_req));
    tc.advance(1001);
    _ = cb.getState(io); // open→half_open 遷移を発火
    ctx.called = false;

    // half_open で成功（max_requests=1）→ closed へ
    var ok_req = OkReq{};
    try cb.execute(io, void, &ok_req);
    try std.testing.expect(ctx.called);
    try std.testing.expectEqual(State.half_open, ctx.from);
    try std.testing.expectEqual(State.closed, ctx.to);
}

test "on state change called on half-open to open" {
    const Ctx = struct {
        called: bool = false,
        from: State = .closed,
        to: State = .closed,
    };
    var ctx = Ctx{};

    var tc = TestClock{};
    var cb = CircuitBreaker.init(.{
        .clock = tc.clock(),
        .timeout_ns = 1000,
        .ready_to_trip = struct {
            fn f(_: Counts) bool {
                return true;
            }
        }.f,
        .on_state_change = .{
            .context = &ctx,
            .call_fn = struct {
                fn f(context: ?*anyopaque, _: []const u8, from: State, to: State) void {
                    const c: *Ctx = @ptrCast(@alignCast(context.?));
                    c.called = true;
                    c.from = from;
                    c.to = to;
                }
            }.f,
        },
    });
    const io = std.testing.io;

    const FailReq = struct {
        pub fn call(self: *@This()) anyerror!void {
            _ = self;
            return error.SomeError;
        }
    };
    var fail_req = FailReq{};
    try std.testing.expectError(error.SomeError, cb.execute(io, void, &fail_req));
    tc.advance(1001);
    ctx.called = false;

    // execute が open→half_open（br）と half_open→open（ar）の 2 回コールバックを発火する。
    // 後勝ちで ctx には half_open→open の値が残る。
    try std.testing.expectError(error.SomeError, cb.execute(io, void, &fail_req));
    try std.testing.expect(ctx.called);
    try std.testing.expectEqual(State.half_open, ctx.from);
    try std.testing.expectEqual(State.open, ctx.to);
}

test "execute returns non-void value" {
    var tc = TestClock{};
    var cb = CircuitBreaker.init(.{ .clock = tc.clock() });
    const io = std.testing.io;

    const Req = struct {
        pub fn call(self: *@This()) anyerror!u32 {
            _ = self;
            return 42;
        }
    };
    var req = Req{};
    const result = try cb.execute(io, u32, &req);
    try std.testing.expectEqual(@as(u32, 42), result);
}

test "getName returns configured name" {
    var tc = TestClock{};
    const cb = CircuitBreaker.init(.{
        .clock = tc.clock(),
        .name = "my-service",
    });
    try std.testing.expectEqualStrings("my-service", cb.getName());
}
