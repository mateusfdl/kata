((for_statement
  body: (block (defer_statement) @match))
 (#set! message "defer in a loop runs only when the function returns, not each iteration - extract the body into its own function or release the resource explicitly"))
