((method_declaration
   receiver: (parameter_list (parameter_declaration
     type: [(type_identifier) @recv (pointer_type (type_identifier) @recv)]))) @match
 (#match? @recv "Repository$")
 (#where? "(> (complexity @match) 5)")
 (#set! message "repository method complexity {complexity @match} exceeds 5 - repositories must stay simple"))
