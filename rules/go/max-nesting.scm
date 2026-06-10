([(function_declaration)
  (method_declaration)
  (func_literal)] @match
 (#where? "(> (nesting @match) 3)")
 (#set! message "nesting depth exceeds 3 - flatten with guard clauses"))
