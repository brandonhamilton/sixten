" Syntax highlighting for Sixten

if exists("b:current_syntax")
  finish
endif

highlight def link sixtenIdentifier Identifier
highlight def link sixtenDefinition Function
highlight def link sixtenType Type
highlight def link sixtenNumber Number
highlight def link sixtenDataKeyword Structure
highlight def link sixtenCaseKeyword Keyword
highlight def link sixtenForall Keyword
highlight def link sixtenLambda Keyword
highlight def link sixtenDot Keyword
highlight def link sixtenArrow Operator
highlight def link sixtenEquals Operator
highlight def link sixtenTypeAnno Operator
highlight def link sixtenLineComment Comment
highlight def link sixtenBlockComment Comment
highlight def link sixtenTodo Todo

syn match sixtenIdentifier "[_a-z][a-zA-Z0-9_']*" contained
syn match sixtenDefinition "^\([_a-z][a-zA-Z0-9_']*\s*\):"
syn match sixtenType "\<[A-Z][a-zA-Z0-9_']*\>"
syn match sixtenNumber "\<[0-9]\+\>"
syn keyword sixtenDataKeyword data where
syn keyword sixtenCaseKeyword case of
syn keyword sixtenForall forall
syn match sixtenLambda "\\"
syn match sixtenDot "\."
syn match sixtenArrow "->"
syn match sixtenEquals "="
syn match sixtenTypeAnno ":"

syn match sixtenLineComment "---*\([^-!#$%&\*\+./<=>\?@\\^|~].*\)\?$"
  \ contains=
  \ sixtenTodo,
  \ @Spell
syn region sixtenBlockComment start="{-" end="-}"
  \ contains=
  \ sixtenBlockComment,
  \ sixtenTodo,
\ @Spell

syn keyword sixtenTodo TODO FIXME contained