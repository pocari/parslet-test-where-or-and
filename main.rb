require 'parslet'
require 'bigdecimal'

class BaseParser < Parslet::Parser
  rule(:space) { match('\s').repeat(1) }
  rule(:space?) { space.maybe }

  rule(:quoted_string) { d_quoted_string | s_quoted_string }

  rule(:escaped_char) { str('\\') >> any }
  rule(:d_quote) { str('"') }
  rule(:d_quoted_string) { d_quote >> (escaped_char | d_quote.absent? >> any).repeat.as(:str) >> d_quote }

  rule(:s_quote) { str('\'') }
  rule(:s_quoted_string) { s_quote >> (escaped_char | s_quote.absent? >> any).repeat.as(:str) >> s_quote }
end

class WhereParser < BaseParser
  root(:or_condition)

  rule(:or_condition) { and_condition.as(:left) >> (or_op.as(:or) >> and_condition.as(:right)).repeat >> space?}
  rule(:and_condition) { primary.as(:left) >> (and_op.as(:and) >> primary.as(:right)).repeat}

  rule(:primary) { (lparen >> or_condition >> rparen).as(:paren) | word}
  rule(:word) { (quoted_string | raw_str).as(:word) }
  rule(:raw_str) { str('or').absent? >> str('and').absent? >> match('[^\s()]').repeat(1) }

  rule(:lparen) { space? >> str('(') >> space? }
  # ')'のあとのspaceを消費すると、orのつもりのspaceまで消費してしまうので')'に関しては後ろのspaceは消費しない
  rule(:rparen) { space? >> str(')') }
  rule(:or_op) { space? >> (str('or') >> space?) | space }
  rule(:and_op) { space? >> str('and') >> space? }
end

BinNode = Struct.new(:ope, :left, :right) do
  def eval
    self
  end

  def sql
    "#{left.sql} #{ope} #{right.sql}"
  end

  def values
    left.values + right.values
  end
end

Word = Struct.new(:word) do
  def eval
    self
  end

  def sql
    "column_name like ?"
  end

  def values
    [word.to_s]
  end
end

LeftOp = Struct.new(:ope, :right) do
  def call(left)
    BinNode.new(ope, left.eval, self.right.eval)
  end
end

Paren = Struct.new(:seq) do
  def eval
    Paren.new(seq.eval)
  end

  def sql
    "(#{seq.sql})"
  end

  def values
    seq.values
  end
end

Seq = Struct.new(:seq) do
  def eval
    seq.inject do |acc, ope|
      ope.call(acc)
    end
  end
end

class WhereTransformer < Parslet::Transform
  rule(str: simple(:s)) { s}
  rule(left: simple(:l)) { l }

  rule(word: simple(:w)) { Word.new(w)}
  rule(or: simple(:_), right: subtree(:r)) {
    LeftOp.new(:or, r)
  }
  rule(and: simple(:_), right: subtree(:r)) {
    LeftOp.new(:and, r)
  }
  rule(paren: simple(:s)) {
    Paren.new(s)
  }
  rule(sequence(:seq)) {
    Seq.new(seq)
  }
end 
begin
  # raw = "aaa bbb1 bbb2 and (ccc or ddd) and (eee \"ff f\")\n"
  # raw = "aaa bbb1\n"
  raw = $stdin.read
  # raw = <<~EOS
  # (aaa bbb) and ccc
  # EOS

  puts "========================== raw"
  pp raw
  parsed = WhereParser.new.parse(raw)
  # puts "========================== syntax tree"
  # pp parsed

  ast = WhereTransformer.new.apply(parsed)
  # puts "========================== AST"
  # pp ast

  puts "========================== AST eval"
  pp [:sql, ast.eval.sql]
  pp [:parameters, ast.eval.values]
rescue Parslet::ParseFailed => failure
  puts failure.parse_failure_cause.ascii_tree
  raise failure
end
