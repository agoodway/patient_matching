[
  import_deps: [:credo],
  inputs: [
    "*.{ex,exs}",
    ".{credo,doctor,formatter}.exs",
    ".sobelow-conf",
    "{config,lib,test,eval}/**/*.{ex,exs}"
  ]
]
