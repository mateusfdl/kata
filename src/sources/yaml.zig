pub fn unquote(s: []const u8) []const u8 {
    if (s.len < 2) return s;

    const first = s[0];
    const last = s[s.len - 1];
    if ((first == '\'' and last == '\'') or (first == '"' and last == '"')) return s[1 .. s.len - 1];

    return s;
}
