const compiled_rule = @import("facts/compiled_rule.zig");
const context_query = @import("facts/context_query.zig");
const count_query = @import("facts/count_query.zig");
const evaluate_rule = @import("facts/evaluate_rule.zig");
const fact_query = @import("facts/fact_query.zig");
const fact_schema = @import("fact_schema.zig");
const message_rule = @import("facts/message_rule.zig");
const operand_query = @import("facts/operand_query.zig");
const predicate_query = @import("facts/predicate_query.zig");
const project_rule = @import("ProjectRule.zig");
const scalar_query = @import("facts/scalar_query.zig");

pub const Violation = project_rule.Violation;

pub const FactKind = fact_schema.FactKind;
pub const Field = fact_schema.Field;
pub const Fact = fact_schema.Fact;
pub const factHasField = fact_schema.factHasField;

pub const CaptureId = context_query.CaptureId;
pub const CaptureSet = context_query.CaptureSet;
pub const FieldOperand = operand_query.FieldOperand;
pub const HelperOperand = operand_query.HelperOperand;
pub const Operand = operand_query.Operand;
pub const Op = scalar_query.Op;
pub const ScalarPredicate = scalar_query.ScalarPredicate;
pub const FactQuery = fact_query.FactQuery;
pub const CountCompare = count_query.CountCompare;
pub const CountPredicate = count_query.CountPredicate;
pub const Predicate = predicate_query.Predicate;
pub const Group = predicate_query.Group;

pub const MessageSegment = message_rule.MessageSegment;
pub const CompiledFactRule = compiled_rule.CompiledFactRule;
pub const fieldFromString = compiled_rule.fieldFromString;

pub const evaluate = evaluate_rule.evaluate;
pub const evaluateInto = evaluate_rule.evaluateInto;
