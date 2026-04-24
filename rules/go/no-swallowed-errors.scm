((short_var_declaration
  left: (expression_list (identifier) @blank)) @match
 (#eq? @blank "_")
 (#set! message "blank identifier discarding function return - errors must be handled explicitly"))
