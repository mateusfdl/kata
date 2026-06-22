((parameter_list
  (parameter_declaration)
  (parameter_declaration
    type: (qualified_type
      package: (package_identifier) @pkg
      name: (type_identifier) @typ)) @match)
 (#eq? @pkg "context")
 (#eq? @typ "Context")
 (#set! message "context.Context must be the first parameter of a function"))
