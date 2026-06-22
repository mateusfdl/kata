((call_expression
  function: (selector_expression
    operand: (identifier) @pkg
    field: (field_identifier) @fn)
  arguments: (argument_list . (interpreted_string_literal) @match))
 (#any-of? @pkg "errors" "fmt")
 (#any-of? @fn "New" "Errorf")
 (#match? @match "^\"[A-Z]")
 (#set! message "error strings should not be capitalized - they are wrapped and printed mid-sentence"))
