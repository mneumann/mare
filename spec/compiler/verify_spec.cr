describe Mare::Compiler::Verify do
  it "does not impose checks on the Main actor if it doesn't exist" do
    source = Mare::Source.new_example <<-SOURCE
    :primitive Example
    SOURCE

    Mare.compiler.compile([source], :verify).errors.should be_empty
  end

  it "complains if the Main type is not an actor" do
    source = Mare::Source.new_example <<-SOURCE
    :class Main
      :new (env Env)
    SOURCE

    expected = <<-MSG
    The Main type defined here must be defined as an actor:
    from (example):1:
    :class Main
           ^~~~
    MSG

    Mare.compiler.compile([source], :verify)
      .errors.map(&.message).join("\n").should eq expected
  end

  it "complains if the Main actor has type parameters" do
    source = Mare::Source.new_example <<-SOURCE
    :actor Main (A)
      :new (env Env)
    SOURCE

    expected = <<-MSG
    The Main actor is not allowed to have type parameters:
    from (example):1:
    :actor Main (A)
                ^~~
    MSG

    Mare.compiler.compile([source], :verify)
      .errors.map(&.message).join("\n").should eq expected
  end

  it "complains if the Main actor has no `new` constructor" do
    source = Mare::Source.new_example <<-SOURCE
    :actor Main
      :new wrong_name
    SOURCE

    expected = <<-MSG
    The Main actor defined here must have a constructor named `new`:
    from (example):1:
    :actor Main
           ^~~~

    - this constructor is not named `new`:
      from (example):2:
      :new wrong_name
           ^~~~~~~~~~
    MSG

    Mare.compiler.compile([source], :verify)
      .errors.map(&.message).join("\n").should eq expected
  end

  it "complains if the Main.new function is not a constructor" do
    source = Mare::Source.new_example <<-SOURCE
    :actor Main
      :fun new (env Env)
    SOURCE

    expected = <<-MSG
    The Main.new function defined here must be a constructor:
    from (example):2:
      :fun new (env Env)
           ^~~
    MSG

    Mare.compiler.compile([source], :verify)
      .errors.map(&.message).join("\n").should eq expected
  end

  it "complains if the Main.new function has no parameters" do
    source = Mare::Source.new_example <<-SOURCE
    :actor Main
      :new
    SOURCE

    expected = <<-MSG
    The Main.new function has too few parameters:
    from (example):2:
      :new
       ^~~

    - it should accept exactly one parameter of type Env:
      from /opt/code/src/prelude/env.mare:1:
    :class val Env
               ^~~
    MSG

    Mare.compiler.compile([source], :verify)
      .errors.map(&.message).join("\n").should eq expected
  end

  it "complains if the Main.new function has too many parameters" do
    source = Mare::Source.new_example <<-SOURCE
    :actor Main
      :new (env Env, bogus Env)
    SOURCE

    expected = <<-MSG
    The Main.new function has too many parameters:
    from (example):2:
      :new (env Env, bogus Env)
           ^~~~~~~~~~~~~~~~~~~~

    - it should accept exactly one parameter of type Env:
      from /opt/code/src/prelude/env.mare:1:
    :class val Env
               ^~~
    MSG

    Mare.compiler.compile([source], :verify)
      .errors.map(&.message).join("\n").should eq expected
  end

  it "complains if the Main.new function is of the wrong type" do
    source = Mare::Source.new_example <<-SOURCE
    :actor Main
      :new (env String)
    SOURCE

    expected = <<-MSG
    The parameter of Main.new has the wrong type:
    from (example):2:
      :new (env String)
            ^~~~~~~~~~

    - it should accept a parameter of type Env:
      from /opt/code/src/prelude/env.mare:1:
    :class val Env
               ^~~

    - but the parameter type is String:
      from (example):2:
      :new (env String)
                ^~~~~~
    MSG

    Mare.compiler.compile([source], :verify)
      .errors.map(&.message).join("\n").should eq expected
  end
end
