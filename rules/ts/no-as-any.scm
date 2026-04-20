((as_expression (predefined_type) @t) @match
 (#eq? @t "any")
 (#set! message "as any is not allowed, create a proper type to represent it"))

((as_expression (array_type (predefined_type) @t)) @match
 (#eq? @t "any")
 (#set! message "as any[] is not allowed, create a proper type to represent it"))
