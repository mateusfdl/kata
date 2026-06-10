([(function_declaration)
  (function_expression)
  (generator_function_declaration)
  (generator_function)
  (arrow_function)
  (method_definition)] @match
 (#where? "(> (nesting @match) 3)")
 (#set! message "nesting depth exceeds 3 - flatten with guard clauses"))
