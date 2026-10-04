//! endpoint_repair: a source stopped answering, the agent found where it lives
//! now. The answer is only ever PROPOSED; the user approves it before any
//! configuration changes.
//!
//! STUB: the real handler (probe the proposed address, store the proposal,
//! apply it through source_config on approval, and the trigger from source
//! health) is not written yet.

const std = @import("std");
const pure = @import("operator_pure.zig");

/// `key` is the source id. Validate and probe `result_json`, then report
/// `proposed` (waiting for the user) or `failed`.
pub fn handle(key: []const u8, result_json: []const u8) pure.Handled {
    _ = key;
    _ = result_json;
    return pure.Handled.make(.failed, "Not implemented yet", .{});
}

/// The user approved the proposal stored for `key`: write it into the source
/// configuration. False when it could not be applied.
pub fn approve(key: []const u8, result_json: []const u8) bool {
    _ = key;
    _ = result_json;
    return false;
}
