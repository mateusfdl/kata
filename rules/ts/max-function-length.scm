([(function_declaration)
  (function_expression)
  (generator_function_declaration)
  (generator_function)
  (arrow_function)
  (method_definition)] @match
 (#where? "(> (length @match) 50)")
 (#set! message "function spans {length @match} lines (max 50) - split it into focused units"))
