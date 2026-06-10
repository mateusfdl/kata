([(function_declaration)
  (method_declaration)
  (func_literal)] @match
 (#where? "(> (length @match) 50)")
 (#set! message "function spans {length @match} lines (max 50) - split it into focused units"))
