((as_expression (predefined_type) @t) @match
 (#eq? @t "any")
 (#set! message "as any is not allowed - parse with zod or use a proper type"))

((as_expression (array_type (predefined_type) @t)) @match
 (#eq? @t "any")
 (#set! message "as any[] is not allowed - parse with zod or use a proper type"))
