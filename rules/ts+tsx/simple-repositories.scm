((class_declaration
   name: (type_identifier) @name
   body: (class_body (method_definition) @match))
 (#match? @name "Repository$")
 (#where? "(> (complexity @match) 5)")
 (#set! message "repository methods must stay simple - keep complexity at 5 or below"))
