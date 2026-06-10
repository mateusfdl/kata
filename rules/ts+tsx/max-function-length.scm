([(function_declaration)
  (function_expression)
  (generator_function_declaration)
  (generator_function)
  (arrow_function)
  (method_definition)] @match
 (#where? "(> (length @match) 50)")
 (#set! message "function exceeds 50 lines - split it into focused units"))
