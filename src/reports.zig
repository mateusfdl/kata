const dispatch = @import("reports/dispatch.zig");
const json = @import("reports/json.zig");
const pretty = @import("reports/pretty.zig");
const sarif = @import("reports/sarif.zig");
const summary = @import("reports/summary.zig");
const text = @import("reports/text.zig");

pub const Counts = summary.Counts;
pub const Error = dispatch.Error;
pub const Format = dispatch.Format;
pub const Json = json.Report;
pub const Pretty = pretty.Report;
pub const Reporter = dispatch.Reporter;
pub const RuleOverflow = summary.RuleOverflow;
pub const Sarif = sarif.Report;
pub const Text = text.Report;
