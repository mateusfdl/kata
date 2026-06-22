((call_expression
  function: (identifier) @fn) @match
 (#any-of? @fn "print" "println")
 (#set! message "builtin print/println is debug-only and not guaranteed by the spec - use proper instrumentation"))
