((call_expression
  function: (member_expression
    object: (identifier) @obj)) @match
 (#eq? @obj "console")
 (#set! message "console is not allowed - use proper instrumentation"))
