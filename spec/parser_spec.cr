require "./spec_helper"

describe Mare::Parser do
  it "parses an example" do
    source = Mare::Source.new_example <<-SOURCE
    :class Example
      :prop name String: "World"

      :: Return a friendly greeting string for this instance.
      :fun greeting String
        "Hello, " + @name + "!"

      :fun degreesF (c F64) F64
        c * 9 / 5 + 32.0
    SOURCE

    ast = Mare::Parser.parse(source)

    ast.to_a.pretty_inspect(74).should eq <<-AST
    [:doc,
     [:declare, [[:ident, "class"], [:ident, "Example"]], [:group, ":"]],
     [:declare,
      [[:ident, "prop"], [:ident, "name"], [:ident, "String"]],
      [:group, ":", [:string, "World", nil]]],
     [:declare,
      [[:ident, "fun"], [:ident, "greeting"], [:ident, "String"]],
      [:group,
       ":",
       [:relate,
        [:relate, [:string, "Hello, ", nil], [:op, "+"], [:ident, "@name"]],
        [:op, "+"],
        [:string, "!", nil]]]],
     [:declare,
      [[:ident, "fun"],
       [:ident, "degreesF"],
       [:group, "(", [:group, " ", [:ident, "c"], [:ident, "F64"]]],
       [:ident, "F64"]],
      [:group,
       ":",
       [:relate,
        [:relate,
         [:relate, [:ident, "c"], [:op, "*"], [:integer, 9]],
         [:op, "/"],
         [:integer, 5]],
        [:op, "+"],
        [:float, 32.0]]]]]
    AST
  end

  it "parses operators" do
    source = Mare::Source.new_example <<-SOURCE
    :describe operators
      :demo all // in order of precedence, from "weakest" to "strongest"
        y = x
        && x || x
        === x == x !== x != x =~ x
        >= x <= x < x > x
        <|> x <~> x <<~ x ~>> x << x >> x <~ x ~> x
        + x - x
        * x / x x.y

      :demo mixed
        a != b && c > d / x + e / y || i.j > k << l

      :demo prefix
        ~x
    SOURCE

    ast = Mare::Parser.parse(source)

    # Can't use array literals here because Crystal is too slow to compile them.
    # See https://github.com/crystal-lang/crystal/issues/5792
    ast.to_a.pretty_inspect(74).should eq <<-AST
    [:doc,
     [:declare, [[:ident, "describe"], [:ident, "operators"]], [:group, ":"]],
     [:declare,
      [[:ident, "demo"], [:ident, "all"]],
      [:group,
       ":",
       [:relate,
        [:ident, "y"],
        [:op, "="],
        [:relate,
         [:relate, [:ident, "x"], [:op, "&&"], [:ident, "x"]],
         [:op, "||"],
         [:relate,
          [:relate,
           [:relate,
            [:relate,
             [:relate,
              [:relate,
               [:relate,
                [:relate,
                 [:relate,
                  [:relate,
                   [:relate,
                    [:relate,
                     [:relate,
                      [:relate,
                       [:relate,
                        [:relate,
                         [:relate,
                          [:ident, "x"],
                          [:op, "==="],
                          [:ident, "x"]],
                         [:op, "=="],
                         [:ident, "x"]],
                        [:op, "!=="],
                        [:ident, "x"]],
                       [:op, "!="],
                       [:ident, "x"]],
                      [:op, "=~"],
                      [:ident, "x"]],
                     [:op, ">="],
                     [:ident, "x"]],
                    [:op, "<="],
                    [:ident, "x"]],
                   [:op, "<"],
                   [:ident, "x"]],
                  [:op, ">"],
                  [:ident, "x"]],
                 [:op, "<|>"],
                 [:ident, "x"]],
                [:op, "<~>"],
                [:ident, "x"]],
               [:op, "<<~"],
               [:ident, "x"]],
              [:op, "~>>"],
              [:ident, "x"]],
             [:op, "<<"],
             [:ident, "x"]],
            [:op, ">>"],
            [:ident, "x"]],
           [:op, "<~"],
           [:ident, "x"]],
          [:op, "~>"],
          [:relate,
           [:relate, [:ident, "x"], [:op, "+"], [:ident, "x"]],
           [:op, "-"],
           [:relate,
            [:relate, [:ident, "x"], [:op, "*"], [:ident, "x"]],
            [:op, "/"],
            [:group,
             " ",
             [:ident, "x"],
             [:relate, [:ident, "x"], [:op, "."], [:ident, "y"]]]]]]]]]],
     [:declare,
      [[:ident, "demo"], [:ident, "mixed"]],
      [:group,
       ":",
       [:relate,
        [:relate,
         [:relate, [:ident, "a"], [:op, "!="], [:ident, "b"]],
         [:op, "&&"],
         [:relate,
          [:ident, "c"],
          [:op, ">"],
          [:relate,
           [:relate, [:ident, "d"], [:op, "/"], [:ident, "x"]],
           [:op, "+"],
           [:relate, [:ident, "e"], [:op, "/"], [:ident, "y"]]]]],
        [:op, "||"],
        [:relate,
         [:relate,
          [:relate, [:ident, "i"], [:op, "."], [:ident, "j"]],
          [:op, ">"],
          [:ident, "k"]],
         [:op, "<<"],
         [:ident, "l"]]]]],
     [:declare,
      [[:ident, "demo"], [:ident, "prefix"]],
      [:group, ":", [:prefix, [:op, "~"], [:ident, "x"]]]]]
    AST
  end

  it "complains when a character literal has too many characters in it" do
    source = Mare::Source.new_example <<-SOURCE
    :actor Main
      :new
        x U64 = '..'
    SOURCE

    expected = <<-MSG
    This character literal has more than one character in it:
    from (example):3:
        x U64 = '..'
                 ^~
    MSG

    expect_raises Mare::Error, expected do
      Mare::Parser.parse(source)
    end
  end

  it "handles nifty heredoc string literals" do
    source = Mare::Source.new_example <<-SOURCE
    :actor Main
      :new
        <<<FOO>>>
        <<<FOO<<<BAR>>>BAZ>>>
        <<<
          FOO
          BAR
          BAZ
        >>>
        <<<
          FOO
          <<<
            BAR
          >>>
          BAZ
        >>>
    SOURCE

    ast = Mare::Parser.parse(source)

    ast.to_a.should eq [:doc,
      [:declare, [[:ident, "actor"], [:ident, "Main"]], [:group, ":"]],
      [:declare, [[:ident, "new"]], [:group, ":",
        [:string, "FOO", nil],
        [:string, "FOO<<<BAR>>>BAZ", nil],
        [:string, "FOO\nBAR\nBAZ", nil],
        [:string, "FOO\n<<<\n  BAR\n>>>\nBAZ", nil],
      ]],
    ]
  end

  it "correctly parses a negative integer literal in a single-line decl" do
    source = Mare::Source.new_example <<-SOURCE
    :primitive Example
      :const x U64: 1
      :const y U64: -1
    SOURCE

    ast = Mare::Parser.parse(source)

    # Can't use array literals here because Crystal is too slow to compile them.
    ast.to_a.pretty_inspect(74).should eq <<-AST
    [:doc,
     [:declare, [[:ident, "primitive"], [:ident, "Example"]], [:group, ":"]],
     [:declare,
      [[:ident, "const"], [:ident, "x"], [:ident, "U64"]],
      [:group, ":", [:integer, 1]]],
     [:declare,
      [[:ident, "const"], [:ident, "y"], [:ident, "U64"]],
      [:group, ":", [:integer, -1]]]]
    AST
  end

  it "returns the same AST when called again with the same source content" do
    content = <<-SOURCE
    :primitive Example
      :const greeting String: "Hello, World!"
    SOURCE

    ast1 = Mare::Parser.parse(Mare::Source.new_example(content))
    ast2 = Mare::Parser.parse(Mare::Source.new_example(content))

    ast1.should be ast2
  end

  it "parses a Pony example" do
    source = Mare::Source.new_pony_example <<-SOURCE
    class Example
      let name: String = "World"

      // Return a friendly greeting string for this instance.
      fun greeting(): String =>
        "Hello, " + this.name + "!"

      fun degreesF(c: F64): F64 =>
        c * 9 / 5 + 32.0
    SOURCE

    ast = Mare::Parser.parse(source)

    ast.to_a.pretty_inspect(74).should eq <<-AST
    [:doc,
     [:declare, [[:ident, "class"], [:ident, "Example"]], [:group, ":"]],
     [:declare,
      [[:ident, "prop"], [:ident, "name"], [:ident, "String"]],
      [:group, ":", [:string, "World", nil]]],
     [:declare,
      [[:ident, "fun"],
       [:ident, "greeting"],
       [:group, "("],
       [:ident, "String"]],
      [:group,
       ":",
       [:relate,
        [:relate,
         [:string, "Hello, ", nil],
         [:op, "+"],
         [:relate, [:ident, "this"], [:op, "."], [:ident, "name"]]],
        [:op, "+"],
        [:string, "!", nil]]]],
     [:declare,
      [[:ident, "fun"],
       [:ident, "degreesF"],
       [:group, "(", [:group, " ", [:ident, "c"], [:ident, "F64"]]],
       [:ident, "F64"]],
      [:group,
       ":",
       [:relate,
        [:relate,
         [:relate, [:ident, "c"], [:op, "*"], [:integer, 9]],
         [:op, "/"],
         [:integer, 5]],
        [:op, "+"],
        [:float, 32.0]]]]]
    AST
  end
end
