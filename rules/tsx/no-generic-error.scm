((throw_statement
  (new_expression
    (identifier) @name)) @match
 (#eq? @name "Error")
 (#set! message "generic Error is not allowed - throw a domain-specific error class"))
