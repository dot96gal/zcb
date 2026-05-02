const cb = @import("circuit_breaker.zig");

pub const default_consecutive_failures_threshold = cb.default_consecutive_failures_threshold;
pub const Clock = cb.Clock;
pub const State = cb.State;
pub const Counts = cb.Counts;
pub const Error = cb.Error;
pub const StateChangeCallback = cb.StateChangeCallback;
pub const Config = cb.Config;
pub const AllowToken = cb.AllowToken;
pub const CircuitBreaker = cb.CircuitBreaker;
pub const TestClock = cb.TestClock;

test {
    _ = @import("circuit_breaker.zig");
}
