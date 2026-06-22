((function_declaration
  name: (identifier) @name) @match
 (#eq? @name "init")
 (#set! message "init functions hide setup and resist testing - use an explicit constructor and dependency injection"))
