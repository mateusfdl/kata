((call_expression
  function: (member_expression
    property: (property_identifier) @name)) @match
 (#match? @name "^(toBeDefined|toBeUndefined|toBeNull|toBeTruthy|toBeFalsy|toHaveBeenCalled|toContain)$")
 (#set! message "weak assertion - use .toEqual() with explicit values"))
