const std = @import("std");
const glob = @import("glob.zig");

fn expectMatch(pattern: []const u8, path: []const u8) !void {
    try std.testing.expect(glob.match(pattern, path));
}

fn expectNoMatch(pattern: []const u8, path: []const u8) !void {
    try std.testing.expect(!glob.match(pattern, path));
}

test "glob: literal path matches exactly" {
    try expectMatch("foo.go", "foo.go");
    try expectNoMatch("foo.go", "foo.gox");
    try expectNoMatch("foo.go", "bar.go");
}

test "glob: single star is segment-bounded" {
    try expectMatch("*.go", "a.go");
    try expectMatch("*_test.go", "foo_test.go");
    try expectNoMatch("*.go", "src/a.go");
    try expectNoMatch("*_test.go", "pkg/foo_test.go");
}

test "glob: star matches empty run" {
    try expectMatch("foo*.go", "foo.go");
    try expectMatch("*foo.go", "foo.go");
}

test "glob: question mark matches one non-slash char" {
    try expectMatch("a?c.go", "abc.go");
    try expectNoMatch("a?c.go", "ac.go");
    try expectNoMatch("a?c", "a/c");
}

test "glob: double star spans segments" {
    try expectMatch("**/vendor", "vendor");
    try expectMatch("**/vendor", "a/b/vendor");
    try expectMatch("**/*_test.go", "foo_test.go");
    try expectMatch("**/*_test.go", "a/b/foo_test.go");
    try expectMatch("src/**/foo.go", "src/a/b/foo.go");
    try expectMatch("src/**/foo.go", "src/foo.go");
}

test "glob: trailing slash is a directory prefix" {
    try expectMatch("vendor/", "vendor/x.go");
    try expectMatch("vendor/", "vendor/a/b.go");
    try expectNoMatch("vendor/", "vendor");
    try expectNoMatch("vendor/", "src/vendor/x.go");
    try expectNoMatch("vendor/", "vendored/x.go");
}

test "glob: double-star directory prefix matches any depth" {
    try expectMatch("**/vendor/", "vendor/x.go");
    try expectMatch("**/vendor/", "a/vendor/b.go");
    try expectNoMatch("**/vendor/", "a/vendored/b.go");
}

test "glob: empty pattern never matches" {
    try expectNoMatch("", "foo.go");
    try expectNoMatch("", "");
}
