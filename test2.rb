require 'css_parser'

decl =
"background-image: url(http://www.w3.org/StyleSheets/TR/logo-WD)"

data = 
"td { background-image: url(http://www.w3.org/StyleSheets/TR/logo-WD); }"

parser = CSSParser.new data, true

if parser.parse("ruleset")
  puts "PARSED"
else
  parser.raise_error
end
