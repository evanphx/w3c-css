class CSSParser
# STANDALONE START
    def setup_parser(str, debug=false)
      @string = str
      @pos = 0
      @memoizations = Hash.new { |h,k| h[k] = {} }
      @result = nil
      @failed_rule = nil
      @failing_rule_offset = -1

      setup_foreign_grammar
    end

    # This is distinct from setup_parser so that a standalone parser
    # can redefine #initialize and still have access to the proper
    # parser setup code.
    #
    def initialize(str, debug=false)
      setup_parser(str, debug)
    end

    attr_reader :string
    attr_reader :result, :failing_rule_offset
    attr_accessor :pos

    # STANDALONE START
    def current_column(target=pos)
      if c = string.rindex("\n", target-1)
        return target - c - 1
      end

      target + 1
    end

    def current_line(target=pos)
      cur_offset = 0
      cur_line = 0

      string.each_line do |line|
        cur_line += 1
        cur_offset += line.size
        return cur_line if cur_offset >= target
      end

      -1
    end

    def lines
      lines = []
      string.each_line { |l| lines << l }
      lines
    end

    #

    def get_text(start)
      @string[start..@pos-1]
    end

    def show_pos
      width = 10
      if @pos < width
        "#{@pos} (\"#{@string[0,@pos]}\" @ \"#{@string[@pos,width]}\")"
      else
        "#{@pos} (\"... #{@string[@pos - width, width]}\" @ \"#{@string[@pos,width]}\")"
      end
    end

    def failure_info
      l = current_line @failing_rule_offset
      c = current_column @failing_rule_offset

      if @failed_rule.kind_of? Symbol
        info = self.class::Rules[@failed_rule]
        "line #{l}, column #{c}: failed rule '#{info.name}' = '#{info.rendered}'"
      else
        "line #{l}, column #{c}: failed rule '#{@failed_rule}'"
      end
    end

    def failure_caret
      l = current_line @failing_rule_offset
      c = current_column @failing_rule_offset

      line = lines[l-1]
      "#{line}\n#{' ' * (c - 1)}^"
    end

    def failure_character
      l = current_line @failing_rule_offset
      c = current_column @failing_rule_offset
      lines[l-1][c-1, 1]
    end

    def failure_oneline
      l = current_line @failing_rule_offset
      c = current_column @failing_rule_offset

      char = lines[l-1][c-1, 1]

      if @failed_rule.kind_of? Symbol
        info = self.class::Rules[@failed_rule]
        "@#{l}:#{c} failed rule '#{info.name}', got '#{char}'"
      else
        "@#{l}:#{c} failed rule '#{@failed_rule}', got '#{char}'"
      end
    end

    class ParseError < RuntimeError
    end

    def raise_error
      raise ParseError, failure_oneline
    end

    def show_error(io=STDOUT)
      error_pos = @failing_rule_offset
      line_no = current_line(error_pos)
      col_no = current_column(error_pos)

      io.puts "On line #{line_no}, column #{col_no}:"

      if @failed_rule.kind_of? Symbol
        info = self.class::Rules[@failed_rule]
        io.puts "Failed to match '#{info.rendered}' (rule '#{info.name}')"
      else
        io.puts "Failed to match rule '#{@failed_rule}'"
      end

      io.puts "Got: #{string[error_pos,1].inspect}"
      line = lines[line_no-1]
      io.puts "=> #{line}"
      io.print(" " * (col_no + 3))
      io.puts "^"
    end

    def set_failed_rule(name)
      if @pos > @failing_rule_offset
        @failed_rule = name
        @failing_rule_offset = @pos
      end
    end

    attr_reader :failed_rule

    def match_string(str)
      len = str.size
      if @string[pos,len] == str
        @pos += len
        return str
      end

      return nil
    end

    def scan(reg)
      if m = reg.match(@string[@pos..-1])
        width = m.end(0)
        @pos += width
        return true
      end

      return nil
    end

    if "".respond_to? :getbyte
      def get_byte
        if @pos >= @string.size
          return nil
        end

        s = @string.getbyte @pos
        @pos += 1
        s
      end
    else
      def get_byte
        if @pos >= @string.size
          return nil
        end

        s = @string[@pos]
        @pos += 1
        s
      end
    end

    def parse(rule=nil)
      if !rule
        _root ? true : false
      else
        # This is not shared with code_generator.rb so this can be standalone
        method = rule.gsub("-","_hyphen_")
        __send__("_#{method}") ? true : false
      end
    end

    class LeftRecursive
      def initialize(detected=false)
        @detected = detected
      end

      attr_accessor :detected
    end

    class MemoEntry
      def initialize(ans, pos)
        @ans = ans
        @pos = pos
        @uses = 1
        @result = nil
      end

      attr_reader :ans, :pos, :uses, :result

      def inc!
        @uses += 1
      end

      def move!(ans, pos, result)
        @ans = ans
        @pos = pos
        @result = result
      end
    end

    def external_invoke(other, rule, *args)
      old_pos = @pos
      old_string = @string

      @pos = other.pos
      @string = other.string

      begin
        if val = __send__(rule, *args)
          other.pos = @pos
        else
          other.set_failed_rule "#{self.class}##{rule}"
        end
        val
      ensure
        @pos = old_pos
        @string = old_string
      end
    end

    def apply(rule)
      if m = @memoizations[rule][@pos]
        m.inc!

        prev = @pos
        @pos = m.pos
        if m.ans.kind_of? LeftRecursive
          m.ans.detected = true
          return nil
        end

        @result = m.result

        return m.ans
      else
        lr = LeftRecursive.new(false)
        m = MemoEntry.new(lr, @pos)
        @memoizations[rule][@pos] = m
        start_pos = @pos

        ans = __send__ rule

        m.move! ans, @pos, @result

        # Don't bother trying to grow the left recursion
        # if it's failing straight away (thus there is no seed)
        if ans and lr.detected
          return grow_lr(rule, start_pos, m)
        else
          return ans
        end

        return ans
      end
    end

    def grow_lr(rule, start_pos, m)
      while true
        @pos = start_pos
        @result = m.result

        ans = __send__ rule
        return nil unless ans

        break if @pos <= m.pos

        m.move! ans, @pos, @result
      end

      @result = m.result
      @pos = m.pos
      return m.ans
    end

    class RuleInfo
      def initialize(name, rendered)
        @name = name
        @rendered = rendered
      end

      attr_reader :name, :rendered
    end

    def self.rule_info(name, rendered)
      RuleInfo.new(name, rendered)
    end

    #
  def setup_foreign_grammar; end

  # h = /[0-9a-fA-F]/
  def _h
    _tmp = scan(/\A(?-mix:[0-9a-fA-F])/)
    set_failed_rule :_h unless _tmp
    return _tmp
  end

  # nonascii = /[\200-\377]/
  def _nonascii
    _tmp = scan(/\A(?-mix:[\200-\377])/)
    set_failed_rule :_nonascii unless _tmp
    return _tmp
  end

  # unicode = h[1, 6] (/\r\n/ | /[ \t\r\n\f]/)?
  def _unicode

    _save = self.pos
    while true # sequence
    _save1 = self.pos
    _count = 0
    while true
      _tmp = apply(:_h)
      if _tmp
        _count += 1
        break if _count == 6
      else
        break
      end
    end
    if _count >= 1
      _tmp = true
    else
      self.pos = _save1
      _tmp = nil
    end
    unless _tmp
      self.pos = _save
      break
    end
    _save2 = self.pos

    _save3 = self.pos
    while true # choice
    _tmp = scan(/\A(?-mix:\r\n)/)
    break if _tmp
    self.pos = _save3
    _tmp = scan(/\A(?-mix:[ \t\r\n\f])/)
    break if _tmp
    self.pos = _save3
    break
    end # end choice

    unless _tmp
      _tmp = true
      self.pos = _save2
    end
    unless _tmp
      self.pos = _save
    end
    break
    end # end sequence

    set_failed_rule :_unicode unless _tmp
    return _tmp
  end

  # escape = (unicode | "\\" /[ -~\200-\377]/)
  def _escape

    _save = self.pos
    while true # choice
    _tmp = apply(:_unicode)
    break if _tmp
    self.pos = _save

    _save1 = self.pos
    while true # sequence
    _tmp = match_string("\\")
    unless _tmp
      self.pos = _save1
      break
    end
    _tmp = scan(/\A(?-mix:[ -~\200-\377])/)
    unless _tmp
      self.pos = _save1
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save
    break
    end # end choice

    set_failed_rule :_escape unless _tmp
    return _tmp
  end

  # nmstart = (/[_a-zA-Z]/ | nonascii | escape)
  def _nmstart

    _save = self.pos
    while true # choice
    _tmp = scan(/\A(?-mix:[_a-zA-Z])/)
    break if _tmp
    self.pos = _save
    _tmp = apply(:_nonascii)
    break if _tmp
    self.pos = _save
    _tmp = apply(:_escape)
    break if _tmp
    self.pos = _save
    break
    end # end choice

    set_failed_rule :_nmstart unless _tmp
    return _tmp
  end

  # nmchar = (/[_a-zA-Z0-9\-]/ | nonascii | escape)
  def _nmchar

    _save = self.pos
    while true # choice
    _tmp = scan(/\A(?-mix:[_a-zA-Z0-9\-])/)
    break if _tmp
    self.pos = _save
    _tmp = apply(:_nonascii)
    break if _tmp
    self.pos = _save
    _tmp = apply(:_escape)
    break if _tmp
    self.pos = _save
    break
    end # end choice

    set_failed_rule :_nmchar unless _tmp
    return _tmp
  end

  # string1 = "\"" (/[^\n\r\f\\"]/ | "\\" nl | escape)* "\""
  def _string1

    _save = self.pos
    while true # sequence
    _tmp = match_string("\"")
    unless _tmp
      self.pos = _save
      break
    end
    while true

    _save2 = self.pos
    while true # choice
    _tmp = scan(/\A(?-mix:[^\n\r\f\\"])/)
    break if _tmp
    self.pos = _save2

    _save3 = self.pos
    while true # sequence
    _tmp = match_string("\\")
    unless _tmp
      self.pos = _save3
      break
    end
    _tmp = apply(:_nl)
    unless _tmp
      self.pos = _save3
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save2
    _tmp = apply(:_escape)
    break if _tmp
    self.pos = _save2
    break
    end # end choice

    break unless _tmp
    end
    _tmp = true
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = match_string("\"")
    unless _tmp
      self.pos = _save
    end
    break
    end # end sequence

    set_failed_rule :_string1 unless _tmp
    return _tmp
  end

  # string2 = "'" (/[^\n\r\f\\']/ | "\\" nl | escape)* "'"
  def _string2

    _save = self.pos
    while true # sequence
    _tmp = match_string("'")
    unless _tmp
      self.pos = _save
      break
    end
    while true

    _save2 = self.pos
    while true # choice
    _tmp = scan(/\A(?-mix:[^\n\r\f\\'])/)
    break if _tmp
    self.pos = _save2

    _save3 = self.pos
    while true # sequence
    _tmp = match_string("\\")
    unless _tmp
      self.pos = _save3
      break
    end
    _tmp = apply(:_nl)
    unless _tmp
      self.pos = _save3
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save2
    _tmp = apply(:_escape)
    break if _tmp
    self.pos = _save2
    break
    end # end choice

    break unless _tmp
    end
    _tmp = true
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = match_string("'")
    unless _tmp
      self.pos = _save
    end
    break
    end # end sequence

    set_failed_rule :_string2 unless _tmp
    return _tmp
  end

  # badstring1 = "\"" (/[^\n\r\f\\"]/ | "\\" nl | escape)* "\\"?
  def _badstring1

    _save = self.pos
    while true # sequence
    _tmp = match_string("\"")
    unless _tmp
      self.pos = _save
      break
    end
    while true

    _save2 = self.pos
    while true # choice
    _tmp = scan(/\A(?-mix:[^\n\r\f\\"])/)
    break if _tmp
    self.pos = _save2

    _save3 = self.pos
    while true # sequence
    _tmp = match_string("\\")
    unless _tmp
      self.pos = _save3
      break
    end
    _tmp = apply(:_nl)
    unless _tmp
      self.pos = _save3
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save2
    _tmp = apply(:_escape)
    break if _tmp
    self.pos = _save2
    break
    end # end choice

    break unless _tmp
    end
    _tmp = true
    unless _tmp
      self.pos = _save
      break
    end
    _save4 = self.pos
    _tmp = match_string("\\")
    unless _tmp
      _tmp = true
      self.pos = _save4
    end
    unless _tmp
      self.pos = _save
    end
    break
    end # end sequence

    set_failed_rule :_badstring1 unless _tmp
    return _tmp
  end

  # badstring2 = "'" (/[^\n\r\f\\']/ | "\\" nl | escape)* "\\"?
  def _badstring2

    _save = self.pos
    while true # sequence
    _tmp = match_string("'")
    unless _tmp
      self.pos = _save
      break
    end
    while true

    _save2 = self.pos
    while true # choice
    _tmp = scan(/\A(?-mix:[^\n\r\f\\'])/)
    break if _tmp
    self.pos = _save2

    _save3 = self.pos
    while true # sequence
    _tmp = match_string("\\")
    unless _tmp
      self.pos = _save3
      break
    end
    _tmp = apply(:_nl)
    unless _tmp
      self.pos = _save3
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save2
    _tmp = apply(:_escape)
    break if _tmp
    self.pos = _save2
    break
    end # end choice

    break unless _tmp
    end
    _tmp = true
    unless _tmp
      self.pos = _save
      break
    end
    _save4 = self.pos
    _tmp = match_string("\\")
    unless _tmp
      _tmp = true
      self.pos = _save4
    end
    unless _tmp
      self.pos = _save
    end
    break
    end # end sequence

    set_failed_rule :_badstring2 unless _tmp
    return _tmp
  end

  # badcomment1 = "/*" /[^*]*/ "*"+ (/[^\/*]/ /[^*]*/ "*"+)*
  def _badcomment1

    _save = self.pos
    while true # sequence
    _tmp = match_string("/*")
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = scan(/\A(?-mix:[^*]*)/)
    unless _tmp
      self.pos = _save
      break
    end
    _save1 = self.pos
    _tmp = match_string("*")
    if _tmp
      while true
        _tmp = match_string("*")
        break unless _tmp
      end
      _tmp = true
    else
      self.pos = _save1
    end
    unless _tmp
      self.pos = _save
      break
    end
    while true

    _save3 = self.pos
    while true # sequence
    _tmp = scan(/\A(?-mix:[^\/*])/)
    unless _tmp
      self.pos = _save3
      break
    end
    _tmp = scan(/\A(?-mix:[^*]*)/)
    unless _tmp
      self.pos = _save3
      break
    end
    _save4 = self.pos
    _tmp = match_string("*")
    if _tmp
      while true
        _tmp = match_string("*")
        break unless _tmp
      end
      _tmp = true
    else
      self.pos = _save4
    end
    unless _tmp
      self.pos = _save3
    end
    break
    end # end sequence

    break unless _tmp
    end
    _tmp = true
    unless _tmp
      self.pos = _save
    end
    break
    end # end sequence

    set_failed_rule :_badcomment1 unless _tmp
    return _tmp
  end

  # badcomment2 = "/*" /[^*]*/ ("*"+ /[^\/*]/ /[^*]*/)*
  def _badcomment2

    _save = self.pos
    while true # sequence
    _tmp = match_string("/*")
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = scan(/\A(?-mix:[^*]*)/)
    unless _tmp
      self.pos = _save
      break
    end
    while true

    _save2 = self.pos
    while true # sequence
    _save3 = self.pos
    _tmp = match_string("*")
    if _tmp
      while true
        _tmp = match_string("*")
        break unless _tmp
      end
      _tmp = true
    else
      self.pos = _save3
    end
    unless _tmp
      self.pos = _save2
      break
    end
    _tmp = scan(/\A(?-mix:[^\/*])/)
    unless _tmp
      self.pos = _save2
      break
    end
    _tmp = scan(/\A(?-mix:[^*]*)/)
    unless _tmp
      self.pos = _save2
    end
    break
    end # end sequence

    break unless _tmp
    end
    _tmp = true
    unless _tmp
      self.pos = _save
    end
    break
    end # end sequence

    set_failed_rule :_badcomment2 unless _tmp
    return _tmp
  end

  # baduri1 = url "(" w (/[\!\#\$\%\&\*-\[\]-\~]/ | nonascii | escape)* w
  def _baduri1

    _save = self.pos
    while true # sequence
    _tmp = apply(:_url)
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = match_string("(")
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:_w)
    unless _tmp
      self.pos = _save
      break
    end
    while true

    _save2 = self.pos
    while true # choice
    _tmp = scan(/\A(?-mix:[\!\#\$\%\&\*-\[\]-\~])/)
    break if _tmp
    self.pos = _save2
    _tmp = apply(:_nonascii)
    break if _tmp
    self.pos = _save2
    _tmp = apply(:_escape)
    break if _tmp
    self.pos = _save2
    break
    end # end choice

    break unless _tmp
    end
    _tmp = true
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:_w)
    unless _tmp
      self.pos = _save
    end
    break
    end # end sequence

    set_failed_rule :_baduri1 unless _tmp
    return _tmp
  end

  # baduri2 = url "(" w string w
  def _baduri2

    _save = self.pos
    while true # sequence
    _tmp = apply(:_url)
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = match_string("(")
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:_w)
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:_string)
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:_w)
    unless _tmp
      self.pos = _save
    end
    break
    end # end sequence

    set_failed_rule :_baduri2 unless _tmp
    return _tmp
  end

  # baduri3 = url "(" w badstring
  def _baduri3

    _save = self.pos
    while true # sequence
    _tmp = apply(:_url)
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = match_string("(")
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:_w)
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:_badstring)
    unless _tmp
      self.pos = _save
    end
    break
    end # end sequence

    set_failed_rule :_baduri3 unless _tmp
    return _tmp
  end

  # comment = "/*" /[^*]*/ "*"+ (/[^\/*]/ /[^*]*/ "*"+)* "/"
  def _comment

    _save = self.pos
    while true # sequence
    _tmp = match_string("/*")
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = scan(/\A(?-mix:[^*]*)/)
    unless _tmp
      self.pos = _save
      break
    end
    _save1 = self.pos
    _tmp = match_string("*")
    if _tmp
      while true
        _tmp = match_string("*")
        break unless _tmp
      end
      _tmp = true
    else
      self.pos = _save1
    end
    unless _tmp
      self.pos = _save
      break
    end
    while true

    _save3 = self.pos
    while true # sequence
    _tmp = scan(/\A(?-mix:[^\/*])/)
    unless _tmp
      self.pos = _save3
      break
    end
    _tmp = scan(/\A(?-mix:[^*]*)/)
    unless _tmp
      self.pos = _save3
      break
    end
    _save4 = self.pos
    _tmp = match_string("*")
    if _tmp
      while true
        _tmp = match_string("*")
        break unless _tmp
      end
      _tmp = true
    else
      self.pos = _save4
    end
    unless _tmp
      self.pos = _save3
    end
    break
    end # end sequence

    break unless _tmp
    end
    _tmp = true
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = match_string("/")
    unless _tmp
      self.pos = _save
    end
    break
    end # end sequence

    set_failed_rule :_comment unless _tmp
    return _tmp
  end

  # ident = "-"? nmstart nmchar*
  def _ident

    _save = self.pos
    while true # sequence
    _save1 = self.pos
    _tmp = match_string("-")
    unless _tmp
      _tmp = true
      self.pos = _save1
    end
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:_nmstart)
    unless _tmp
      self.pos = _save
      break
    end
    while true
    _tmp = apply(:_nmchar)
    break unless _tmp
    end
    _tmp = true
    unless _tmp
      self.pos = _save
    end
    break
    end # end sequence

    set_failed_rule :_ident unless _tmp
    return _tmp
  end

  # name = nmchar+
  def _name
    _save = self.pos
    _tmp = apply(:_nmchar)
    if _tmp
      while true
        _tmp = apply(:_nmchar)
        break unless _tmp
      end
      _tmp = true
    else
      self.pos = _save
    end
    set_failed_rule :_name unless _tmp
    return _tmp
  end

  # num = (/[0-9]+/ | /[0-9]*/ "." /[0-9]+/)
  def _num

    _save = self.pos
    while true # choice
    _tmp = scan(/\A(?-mix:[0-9]+)/)
    break if _tmp
    self.pos = _save

    _save1 = self.pos
    while true # sequence
    _tmp = scan(/\A(?-mix:[0-9]*)/)
    unless _tmp
      self.pos = _save1
      break
    end
    _tmp = match_string(".")
    unless _tmp
      self.pos = _save1
      break
    end
    _tmp = scan(/\A(?-mix:[0-9]+)/)
    unless _tmp
      self.pos = _save1
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save
    break
    end # end choice

    set_failed_rule :_num unless _tmp
    return _tmp
  end

  # string = (string1 | string2)
  def _string

    _save = self.pos
    while true # choice
    _tmp = apply(:_string1)
    break if _tmp
    self.pos = _save
    _tmp = apply(:_string2)
    break if _tmp
    self.pos = _save
    break
    end # end choice

    set_failed_rule :_string unless _tmp
    return _tmp
  end

  # badstring = (badstring1 | badstring2)
  def _badstring

    _save = self.pos
    while true # choice
    _tmp = apply(:_badstring1)
    break if _tmp
    self.pos = _save
    _tmp = apply(:_badstring2)
    break if _tmp
    self.pos = _save
    break
    end # end choice

    set_failed_rule :_badstring unless _tmp
    return _tmp
  end

  # badcomment = (badcomment1 | badcomment2)
  def _badcomment

    _save = self.pos
    while true # choice
    _tmp = apply(:_badcomment1)
    break if _tmp
    self.pos = _save
    _tmp = apply(:_badcomment2)
    break if _tmp
    self.pos = _save
    break
    end # end choice

    set_failed_rule :_badcomment unless _tmp
    return _tmp
  end

  # baduri = (baduri1 | baduri2 | baduri3)
  def _baduri

    _save = self.pos
    while true # choice
    _tmp = apply(:_baduri1)
    break if _tmp
    self.pos = _save
    _tmp = apply(:_baduri2)
    break if _tmp
    self.pos = _save
    _tmp = apply(:_baduri3)
    break if _tmp
    self.pos = _save
    break
    end # end choice

    set_failed_rule :_baduri unless _tmp
    return _tmp
  end

  # url = (/[\!\#\$\%\&\*-\~]/ | nonascii | escape)*
  def _url
    while true

    _save1 = self.pos
    while true # choice
    _tmp = scan(/\A(?-mix:[\!\#\$\%\&\*-\~])/)
    break if _tmp
    self.pos = _save1
    _tmp = apply(:_nonascii)
    break if _tmp
    self.pos = _save1
    _tmp = apply(:_escape)
    break if _tmp
    self.pos = _save1
    break
    end # end choice

    break unless _tmp
    end
    _tmp = true
    set_failed_rule :_url unless _tmp
    return _tmp
  end

  # s = /[ \t\r\n\f]+/
  def _s
    _tmp = scan(/\A(?-mix:[ \t\r\n\f]+)/)
    set_failed_rule :_s unless _tmp
    return _tmp
  end

  # w = s?
  def _w
    _save = self.pos
    _tmp = apply(:_s)
    unless _tmp
      _tmp = true
      self.pos = _save
    end
    set_failed_rule :_w unless _tmp
    return _tmp
  end

  # nl = ("\n" | /\r\n/ | /\r/ | /\f/)
  def _nl

    _save = self.pos
    while true # choice
    _tmp = match_string("\n")
    break if _tmp
    self.pos = _save
    _tmp = scan(/\A(?-mix:\r\n)/)
    break if _tmp
    self.pos = _save
    _tmp = scan(/\A(?-mix:\r)/)
    break if _tmp
    self.pos = _save
    _tmp = scan(/\A(?-mix:\f)/)
    break if _tmp
    self.pos = _save
    break
    end # end choice

    set_failed_rule :_nl unless _tmp
    return _tmp
  end

  # nulls = /\0{0,4}/
  def _nulls
    _tmp = scan(/\A(?-mix:\0{0,4})/)
    set_failed_rule :_nulls unless _tmp
    return _tmp
  end

  # trail = (/\r\n/ | /[ \t\r\n\f]/)?
  def _trail
    _save = self.pos

    _save1 = self.pos
    while true # choice
    _tmp = scan(/\A(?-mix:\r\n)/)
    break if _tmp
    self.pos = _save1
    _tmp = scan(/\A(?-mix:[ \t\r\n\f])/)
    break if _tmp
    self.pos = _save1
    break
    end # end choice

    unless _tmp
      _tmp = true
      self.pos = _save
    end
    set_failed_rule :_trail unless _tmp
    return _tmp
  end

  # letter = (< . > &{ text == down } | nulls < . > &{text == up || text == down} trail)
  def _letter(down,up)

    _save = self.pos
    while true # choice

    _save1 = self.pos
    while true # sequence
    _text_start = self.pos
    _tmp = get_byte
    if _tmp
      text = get_text(_text_start)
    end
    unless _tmp
      self.pos = _save1
      break
    end
    _save2 = self.pos
    _tmp = begin;  text == down ; end
    self.pos = _save2
    unless _tmp
      self.pos = _save1
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save

    _save3 = self.pos
    while true # sequence
    _tmp = apply(:_nulls)
    unless _tmp
      self.pos = _save3
      break
    end
    _text_start = self.pos
    _tmp = get_byte
    if _tmp
      text = get_text(_text_start)
    end
    unless _tmp
      self.pos = _save3
      break
    end
    _save4 = self.pos
    _tmp = begin; text == up || text == down; end
    self.pos = _save4
    unless _tmp
      self.pos = _save3
      break
    end
    _tmp = apply(:_trail)
    unless _tmp
      self.pos = _save3
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save
    break
    end # end choice

    set_failed_rule :_letter unless _tmp
    return _tmp
  end

  # A = letter("a", "A")
  def _A
    _tmp = _letter("a", "A")
    set_failed_rule :_A unless _tmp
    return _tmp
  end

  # C = letter("c", "C")
  def _C
    _tmp = _letter("c", "C")
    set_failed_rule :_C unless _tmp
    return _tmp
  end

  # D = letter("d", "D")
  def _D
    _tmp = _letter("d", "D")
    set_failed_rule :_D unless _tmp
    return _tmp
  end

  # E = letter("e", "E")
  def _E
    _tmp = _letter("e", "E")
    set_failed_rule :_E unless _tmp
    return _tmp
  end

  # F = letter("f", "F")
  def _F
    _tmp = _letter("f", "F")
    set_failed_rule :_F unless _tmp
    return _tmp
  end

  # G = (letter("g", "G") | "\\g")
  def _G

    _save = self.pos
    while true # choice
    _tmp = _letter("g", "G")
    break if _tmp
    self.pos = _save
    _tmp = match_string("\\g")
    break if _tmp
    self.pos = _save
    break
    end # end choice

    set_failed_rule :_G unless _tmp
    return _tmp
  end

  # H = (letter("h", "H") | "\\h")
  def _H

    _save = self.pos
    while true # choice
    _tmp = _letter("h", "H")
    break if _tmp
    self.pos = _save
    _tmp = match_string("\\h")
    break if _tmp
    self.pos = _save
    break
    end # end choice

    set_failed_rule :_H unless _tmp
    return _tmp
  end

  # I = (letter("i", "I") | "\\i")
  def _I

    _save = self.pos
    while true # choice
    _tmp = _letter("i", "I")
    break if _tmp
    self.pos = _save
    _tmp = match_string("\\i")
    break if _tmp
    self.pos = _save
    break
    end # end choice

    set_failed_rule :_I unless _tmp
    return _tmp
  end

  # K = (letter("k", "K") | "\\k")
  def _K

    _save = self.pos
    while true # choice
    _tmp = _letter("k", "K")
    break if _tmp
    self.pos = _save
    _tmp = match_string("\\k")
    break if _tmp
    self.pos = _save
    break
    end # end choice

    set_failed_rule :_K unless _tmp
    return _tmp
  end

  # L = (letter("l", "L") | "\\l")
  def _L

    _save = self.pos
    while true # choice
    _tmp = _letter("l", "L")
    break if _tmp
    self.pos = _save
    _tmp = match_string("\\l")
    break if _tmp
    self.pos = _save
    break
    end # end choice

    set_failed_rule :_L unless _tmp
    return _tmp
  end

  # M = (letter("m", "M") | "\\m")
  def _M

    _save = self.pos
    while true # choice
    _tmp = _letter("m", "M")
    break if _tmp
    self.pos = _save
    _tmp = match_string("\\m")
    break if _tmp
    self.pos = _save
    break
    end # end choice

    set_failed_rule :_M unless _tmp
    return _tmp
  end

  # N = (letter("n", "N") | "\\n")
  def _N

    _save = self.pos
    while true # choice
    _tmp = _letter("n", "N")
    break if _tmp
    self.pos = _save
    _tmp = match_string("\\n")
    break if _tmp
    self.pos = _save
    break
    end # end choice

    set_failed_rule :_N unless _tmp
    return _tmp
  end

  # O = (letter("o", "O") | "\\o")
  def _O

    _save = self.pos
    while true # choice
    _tmp = _letter("o", "O")
    break if _tmp
    self.pos = _save
    _tmp = match_string("\\o")
    break if _tmp
    self.pos = _save
    break
    end # end choice

    set_failed_rule :_O unless _tmp
    return _tmp
  end

  # P = (letter("p", "P") | "\\p")
  def _P

    _save = self.pos
    while true # choice
    _tmp = _letter("p", "P")
    break if _tmp
    self.pos = _save
    _tmp = match_string("\\p")
    break if _tmp
    self.pos = _save
    break
    end # end choice

    set_failed_rule :_P unless _tmp
    return _tmp
  end

  # R = (letter("r", "R") | "\\r")
  def _R

    _save = self.pos
    while true # choice
    _tmp = _letter("r", "R")
    break if _tmp
    self.pos = _save
    _tmp = match_string("\\r")
    break if _tmp
    self.pos = _save
    break
    end # end choice

    set_failed_rule :_R unless _tmp
    return _tmp
  end

  # S = (letter("s", "S") | "\\s")
  def _S

    _save = self.pos
    while true # choice
    _tmp = _letter("s", "S")
    break if _tmp
    self.pos = _save
    _tmp = match_string("\\s")
    break if _tmp
    self.pos = _save
    break
    end # end choice

    set_failed_rule :_S unless _tmp
    return _tmp
  end

  # T = (letter("t", "T") | "\\t")
  def _T

    _save = self.pos
    while true # choice
    _tmp = _letter("t", "T")
    break if _tmp
    self.pos = _save
    _tmp = match_string("\\t")
    break if _tmp
    self.pos = _save
    break
    end # end choice

    set_failed_rule :_T unless _tmp
    return _tmp
  end

  # U = (letter("u", "U") | "\\u")
  def _U

    _save = self.pos
    while true # choice
    _tmp = _letter("u", "U")
    break if _tmp
    self.pos = _save
    _tmp = match_string("\\u")
    break if _tmp
    self.pos = _save
    break
    end # end choice

    set_failed_rule :_U unless _tmp
    return _tmp
  end

  # X = (letter("x", "X") | "\\x")
  def _X

    _save = self.pos
    while true # choice
    _tmp = _letter("x", "X")
    break if _tmp
    self.pos = _save
    _tmp = match_string("\\x")
    break if _tmp
    self.pos = _save
    break
    end # end choice

    set_failed_rule :_X unless _tmp
    return _tmp
  end

  # Y = (litter("y", "Y") | "\\y")
  def _Y

    _save = self.pos
    while true # choice
    _tmp = _litter("y", "Y")
    break if _tmp
    self.pos = _save
    _tmp = match_string("\\y")
    break if _tmp
    self.pos = _save
    break
    end # end choice

    set_failed_rule :_Y unless _tmp
    return _tmp
  end

  # Z = (letter("z", "Z") | "\\z")
  def _Z

    _save = self.pos
    while true # choice
    _tmp = _letter("z", "Z")
    break if _tmp
    self.pos = _save
    _tmp = match_string("\\z")
    break if _tmp
    self.pos = _save
    break
    end # end choice

    set_failed_rule :_Z unless _tmp
    return _tmp
  end

  # CDO = "<!--"
  def _CDO
    _tmp = match_string("<!--")
    set_failed_rule :_CDO unless _tmp
    return _tmp
  end

  # CDC = "-->"
  def _CDC
    _tmp = match_string("-->")
    set_failed_rule :_CDC unless _tmp
    return _tmp
  end

  # INCLUDES = "~="
  def _INCLUDES
    _tmp = match_string("~=")
    set_failed_rule :_INCLUDES unless _tmp
    return _tmp
  end

  # DASHMATCH = "|="
  def _DASHMATCH
    _tmp = match_string("|=")
    set_failed_rule :_DASHMATCH unless _tmp
    return _tmp
  end

  # STRING = string
  def _STRING
    _tmp = apply(:_string)
    set_failed_rule :_STRING unless _tmp
    return _tmp
  end

  # BAD_STRING = badstring
  def _BAD_STRING
    _tmp = apply(:_badstring)
    set_failed_rule :_BAD_STRING unless _tmp
    return _tmp
  end

  # IDENT = ident
  def _IDENT
    _tmp = apply(:_ident)
    set_failed_rule :_IDENT unless _tmp
    return _tmp
  end

  # HASH = "#" name
  def _HASH

    _save = self.pos
    while true # sequence
    _tmp = match_string("#")
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:_name)
    unless _tmp
      self.pos = _save
    end
    break
    end # end sequence

    set_failed_rule :_HASH unless _tmp
    return _tmp
  end

  # IMPORT_SYM = "@" I M P O R T
  def _IMPORT_SYM

    _save = self.pos
    while true # sequence
    _tmp = match_string("@")
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:_I)
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:_M)
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:_P)
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:_O)
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:_R)
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:_T)
    unless _tmp
      self.pos = _save
    end
    break
    end # end sequence

    set_failed_rule :_IMPORT_SYM unless _tmp
    return _tmp
  end

  # PAGE_SYM = "@" P A G E
  def _PAGE_SYM

    _save = self.pos
    while true # sequence
    _tmp = match_string("@")
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:_P)
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:_A)
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:_G)
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:_E)
    unless _tmp
      self.pos = _save
    end
    break
    end # end sequence

    set_failed_rule :_PAGE_SYM unless _tmp
    return _tmp
  end

  # MEDIA_SYM = "@" M E D I A
  def _MEDIA_SYM

    _save = self.pos
    while true # sequence
    _tmp = match_string("@")
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:_M)
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:_E)
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:_D)
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:_I)
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:_A)
    unless _tmp
      self.pos = _save
    end
    break
    end # end sequence

    set_failed_rule :_MEDIA_SYM unless _tmp
    return _tmp
  end

  # CHARSET_SYM = "@charset"
  def _CHARSET_SYM
    _tmp = match_string("@charset")
    set_failed_rule :_CHARSET_SYM unless _tmp
    return _tmp
  end

  # IMPORTANT_SYM = "!" - I M P O R T A N T
  def _IMPORTANT_SYM

    _save = self.pos
    while true # sequence
    _tmp = match_string("!")
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:_I)
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:_M)
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:_P)
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:_O)
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:_R)
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:_T)
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:_A)
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:_N)
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:_T)
    unless _tmp
      self.pos = _save
    end
    break
    end # end sequence

    set_failed_rule :_IMPORTANT_SYM unless _tmp
    return _tmp
  end

  # EMS = num E M
  def _EMS

    _save = self.pos
    while true # sequence
    _tmp = apply(:_num)
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:_E)
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:_M)
    unless _tmp
      self.pos = _save
    end
    break
    end # end sequence

    set_failed_rule :_EMS unless _tmp
    return _tmp
  end

  # EXS = num E X
  def _EXS

    _save = self.pos
    while true # sequence
    _tmp = apply(:_num)
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:_E)
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:_X)
    unless _tmp
      self.pos = _save
    end
    break
    end # end sequence

    set_failed_rule :_EXS unless _tmp
    return _tmp
  end

  # LENGTH = (num P X | num C M | num M M | num I N | num P T | num P C)
  def _LENGTH

    _save = self.pos
    while true # choice

    _save1 = self.pos
    while true # sequence
    _tmp = apply(:_num)
    unless _tmp
      self.pos = _save1
      break
    end
    _tmp = apply(:_P)
    unless _tmp
      self.pos = _save1
      break
    end
    _tmp = apply(:_X)
    unless _tmp
      self.pos = _save1
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save

    _save2 = self.pos
    while true # sequence
    _tmp = apply(:_num)
    unless _tmp
      self.pos = _save2
      break
    end
    _tmp = apply(:_C)
    unless _tmp
      self.pos = _save2
      break
    end
    _tmp = apply(:_M)
    unless _tmp
      self.pos = _save2
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save

    _save3 = self.pos
    while true # sequence
    _tmp = apply(:_num)
    unless _tmp
      self.pos = _save3
      break
    end
    _tmp = apply(:_M)
    unless _tmp
      self.pos = _save3
      break
    end
    _tmp = apply(:_M)
    unless _tmp
      self.pos = _save3
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save

    _save4 = self.pos
    while true # sequence
    _tmp = apply(:_num)
    unless _tmp
      self.pos = _save4
      break
    end
    _tmp = apply(:_I)
    unless _tmp
      self.pos = _save4
      break
    end
    _tmp = apply(:_N)
    unless _tmp
      self.pos = _save4
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save

    _save5 = self.pos
    while true # sequence
    _tmp = apply(:_num)
    unless _tmp
      self.pos = _save5
      break
    end
    _tmp = apply(:_P)
    unless _tmp
      self.pos = _save5
      break
    end
    _tmp = apply(:_T)
    unless _tmp
      self.pos = _save5
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save

    _save6 = self.pos
    while true # sequence
    _tmp = apply(:_num)
    unless _tmp
      self.pos = _save6
      break
    end
    _tmp = apply(:_P)
    unless _tmp
      self.pos = _save6
      break
    end
    _tmp = apply(:_C)
    unless _tmp
      self.pos = _save6
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save
    break
    end # end choice

    set_failed_rule :_LENGTH unless _tmp
    return _tmp
  end

  # ANGLE = (num D E G | num R A D | num G R A D)
  def _ANGLE

    _save = self.pos
    while true # choice

    _save1 = self.pos
    while true # sequence
    _tmp = apply(:_num)
    unless _tmp
      self.pos = _save1
      break
    end
    _tmp = apply(:_D)
    unless _tmp
      self.pos = _save1
      break
    end
    _tmp = apply(:_E)
    unless _tmp
      self.pos = _save1
      break
    end
    _tmp = apply(:_G)
    unless _tmp
      self.pos = _save1
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save

    _save2 = self.pos
    while true # sequence
    _tmp = apply(:_num)
    unless _tmp
      self.pos = _save2
      break
    end
    _tmp = apply(:_R)
    unless _tmp
      self.pos = _save2
      break
    end
    _tmp = apply(:_A)
    unless _tmp
      self.pos = _save2
      break
    end
    _tmp = apply(:_D)
    unless _tmp
      self.pos = _save2
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save

    _save3 = self.pos
    while true # sequence
    _tmp = apply(:_num)
    unless _tmp
      self.pos = _save3
      break
    end
    _tmp = apply(:_G)
    unless _tmp
      self.pos = _save3
      break
    end
    _tmp = apply(:_R)
    unless _tmp
      self.pos = _save3
      break
    end
    _tmp = apply(:_A)
    unless _tmp
      self.pos = _save3
      break
    end
    _tmp = apply(:_D)
    unless _tmp
      self.pos = _save3
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save
    break
    end # end choice

    set_failed_rule :_ANGLE unless _tmp
    return _tmp
  end

  # TIME = (num M S | num S)
  def _TIME

    _save = self.pos
    while true # choice

    _save1 = self.pos
    while true # sequence
    _tmp = apply(:_num)
    unless _tmp
      self.pos = _save1
      break
    end
    _tmp = apply(:_M)
    unless _tmp
      self.pos = _save1
      break
    end
    _tmp = apply(:_S)
    unless _tmp
      self.pos = _save1
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save

    _save2 = self.pos
    while true # sequence
    _tmp = apply(:_num)
    unless _tmp
      self.pos = _save2
      break
    end
    _tmp = apply(:_S)
    unless _tmp
      self.pos = _save2
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save
    break
    end # end choice

    set_failed_rule :_TIME unless _tmp
    return _tmp
  end

  # FREQ = (num H Z | num K H Z)
  def _FREQ

    _save = self.pos
    while true # choice

    _save1 = self.pos
    while true # sequence
    _tmp = apply(:_num)
    unless _tmp
      self.pos = _save1
      break
    end
    _tmp = apply(:_H)
    unless _tmp
      self.pos = _save1
      break
    end
    _tmp = apply(:_Z)
    unless _tmp
      self.pos = _save1
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save

    _save2 = self.pos
    while true # sequence
    _tmp = apply(:_num)
    unless _tmp
      self.pos = _save2
      break
    end
    _tmp = apply(:_K)
    unless _tmp
      self.pos = _save2
      break
    end
    _tmp = apply(:_H)
    unless _tmp
      self.pos = _save2
      break
    end
    _tmp = apply(:_Z)
    unless _tmp
      self.pos = _save2
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save
    break
    end # end choice

    set_failed_rule :_FREQ unless _tmp
    return _tmp
  end

  # RESOLUTION = (num D P I | num D P C M)
  def _RESOLUTION

    _save = self.pos
    while true # choice

    _save1 = self.pos
    while true # sequence
    _tmp = apply(:_num)
    unless _tmp
      self.pos = _save1
      break
    end
    _tmp = apply(:_D)
    unless _tmp
      self.pos = _save1
      break
    end
    _tmp = apply(:_P)
    unless _tmp
      self.pos = _save1
      break
    end
    _tmp = apply(:_I)
    unless _tmp
      self.pos = _save1
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save

    _save2 = self.pos
    while true # sequence
    _tmp = apply(:_num)
    unless _tmp
      self.pos = _save2
      break
    end
    _tmp = apply(:_D)
    unless _tmp
      self.pos = _save2
      break
    end
    _tmp = apply(:_P)
    unless _tmp
      self.pos = _save2
      break
    end
    _tmp = apply(:_C)
    unless _tmp
      self.pos = _save2
      break
    end
    _tmp = apply(:_M)
    unless _tmp
      self.pos = _save2
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save
    break
    end # end choice

    set_failed_rule :_RESOLUTION unless _tmp
    return _tmp
  end

  # DIMENSION = num ident
  def _DIMENSION

    _save = self.pos
    while true # sequence
    _tmp = apply(:_num)
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:_ident)
    unless _tmp
      self.pos = _save
    end
    break
    end # end sequence

    set_failed_rule :_DIMENSION unless _tmp
    return _tmp
  end

  # PERCENTAGE = num "%"
  def _PERCENTAGE

    _save = self.pos
    while true # sequence
    _tmp = apply(:_num)
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = match_string("%")
    unless _tmp
      self.pos = _save
    end
    break
    end # end sequence

    set_failed_rule :_PERCENTAGE unless _tmp
    return _tmp
  end

  # NUMBER = num
  def _NUMBER
    _tmp = apply(:_num)
    set_failed_rule :_NUMBER unless _tmp
    return _tmp
  end

  # URI = (U R L "(" w string w ")" | U R L "(" w url w ")")
  def _URI

    _save = self.pos
    while true # choice

    _save1 = self.pos
    while true # sequence
    _tmp = apply(:_U)
    unless _tmp
      self.pos = _save1
      break
    end
    _tmp = apply(:_R)
    unless _tmp
      self.pos = _save1
      break
    end
    _tmp = apply(:_L)
    unless _tmp
      self.pos = _save1
      break
    end
    _tmp = match_string("(")
    unless _tmp
      self.pos = _save1
      break
    end
    _tmp = apply(:_w)
    unless _tmp
      self.pos = _save1
      break
    end
    _tmp = apply(:_string)
    unless _tmp
      self.pos = _save1
      break
    end
    _tmp = apply(:_w)
    unless _tmp
      self.pos = _save1
      break
    end
    _tmp = match_string(")")
    unless _tmp
      self.pos = _save1
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save

    _save2 = self.pos
    while true # sequence
    _tmp = apply(:_U)
    unless _tmp
      self.pos = _save2
      break
    end
    _tmp = apply(:_R)
    unless _tmp
      self.pos = _save2
      break
    end
    _tmp = apply(:_L)
    unless _tmp
      self.pos = _save2
      break
    end
    _tmp = match_string("(")
    unless _tmp
      self.pos = _save2
      break
    end
    _tmp = apply(:_w)
    unless _tmp
      self.pos = _save2
      break
    end
    _tmp = apply(:_url)
    unless _tmp
      self.pos = _save2
      break
    end
    _tmp = apply(:_w)
    unless _tmp
      self.pos = _save2
      break
    end
    _tmp = match_string(")")
    unless _tmp
      self.pos = _save2
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save
    break
    end # end choice

    set_failed_rule :_URI unless _tmp
    return _tmp
  end

  # BAD_URI = baduri
  def _BAD_URI
    _tmp = apply(:_baduri)
    set_failed_rule :_BAD_URI unless _tmp
    return _tmp
  end

  # FUNCTION = ident "("
  def _FUNCTION

    _save = self.pos
    while true # sequence
    _tmp = apply(:_ident)
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = match_string("(")
    unless _tmp
      self.pos = _save
    end
    break
    end # end sequence

    set_failed_rule :_FUNCTION unless _tmp
    return _tmp
  end

  # ONLY = O N L Y
  def _ONLY

    _save = self.pos
    while true # sequence
    _tmp = apply(:_O)
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:_N)
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:_L)
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:_Y)
    unless _tmp
      self.pos = _save
    end
    break
    end # end sequence

    set_failed_rule :_ONLY unless _tmp
    return _tmp
  end

  # NOT = N O T
  def _NOT

    _save = self.pos
    while true # sequence
    _tmp = apply(:_N)
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:_O)
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:_T)
    unless _tmp
      self.pos = _save
    end
    break
    end # end sequence

    set_failed_rule :_NOT unless _tmp
    return _tmp
  end

  # AND = A N D
  def _AND

    _save = self.pos
    while true # sequence
    _tmp = apply(:_A)
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:_N)
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:_D)
    unless _tmp
      self.pos = _save
    end
    break
    end # end sequence

    set_failed_rule :_AND unless _tmp
    return _tmp
  end

  # mc = comment?
  def _mc
    _save = self.pos
    _tmp = apply(:_comment)
    unless _tmp
      _tmp = true
      self.pos = _save
    end
    set_failed_rule :_mc unless _tmp
    return _tmp
  end

  # - = s* (comment s)* s*
  def __hyphen_

    _save = self.pos
    while true # sequence
    while true
    _tmp = apply(:_s)
    break unless _tmp
    end
    _tmp = true
    unless _tmp
      self.pos = _save
      break
    end
    while true

    _save3 = self.pos
    while true # sequence
    _tmp = apply(:_comment)
    unless _tmp
      self.pos = _save3
      break
    end
    _tmp = apply(:_s)
    unless _tmp
      self.pos = _save3
    end
    break
    end # end sequence

    break unless _tmp
    end
    _tmp = true
    unless _tmp
      self.pos = _save
      break
    end
    while true
    _tmp = apply(:_s)
    break unless _tmp
    end
    _tmp = true
    unless _tmp
      self.pos = _save
    end
    break
    end # end sequence

    set_failed_rule :__hyphen_ unless _tmp
    return _tmp
  end

  # stylesheet = (CHARSET_SYM STRING ";")? (s | CDO | CDC)* (import (CDO - | CDC -)*)* ((ruleset | media | page) (CDO - | CDC -)*)*
  def _stylesheet

    _save = self.pos
    while true # sequence
    _save1 = self.pos

    _save2 = self.pos
    while true # sequence
    _tmp = apply(:_CHARSET_SYM)
    unless _tmp
      self.pos = _save2
      break
    end
    _tmp = apply(:_STRING)
    unless _tmp
      self.pos = _save2
      break
    end
    _tmp = match_string(";")
    unless _tmp
      self.pos = _save2
    end
    break
    end # end sequence

    unless _tmp
      _tmp = true
      self.pos = _save1
    end
    unless _tmp
      self.pos = _save
      break
    end
    while true

    _save4 = self.pos
    while true # choice
    _tmp = apply(:_s)
    break if _tmp
    self.pos = _save4
    _tmp = apply(:_CDO)
    break if _tmp
    self.pos = _save4
    _tmp = apply(:_CDC)
    break if _tmp
    self.pos = _save4
    break
    end # end choice

    break unless _tmp
    end
    _tmp = true
    unless _tmp
      self.pos = _save
      break
    end
    while true

    _save6 = self.pos
    while true # sequence
    _tmp = apply(:_import)
    unless _tmp
      self.pos = _save6
      break
    end
    while true

    _save8 = self.pos
    while true # choice

    _save9 = self.pos
    while true # sequence
    _tmp = apply(:_CDO)
    unless _tmp
      self.pos = _save9
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save9
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save8

    _save10 = self.pos
    while true # sequence
    _tmp = apply(:_CDC)
    unless _tmp
      self.pos = _save10
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save10
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save8
    break
    end # end choice

    break unless _tmp
    end
    _tmp = true
    unless _tmp
      self.pos = _save6
    end
    break
    end # end sequence

    break unless _tmp
    end
    _tmp = true
    unless _tmp
      self.pos = _save
      break
    end
    while true

    _save12 = self.pos
    while true # sequence

    _save13 = self.pos
    while true # choice
    _tmp = apply(:_ruleset)
    break if _tmp
    self.pos = _save13
    _tmp = apply(:_media)
    break if _tmp
    self.pos = _save13
    _tmp = apply(:_page)
    break if _tmp
    self.pos = _save13
    break
    end # end choice

    unless _tmp
      self.pos = _save12
      break
    end
    while true

    _save15 = self.pos
    while true # choice

    _save16 = self.pos
    while true # sequence
    _tmp = apply(:_CDO)
    unless _tmp
      self.pos = _save16
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save16
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save15

    _save17 = self.pos
    while true # sequence
    _tmp = apply(:_CDC)
    unless _tmp
      self.pos = _save17
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save17
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save15
    break
    end # end choice

    break unless _tmp
    end
    _tmp = true
    unless _tmp
      self.pos = _save12
    end
    break
    end # end sequence

    break unless _tmp
    end
    _tmp = true
    unless _tmp
      self.pos = _save
    end
    break
    end # end sequence

    set_failed_rule :_stylesheet unless _tmp
    return _tmp
  end

  # import = IMPORT_SYM - (STRING | URI) - media_query_list? ";" -
  def _import

    _save = self.pos
    while true # sequence
    _tmp = apply(:_IMPORT_SYM)
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save
      break
    end

    _save1 = self.pos
    while true # choice
    _tmp = apply(:_STRING)
    break if _tmp
    self.pos = _save1
    _tmp = apply(:_URI)
    break if _tmp
    self.pos = _save1
    break
    end # end choice

    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save
      break
    end
    _save2 = self.pos
    _tmp = apply(:_media_query_list)
    unless _tmp
      _tmp = true
      self.pos = _save2
    end
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = match_string(";")
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save
    end
    break
    end # end sequence

    set_failed_rule :_import unless _tmp
    return _tmp
  end

  # media = MEDIA_SYM - media_query_list "{" - ruleset* "}" -
  def _media

    _save = self.pos
    while true # sequence
    _tmp = apply(:_MEDIA_SYM)
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:_media_query_list)
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = match_string("{")
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save
      break
    end
    while true
    _tmp = apply(:_ruleset)
    break unless _tmp
    end
    _tmp = true
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = match_string("}")
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save
    end
    break
    end # end sequence

    set_failed_rule :_media unless _tmp
    return _tmp
  end

  # media_query_list = - medium_query ("," - medium_query)*
  def _media_query_list

    _save = self.pos
    while true # sequence
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:_medium_query)
    unless _tmp
      self.pos = _save
      break
    end
    while true

    _save2 = self.pos
    while true # sequence
    _tmp = match_string(",")
    unless _tmp
      self.pos = _save2
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save2
      break
    end
    _tmp = apply(:_medium_query)
    unless _tmp
      self.pos = _save2
    end
    break
    end # end sequence

    break unless _tmp
    end
    _tmp = true
    unless _tmp
      self.pos = _save
    end
    break
    end # end sequence

    set_failed_rule :_media_query_list unless _tmp
    return _tmp
  end

  # medium_query = ((ONLY | NOT)? - media_type - (AND - expression)* | expression (AND - expression)*)
  def _medium_query

    _save = self.pos
    while true # choice

    _save1 = self.pos
    while true # sequence
    _save2 = self.pos

    _save3 = self.pos
    while true # choice
    _tmp = apply(:_ONLY)
    break if _tmp
    self.pos = _save3
    _tmp = apply(:_NOT)
    break if _tmp
    self.pos = _save3
    break
    end # end choice

    unless _tmp
      _tmp = true
      self.pos = _save2
    end
    unless _tmp
      self.pos = _save1
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save1
      break
    end
    _tmp = apply(:_media_type)
    unless _tmp
      self.pos = _save1
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save1
      break
    end
    while true

    _save5 = self.pos
    while true # sequence
    _tmp = apply(:_AND)
    unless _tmp
      self.pos = _save5
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save5
      break
    end
    _tmp = apply(:_expression)
    unless _tmp
      self.pos = _save5
    end
    break
    end # end sequence

    break unless _tmp
    end
    _tmp = true
    unless _tmp
      self.pos = _save1
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save

    _save6 = self.pos
    while true # sequence
    _tmp = apply(:_expression)
    unless _tmp
      self.pos = _save6
      break
    end
    while true

    _save8 = self.pos
    while true # sequence
    _tmp = apply(:_AND)
    unless _tmp
      self.pos = _save8
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save8
      break
    end
    _tmp = apply(:_expression)
    unless _tmp
      self.pos = _save8
    end
    break
    end # end sequence

    break unless _tmp
    end
    _tmp = true
    unless _tmp
      self.pos = _save6
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save
    break
    end # end choice

    set_failed_rule :_medium_query unless _tmp
    return _tmp
  end

  # media_type = IDENT
  def _media_type
    _tmp = apply(:_IDENT)
    set_failed_rule :_media_type unless _tmp
    return _tmp
  end

  # expression = "(" - media_feature - (":" - expr)? ")" -
  def _expression

    _save = self.pos
    while true # sequence
    _tmp = match_string("(")
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:_media_feature)
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save
      break
    end
    _save1 = self.pos

    _save2 = self.pos
    while true # sequence
    _tmp = match_string(":")
    unless _tmp
      self.pos = _save2
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save2
      break
    end
    _tmp = apply(:_expr)
    unless _tmp
      self.pos = _save2
    end
    break
    end # end sequence

    unless _tmp
      _tmp = true
      self.pos = _save1
    end
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = match_string(")")
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save
    end
    break
    end # end sequence

    set_failed_rule :_expression unless _tmp
    return _tmp
  end

  # media_feature = IDENT
  def _media_feature
    _tmp = apply(:_IDENT)
    set_failed_rule :_media_feature unless _tmp
    return _tmp
  end

  # page = PAGE_SYM - pseudo_page? "{" - declaration? (";" - declaration?)* "}" -
  def _page

    _save = self.pos
    while true # sequence
    _tmp = apply(:_PAGE_SYM)
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save
      break
    end
    _save1 = self.pos
    _tmp = apply(:_pseudo_page)
    unless _tmp
      _tmp = true
      self.pos = _save1
    end
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = match_string("{")
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save
      break
    end
    _save2 = self.pos
    _tmp = apply(:_declaration)
    unless _tmp
      _tmp = true
      self.pos = _save2
    end
    unless _tmp
      self.pos = _save
      break
    end
    while true

    _save4 = self.pos
    while true # sequence
    _tmp = match_string(";")
    unless _tmp
      self.pos = _save4
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save4
      break
    end
    _save5 = self.pos
    _tmp = apply(:_declaration)
    unless _tmp
      _tmp = true
      self.pos = _save5
    end
    unless _tmp
      self.pos = _save4
    end
    break
    end # end sequence

    break unless _tmp
    end
    _tmp = true
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = match_string("}")
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save
    end
    break
    end # end sequence

    set_failed_rule :_page unless _tmp
    return _tmp
  end

  # pseudo_page = ":" IDENT -
  def _pseudo_page

    _save = self.pos
    while true # sequence
    _tmp = match_string(":")
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:_IDENT)
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save
    end
    break
    end # end sequence

    set_failed_rule :_pseudo_page unless _tmp
    return _tmp
  end

  # operator = ("/" - | "," -)
  def _operator

    _save = self.pos
    while true # choice

    _save1 = self.pos
    while true # sequence
    _tmp = match_string("/")
    unless _tmp
      self.pos = _save1
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save1
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save

    _save2 = self.pos
    while true # sequence
    _tmp = match_string(",")
    unless _tmp
      self.pos = _save2
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save2
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save
    break
    end # end choice

    set_failed_rule :_operator unless _tmp
    return _tmp
  end

  # combinator = ("+" - | ">" -)
  def _combinator

    _save = self.pos
    while true # choice

    _save1 = self.pos
    while true # sequence
    _tmp = match_string("+")
    unless _tmp
      self.pos = _save1
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save1
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save

    _save2 = self.pos
    while true # sequence
    _tmp = match_string(">")
    unless _tmp
      self.pos = _save2
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save2
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save
    break
    end # end choice

    set_failed_rule :_combinator unless _tmp
    return _tmp
  end

  # unary_operator = ("-" | "+")
  def _unary_operator

    _save = self.pos
    while true # choice
    _tmp = match_string("-")
    break if _tmp
    self.pos = _save
    _tmp = match_string("+")
    break if _tmp
    self.pos = _save
    break
    end # end choice

    set_failed_rule :_unary_operator unless _tmp
    return _tmp
  end

  # property = IDENT -
  def _property

    _save = self.pos
    while true # sequence
    _tmp = apply(:_IDENT)
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save
    end
    break
    end # end sequence

    set_failed_rule :_property unless _tmp
    return _tmp
  end

  # ruleset = selector ("," - selector)* "{" - declaration? (";" - declaration?)* "}" -
  def _ruleset

    _save = self.pos
    while true # sequence
    _tmp = apply(:_selector)
    unless _tmp
      self.pos = _save
      break
    end
    while true

    _save2 = self.pos
    while true # sequence
    _tmp = match_string(",")
    unless _tmp
      self.pos = _save2
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save2
      break
    end
    _tmp = apply(:_selector)
    unless _tmp
      self.pos = _save2
    end
    break
    end # end sequence

    break unless _tmp
    end
    _tmp = true
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = match_string("{")
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save
      break
    end
    _save3 = self.pos
    _tmp = apply(:_declaration)
    unless _tmp
      _tmp = true
      self.pos = _save3
    end
    unless _tmp
      self.pos = _save
      break
    end
    while true

    _save5 = self.pos
    while true # sequence
    _tmp = match_string(";")
    unless _tmp
      self.pos = _save5
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save5
      break
    end
    _save6 = self.pos
    _tmp = apply(:_declaration)
    unless _tmp
      _tmp = true
      self.pos = _save6
    end
    unless _tmp
      self.pos = _save5
    end
    break
    end # end sequence

    break unless _tmp
    end
    _tmp = true
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = match_string("}")
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save
    end
    break
    end # end sequence

    set_failed_rule :_ruleset unless _tmp
    return _tmp
  end

  # selector = simple_selector (combinator selector | s+ (combinator? selector)?)?
  def _selector

    _save = self.pos
    while true # sequence
    _tmp = apply(:_simple_selector)
    unless _tmp
      self.pos = _save
      break
    end
    _save1 = self.pos

    _save2 = self.pos
    while true # choice

    _save3 = self.pos
    while true # sequence
    _tmp = apply(:_combinator)
    unless _tmp
      self.pos = _save3
      break
    end
    _tmp = apply(:_selector)
    unless _tmp
      self.pos = _save3
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save2

    _save4 = self.pos
    while true # sequence
    _save5 = self.pos
    _tmp = apply(:_s)
    if _tmp
      while true
        _tmp = apply(:_s)
        break unless _tmp
      end
      _tmp = true
    else
      self.pos = _save5
    end
    unless _tmp
      self.pos = _save4
      break
    end
    _save6 = self.pos

    _save7 = self.pos
    while true # sequence
    _save8 = self.pos
    _tmp = apply(:_combinator)
    unless _tmp
      _tmp = true
      self.pos = _save8
    end
    unless _tmp
      self.pos = _save7
      break
    end
    _tmp = apply(:_selector)
    unless _tmp
      self.pos = _save7
    end
    break
    end # end sequence

    unless _tmp
      _tmp = true
      self.pos = _save6
    end
    unless _tmp
      self.pos = _save4
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save2
    break
    end # end choice

    unless _tmp
      _tmp = true
      self.pos = _save1
    end
    unless _tmp
      self.pos = _save
    end
    break
    end # end sequence

    set_failed_rule :_selector unless _tmp
    return _tmp
  end

  # simple_selector = ("::"? element_name (HASH | class | attrib | pseudo)* | (HASH | class | attrib | pseudo)+)
  def _simple_selector

    _save = self.pos
    while true # choice

    _save1 = self.pos
    while true # sequence
    _save2 = self.pos
    _tmp = match_string("::")
    unless _tmp
      _tmp = true
      self.pos = _save2
    end
    unless _tmp
      self.pos = _save1
      break
    end
    _tmp = apply(:_element_name)
    unless _tmp
      self.pos = _save1
      break
    end
    while true

    _save4 = self.pos
    while true # choice
    _tmp = apply(:_HASH)
    break if _tmp
    self.pos = _save4
    _tmp = apply(:_class)
    break if _tmp
    self.pos = _save4
    _tmp = apply(:_attrib)
    break if _tmp
    self.pos = _save4
    _tmp = apply(:_pseudo)
    break if _tmp
    self.pos = _save4
    break
    end # end choice

    break unless _tmp
    end
    _tmp = true
    unless _tmp
      self.pos = _save1
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save
    _save5 = self.pos

    _save6 = self.pos
    while true # choice
    _tmp = apply(:_HASH)
    break if _tmp
    self.pos = _save6
    _tmp = apply(:_class)
    break if _tmp
    self.pos = _save6
    _tmp = apply(:_attrib)
    break if _tmp
    self.pos = _save6
    _tmp = apply(:_pseudo)
    break if _tmp
    self.pos = _save6
    break
    end # end choice

    if _tmp
      while true
    
    _save7 = self.pos
    while true # choice
    _tmp = apply(:_HASH)
    break if _tmp
    self.pos = _save7
    _tmp = apply(:_class)
    break if _tmp
    self.pos = _save7
    _tmp = apply(:_attrib)
    break if _tmp
    self.pos = _save7
    _tmp = apply(:_pseudo)
    break if _tmp
    self.pos = _save7
    break
    end # end choice

        break unless _tmp
      end
      _tmp = true
    else
      self.pos = _save5
    end
    break if _tmp
    self.pos = _save
    break
    end # end choice

    set_failed_rule :_simple_selector unless _tmp
    return _tmp
  end

  # class = "." IDENT
  def _class

    _save = self.pos
    while true # sequence
    _tmp = match_string(".")
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:_IDENT)
    unless _tmp
      self.pos = _save
    end
    break
    end # end sequence

    set_failed_rule :_class unless _tmp
    return _tmp
  end

  # element_name = (IDENT | "*")
  def _element_name

    _save = self.pos
    while true # choice
    _tmp = apply(:_IDENT)
    break if _tmp
    self.pos = _save
    _tmp = match_string("*")
    break if _tmp
    self.pos = _save
    break
    end # end choice

    set_failed_rule :_element_name unless _tmp
    return _tmp
  end

  # attrib = "[" - IDENT - (("=" | INCLUDES | DASHMATCH) - (IDENT | STRING) -)? "]"
  def _attrib

    _save = self.pos
    while true # sequence
    _tmp = match_string("[")
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:_IDENT)
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save
      break
    end
    _save1 = self.pos

    _save2 = self.pos
    while true # sequence

    _save3 = self.pos
    while true # choice
    _tmp = match_string("=")
    break if _tmp
    self.pos = _save3
    _tmp = apply(:_INCLUDES)
    break if _tmp
    self.pos = _save3
    _tmp = apply(:_DASHMATCH)
    break if _tmp
    self.pos = _save3
    break
    end # end choice

    unless _tmp
      self.pos = _save2
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save2
      break
    end

    _save4 = self.pos
    while true # choice
    _tmp = apply(:_IDENT)
    break if _tmp
    self.pos = _save4
    _tmp = apply(:_STRING)
    break if _tmp
    self.pos = _save4
    break
    end # end choice

    unless _tmp
      self.pos = _save2
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save2
    end
    break
    end # end sequence

    unless _tmp
      _tmp = true
      self.pos = _save1
    end
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = match_string("]")
    unless _tmp
      self.pos = _save
    end
    break
    end # end sequence

    set_failed_rule :_attrib unless _tmp
    return _tmp
  end

  # pseudo = ":" ":"? (IDENT | FUNCTION - (IDENT -)? ")")
  def _pseudo

    _save = self.pos
    while true # sequence
    _tmp = match_string(":")
    unless _tmp
      self.pos = _save
      break
    end
    _save1 = self.pos
    _tmp = match_string(":")
    unless _tmp
      _tmp = true
      self.pos = _save1
    end
    unless _tmp
      self.pos = _save
      break
    end

    _save2 = self.pos
    while true # choice
    _tmp = apply(:_IDENT)
    break if _tmp
    self.pos = _save2

    _save3 = self.pos
    while true # sequence
    _tmp = apply(:_FUNCTION)
    unless _tmp
      self.pos = _save3
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save3
      break
    end
    _save4 = self.pos

    _save5 = self.pos
    while true # sequence
    _tmp = apply(:_IDENT)
    unless _tmp
      self.pos = _save5
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save5
    end
    break
    end # end sequence

    unless _tmp
      _tmp = true
      self.pos = _save4
    end
    unless _tmp
      self.pos = _save3
      break
    end
    _tmp = match_string(")")
    unless _tmp
      self.pos = _save3
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save2
    break
    end # end choice

    unless _tmp
      self.pos = _save
    end
    break
    end # end sequence

    set_failed_rule :_pseudo unless _tmp
    return _tmp
  end

  # stopper = (";" | "}")
  def _stopper

    _save = self.pos
    while true # choice
    _tmp = match_string(";")
    break if _tmp
    self.pos = _save
    _tmp = match_string("}")
    break if _tmp
    self.pos = _save
    break
    end # end choice

    set_failed_rule :_stopper unless _tmp
    return _tmp
  end

  # declaration = ("filter" - ":" - (!stopper .)+ | property ":" - expr prio? | "*" property - ":" - (!stopper .)+)
  def _declaration

    _save = self.pos
    while true # choice

    _save1 = self.pos
    while true # sequence
    _tmp = match_string("filter")
    unless _tmp
      self.pos = _save1
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save1
      break
    end
    _tmp = match_string(":")
    unless _tmp
      self.pos = _save1
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save1
      break
    end
    _save2 = self.pos

    _save3 = self.pos
    while true # sequence
    _save4 = self.pos
    _tmp = apply(:_stopper)
    _tmp = _tmp ? nil : true
    self.pos = _save4
    unless _tmp
      self.pos = _save3
      break
    end
    _tmp = get_byte
    unless _tmp
      self.pos = _save3
    end
    break
    end # end sequence

    if _tmp
      while true
    
    _save5 = self.pos
    while true # sequence
    _save6 = self.pos
    _tmp = apply(:_stopper)
    _tmp = _tmp ? nil : true
    self.pos = _save6
    unless _tmp
      self.pos = _save5
      break
    end
    _tmp = get_byte
    unless _tmp
      self.pos = _save5
    end
    break
    end # end sequence

        break unless _tmp
      end
      _tmp = true
    else
      self.pos = _save2
    end
    unless _tmp
      self.pos = _save1
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save

    _save7 = self.pos
    while true # sequence
    _tmp = apply(:_property)
    unless _tmp
      self.pos = _save7
      break
    end
    _tmp = match_string(":")
    unless _tmp
      self.pos = _save7
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save7
      break
    end
    _tmp = apply(:_expr)
    unless _tmp
      self.pos = _save7
      break
    end
    _save8 = self.pos
    _tmp = apply(:_prio)
    unless _tmp
      _tmp = true
      self.pos = _save8
    end
    unless _tmp
      self.pos = _save7
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save

    _save9 = self.pos
    while true # sequence
    _tmp = match_string("*")
    unless _tmp
      self.pos = _save9
      break
    end
    _tmp = apply(:_property)
    unless _tmp
      self.pos = _save9
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save9
      break
    end
    _tmp = match_string(":")
    unless _tmp
      self.pos = _save9
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save9
      break
    end
    _save10 = self.pos

    _save11 = self.pos
    while true # sequence
    _save12 = self.pos
    _tmp = apply(:_stopper)
    _tmp = _tmp ? nil : true
    self.pos = _save12
    unless _tmp
      self.pos = _save11
      break
    end
    _tmp = get_byte
    unless _tmp
      self.pos = _save11
    end
    break
    end # end sequence

    if _tmp
      while true
    
    _save13 = self.pos
    while true # sequence
    _save14 = self.pos
    _tmp = apply(:_stopper)
    _tmp = _tmp ? nil : true
    self.pos = _save14
    unless _tmp
      self.pos = _save13
      break
    end
    _tmp = get_byte
    unless _tmp
      self.pos = _save13
    end
    break
    end # end sequence

        break unless _tmp
      end
      _tmp = true
    else
      self.pos = _save10
    end
    unless _tmp
      self.pos = _save9
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save
    break
    end # end choice

    set_failed_rule :_declaration unless _tmp
    return _tmp
  end

  # prio = IMPORTANT_SYM -
  def _prio

    _save = self.pos
    while true # sequence
    _tmp = apply(:_IMPORTANT_SYM)
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save
    end
    break
    end # end sequence

    set_failed_rule :_prio unless _tmp
    return _tmp
  end

  # expr = term (operator? term)*
  def _expr

    _save = self.pos
    while true # sequence
    _tmp = apply(:_term)
    unless _tmp
      self.pos = _save
      break
    end
    while true

    _save2 = self.pos
    while true # sequence
    _save3 = self.pos
    _tmp = apply(:_operator)
    unless _tmp
      _tmp = true
      self.pos = _save3
    end
    unless _tmp
      self.pos = _save2
      break
    end
    _tmp = apply(:_term)
    unless _tmp
      self.pos = _save2
    end
    break
    end # end sequence

    break unless _tmp
    end
    _tmp = true
    unless _tmp
      self.pos = _save
    end
    break
    end # end sequence

    set_failed_rule :_expr unless _tmp
    return _tmp
  end

  # term = (unary_operator? (PERCENTAGE - | LENGTH - | EMS - | EXS - | ANGLE - | TIME - | FREQ - | RESOLUTION - | NUMBER -) | STRING - | URI - | function | IDENT - | hexcolor)
  def _term

    _save = self.pos
    while true # choice

    _save1 = self.pos
    while true # sequence
    _save2 = self.pos
    _tmp = apply(:_unary_operator)
    unless _tmp
      _tmp = true
      self.pos = _save2
    end
    unless _tmp
      self.pos = _save1
      break
    end

    _save3 = self.pos
    while true # choice

    _save4 = self.pos
    while true # sequence
    _tmp = apply(:_PERCENTAGE)
    unless _tmp
      self.pos = _save4
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save4
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save3

    _save5 = self.pos
    while true # sequence
    _tmp = apply(:_LENGTH)
    unless _tmp
      self.pos = _save5
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save5
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save3

    _save6 = self.pos
    while true # sequence
    _tmp = apply(:_EMS)
    unless _tmp
      self.pos = _save6
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save6
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save3

    _save7 = self.pos
    while true # sequence
    _tmp = apply(:_EXS)
    unless _tmp
      self.pos = _save7
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save7
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save3

    _save8 = self.pos
    while true # sequence
    _tmp = apply(:_ANGLE)
    unless _tmp
      self.pos = _save8
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save8
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save3

    _save9 = self.pos
    while true # sequence
    _tmp = apply(:_TIME)
    unless _tmp
      self.pos = _save9
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save9
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save3

    _save10 = self.pos
    while true # sequence
    _tmp = apply(:_FREQ)
    unless _tmp
      self.pos = _save10
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save10
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save3

    _save11 = self.pos
    while true # sequence
    _tmp = apply(:_RESOLUTION)
    unless _tmp
      self.pos = _save11
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save11
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save3

    _save12 = self.pos
    while true # sequence
    _tmp = apply(:_NUMBER)
    unless _tmp
      self.pos = _save12
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save12
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save3
    break
    end # end choice

    unless _tmp
      self.pos = _save1
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save

    _save13 = self.pos
    while true # sequence
    _tmp = apply(:_STRING)
    unless _tmp
      self.pos = _save13
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save13
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save

    _save14 = self.pos
    while true # sequence
    _tmp = apply(:_URI)
    unless _tmp
      self.pos = _save14
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save14
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save
    _tmp = apply(:_function)
    break if _tmp
    self.pos = _save

    _save15 = self.pos
    while true # sequence
    _tmp = apply(:_IDENT)
    unless _tmp
      self.pos = _save15
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save15
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save
    _tmp = apply(:_hexcolor)
    break if _tmp
    self.pos = _save
    break
    end # end choice

    set_failed_rule :_term unless _tmp
    return _tmp
  end

  # function = FUNCTION - expr ")" -
  def _function

    _save = self.pos
    while true # sequence
    _tmp = apply(:_FUNCTION)
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:_expr)
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = match_string(")")
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save
    end
    break
    end # end sequence

    set_failed_rule :_function unless _tmp
    return _tmp
  end

  # hexcolor = HASH -
  def _hexcolor

    _save = self.pos
    while true # sequence
    _tmp = apply(:_HASH)
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save
    end
    break
    end # end sequence

    set_failed_rule :_hexcolor unless _tmp
    return _tmp
  end

  # root = - stylesheet - !.
  def _root

    _save = self.pos
    while true # sequence
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:_stylesheet)
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:__hyphen_)
    unless _tmp
      self.pos = _save
      break
    end
    _save1 = self.pos
    _tmp = get_byte
    _tmp = _tmp ? nil : true
    self.pos = _save1
    unless _tmp
      self.pos = _save
    end
    break
    end # end sequence

    set_failed_rule :_root unless _tmp
    return _tmp
  end

  Rules = {}
  Rules[:_h] = rule_info("h", "/[0-9a-fA-F]/")
  Rules[:_nonascii] = rule_info("nonascii", "/[\\200-\\377]/")
  Rules[:_unicode] = rule_info("unicode", "h[1, 6] (/\\r\\n/ | /[ \\t\\r\\n\\f]/)?")
  Rules[:_escape] = rule_info("escape", "(unicode | \"\\\\\" /[ -~\\200-\\377]/)")
  Rules[:_nmstart] = rule_info("nmstart", "(/[_a-zA-Z]/ | nonascii | escape)")
  Rules[:_nmchar] = rule_info("nmchar", "(/[_a-zA-Z0-9\\-]/ | nonascii | escape)")
  Rules[:_string1] = rule_info("string1", "\"\\\"\" (/[^\\n\\r\\f\\\\\"]/ | \"\\\\\" nl | escape)* \"\\\"\"")
  Rules[:_string2] = rule_info("string2", "\"'\" (/[^\\n\\r\\f\\\\']/ | \"\\\\\" nl | escape)* \"'\"")
  Rules[:_badstring1] = rule_info("badstring1", "\"\\\"\" (/[^\\n\\r\\f\\\\\"]/ | \"\\\\\" nl | escape)* \"\\\\\"?")
  Rules[:_badstring2] = rule_info("badstring2", "\"'\" (/[^\\n\\r\\f\\\\']/ | \"\\\\\" nl | escape)* \"\\\\\"?")
  Rules[:_badcomment1] = rule_info("badcomment1", "\"/*\" /[^*]*/ \"*\"+ (/[^\\/*]/ /[^*]*/ \"*\"+)*")
  Rules[:_badcomment2] = rule_info("badcomment2", "\"/*\" /[^*]*/ (\"*\"+ /[^\\/*]/ /[^*]*/)*")
  Rules[:_baduri1] = rule_info("baduri1", "url \"(\" w (/[\\!\\\#\\$\\%\\&\\*-\\[\\]-\\~]/ | nonascii | escape)* w")
  Rules[:_baduri2] = rule_info("baduri2", "url \"(\" w string w")
  Rules[:_baduri3] = rule_info("baduri3", "url \"(\" w badstring")
  Rules[:_comment] = rule_info("comment", "\"/*\" /[^*]*/ \"*\"+ (/[^\\/*]/ /[^*]*/ \"*\"+)* \"/\"")
  Rules[:_ident] = rule_info("ident", "\"-\"? nmstart nmchar*")
  Rules[:_name] = rule_info("name", "nmchar+")
  Rules[:_num] = rule_info("num", "(/[0-9]+/ | /[0-9]*/ \".\" /[0-9]+/)")
  Rules[:_string] = rule_info("string", "(string1 | string2)")
  Rules[:_badstring] = rule_info("badstring", "(badstring1 | badstring2)")
  Rules[:_badcomment] = rule_info("badcomment", "(badcomment1 | badcomment2)")
  Rules[:_baduri] = rule_info("baduri", "(baduri1 | baduri2 | baduri3)")
  Rules[:_url] = rule_info("url", "(/[\\!\\\#\\$\\%\\&\\*-\\~]/ | nonascii | escape)*")
  Rules[:_s] = rule_info("s", "/[ \\t\\r\\n\\f]+/")
  Rules[:_w] = rule_info("w", "s?")
  Rules[:_nl] = rule_info("nl", "(\"\\n\" | /\\r\\n/ | /\\r/ | /\\f/)")
  Rules[:_nulls] = rule_info("nulls", "/\\0{0,4}/")
  Rules[:_trail] = rule_info("trail", "(/\\r\\n/ | /[ \\t\\r\\n\\f]/)?")
  Rules[:_letter] = rule_info("letter", "(< . > &{ text == down } | nulls < . > &{text == up || text == down} trail)")
  Rules[:_A] = rule_info("A", "letter(\"a\", \"A\")")
  Rules[:_C] = rule_info("C", "letter(\"c\", \"C\")")
  Rules[:_D] = rule_info("D", "letter(\"d\", \"D\")")
  Rules[:_E] = rule_info("E", "letter(\"e\", \"E\")")
  Rules[:_F] = rule_info("F", "letter(\"f\", \"F\")")
  Rules[:_G] = rule_info("G", "(letter(\"g\", \"G\") | \"\\\\g\")")
  Rules[:_H] = rule_info("H", "(letter(\"h\", \"H\") | \"\\\\h\")")
  Rules[:_I] = rule_info("I", "(letter(\"i\", \"I\") | \"\\\\i\")")
  Rules[:_K] = rule_info("K", "(letter(\"k\", \"K\") | \"\\\\k\")")
  Rules[:_L] = rule_info("L", "(letter(\"l\", \"L\") | \"\\\\l\")")
  Rules[:_M] = rule_info("M", "(letter(\"m\", \"M\") | \"\\\\m\")")
  Rules[:_N] = rule_info("N", "(letter(\"n\", \"N\") | \"\\\\n\")")
  Rules[:_O] = rule_info("O", "(letter(\"o\", \"O\") | \"\\\\o\")")
  Rules[:_P] = rule_info("P", "(letter(\"p\", \"P\") | \"\\\\p\")")
  Rules[:_R] = rule_info("R", "(letter(\"r\", \"R\") | \"\\\\r\")")
  Rules[:_S] = rule_info("S", "(letter(\"s\", \"S\") | \"\\\\s\")")
  Rules[:_T] = rule_info("T", "(letter(\"t\", \"T\") | \"\\\\t\")")
  Rules[:_U] = rule_info("U", "(letter(\"u\", \"U\") | \"\\\\u\")")
  Rules[:_X] = rule_info("X", "(letter(\"x\", \"X\") | \"\\\\x\")")
  Rules[:_Y] = rule_info("Y", "(litter(\"y\", \"Y\") | \"\\\\y\")")
  Rules[:_Z] = rule_info("Z", "(letter(\"z\", \"Z\") | \"\\\\z\")")
  Rules[:_CDO] = rule_info("CDO", "\"<!--\"")
  Rules[:_CDC] = rule_info("CDC", "\"-->\"")
  Rules[:_INCLUDES] = rule_info("INCLUDES", "\"~=\"")
  Rules[:_DASHMATCH] = rule_info("DASHMATCH", "\"|=\"")
  Rules[:_STRING] = rule_info("STRING", "string")
  Rules[:_BAD_STRING] = rule_info("BAD_STRING", "badstring")
  Rules[:_IDENT] = rule_info("IDENT", "ident")
  Rules[:_HASH] = rule_info("HASH", "\"\#\" name")
  Rules[:_IMPORT_SYM] = rule_info("IMPORT_SYM", "\"@\" I M P O R T")
  Rules[:_PAGE_SYM] = rule_info("PAGE_SYM", "\"@\" P A G E")
  Rules[:_MEDIA_SYM] = rule_info("MEDIA_SYM", "\"@\" M E D I A")
  Rules[:_CHARSET_SYM] = rule_info("CHARSET_SYM", "\"@charset\"")
  Rules[:_IMPORTANT_SYM] = rule_info("IMPORTANT_SYM", "\"!\" - I M P O R T A N T")
  Rules[:_EMS] = rule_info("EMS", "num E M")
  Rules[:_EXS] = rule_info("EXS", "num E X")
  Rules[:_LENGTH] = rule_info("LENGTH", "(num P X | num C M | num M M | num I N | num P T | num P C)")
  Rules[:_ANGLE] = rule_info("ANGLE", "(num D E G | num R A D | num G R A D)")
  Rules[:_TIME] = rule_info("TIME", "(num M S | num S)")
  Rules[:_FREQ] = rule_info("FREQ", "(num H Z | num K H Z)")
  Rules[:_RESOLUTION] = rule_info("RESOLUTION", "(num D P I | num D P C M)")
  Rules[:_DIMENSION] = rule_info("DIMENSION", "num ident")
  Rules[:_PERCENTAGE] = rule_info("PERCENTAGE", "num \"%\"")
  Rules[:_NUMBER] = rule_info("NUMBER", "num")
  Rules[:_URI] = rule_info("URI", "(U R L \"(\" w string w \")\" | U R L \"(\" w url w \")\")")
  Rules[:_BAD_URI] = rule_info("BAD_URI", "baduri")
  Rules[:_FUNCTION] = rule_info("FUNCTION", "ident \"(\"")
  Rules[:_ONLY] = rule_info("ONLY", "O N L Y")
  Rules[:_NOT] = rule_info("NOT", "N O T")
  Rules[:_AND] = rule_info("AND", "A N D")
  Rules[:_mc] = rule_info("mc", "comment?")
  Rules[:__hyphen_] = rule_info("-", "s* (comment s)* s*")
  Rules[:_stylesheet] = rule_info("stylesheet", "(CHARSET_SYM STRING \";\")? (s | CDO | CDC)* (import (CDO - | CDC -)*)* ((ruleset | media | page) (CDO - | CDC -)*)*")
  Rules[:_import] = rule_info("import", "IMPORT_SYM - (STRING | URI) - media_query_list? \";\" -")
  Rules[:_media] = rule_info("media", "MEDIA_SYM - media_query_list \"{\" - ruleset* \"}\" -")
  Rules[:_media_query_list] = rule_info("media_query_list", "- medium_query (\",\" - medium_query)*")
  Rules[:_medium_query] = rule_info("medium_query", "((ONLY | NOT)? - media_type - (AND - expression)* | expression (AND - expression)*)")
  Rules[:_media_type] = rule_info("media_type", "IDENT")
  Rules[:_expression] = rule_info("expression", "\"(\" - media_feature - (\":\" - expr)? \")\" -")
  Rules[:_media_feature] = rule_info("media_feature", "IDENT")
  Rules[:_page] = rule_info("page", "PAGE_SYM - pseudo_page? \"{\" - declaration? (\";\" - declaration?)* \"}\" -")
  Rules[:_pseudo_page] = rule_info("pseudo_page", "\":\" IDENT -")
  Rules[:_operator] = rule_info("operator", "(\"/\" - | \",\" -)")
  Rules[:_combinator] = rule_info("combinator", "(\"+\" - | \">\" -)")
  Rules[:_unary_operator] = rule_info("unary_operator", "(\"-\" | \"+\")")
  Rules[:_property] = rule_info("property", "IDENT -")
  Rules[:_ruleset] = rule_info("ruleset", "selector (\",\" - selector)* \"{\" - declaration? (\";\" - declaration?)* \"}\" -")
  Rules[:_selector] = rule_info("selector", "simple_selector (combinator selector | s+ (combinator? selector)?)?")
  Rules[:_simple_selector] = rule_info("simple_selector", "(\"::\"? element_name (HASH | class | attrib | pseudo)* | (HASH | class | attrib | pseudo)+)")
  Rules[:_class] = rule_info("class", "\".\" IDENT")
  Rules[:_element_name] = rule_info("element_name", "(IDENT | \"*\")")
  Rules[:_attrib] = rule_info("attrib", "\"[\" - IDENT - ((\"=\" | INCLUDES | DASHMATCH) - (IDENT | STRING) -)? \"]\"")
  Rules[:_pseudo] = rule_info("pseudo", "\":\" \":\"? (IDENT | FUNCTION - (IDENT -)? \")\")")
  Rules[:_stopper] = rule_info("stopper", "(\";\" | \"}\")")
  Rules[:_declaration] = rule_info("declaration", "(\"filter\" - \":\" - (!stopper .)+ | property \":\" - expr prio? | \"*\" property - \":\" - (!stopper .)+)")
  Rules[:_prio] = rule_info("prio", "IMPORTANT_SYM -")
  Rules[:_expr] = rule_info("expr", "term (operator? term)*")
  Rules[:_term] = rule_info("term", "(unary_operator? (PERCENTAGE - | LENGTH - | EMS - | EXS - | ANGLE - | TIME - | FREQ - | RESOLUTION - | NUMBER -) | STRING - | URI - | function | IDENT - | hexcolor)")
  Rules[:_function] = rule_info("function", "FUNCTION - expr \")\" -")
  Rules[:_hexcolor] = rule_info("hexcolor", "HASH -")
  Rules[:_root] = rule_info("root", "- stylesheet - !.")
end
