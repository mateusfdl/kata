((call_expression
  function: (identifier) @fn) @match
 (#eq? @fn "panic")
 (#set! message "panic is not allowed - return a domain-specific error and let the caller decide"))
