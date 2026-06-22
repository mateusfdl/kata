((interface_type) @match
 (#match? @match "^interface\\s*\\{\\s*\\}")
 (#set! message "the empty interface accepts anything and asserts nothing - use a concrete type or a generic constraint"))

((parameter_declaration
  type: (type_identifier) @match)
 (#eq? @match "any")
 (#set! message "any accepts anything and asserts nothing - use a concrete type or a generic constraint"))

((function_declaration
  result: (type_identifier) @match)
 (#eq? @match "any")
 (#set! message "any accepts anything and asserts nothing - use a concrete type or a generic constraint"))

((field_declaration
  type: (type_identifier) @match)
 (#eq? @match "any")
 (#set! message "any accepts anything and asserts nothing - use a concrete type or a generic constraint"))

((var_spec
  type: (type_identifier) @match)
 (#eq? @match "any")
 (#set! message "any accepts anything and asserts nothing - use a concrete type or a generic constraint"))
