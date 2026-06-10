([(function_declaration)
  (method_declaration)
  (func_literal)] @match
 (#where? "(> (complexity @match) 10)")
 (#set! message "cyclomatic complexity exceeds 10 - extract smaller functions"))
