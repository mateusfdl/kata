([(function_declaration)
  (function_expression)
  (generator_function_declaration)
  (generator_function)
  (arrow_function)
  (method_definition)] @match
 (#where? "(> (complexity @match) 10)")
 (#set! message "cyclomatic complexity {complexity @match} exceeds 10 - extract smaller functions"))
