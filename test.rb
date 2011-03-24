require 'css_parser'

data = File.read ARGV.shift

parser = CSSParser.new data, true

if parser.parse
  puts "PARSED"
else
  parser.raise_error
end
