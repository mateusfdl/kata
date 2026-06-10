((class_declaration
   name: (type_identifier) @name
   body: (class_body (method_definition) @match))
 (#match? @name "Repository$")
 (#where? "(> (complexity @match) 5)")
 (#set! message "repository method complexity {complexity @match} exceeds 5 - repositories must stay simple"))
