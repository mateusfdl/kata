((call_expression
  function: (member_expression
    object: (call_expression
      function: (identifier) @expect)
    property: (property_identifier) @name)) @match
 (#eq? @expect "expect")
 (#any-of? @name "toBeDefined" "toBeUndefined" "toBeNull" "toBeTruthy" "toBeFalsy" "toHaveBeenCalled" "toContain")
 (#set! message "weak assertion - use .toEqual() with explicit values"))
