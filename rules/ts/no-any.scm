((type_annotation (predefined_type) @t) @match
 (#eq? @t "any")
 (#set! message "any is not allowed - use a proper type"))

((type_annotation (array_type (predefined_type) @t)) @match
 (#eq? @t "any")
 (#set! message "any[] is not allowed - use a proper type"))

((type_arguments (predefined_type) @t) @match
 (#eq? @t "any")
 (#set! message "any as type argument is not allowed - use a proper type"))
