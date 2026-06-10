([(function_declaration)
  (method_declaration)
  (func_literal)] @match
 (#where? "(> (length @match) 50)")
 (#set! message "function exceeds 50 lines - split it into focused units"))
