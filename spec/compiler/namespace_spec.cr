describe Savi::Compiler::Namespace do
  it "returns the same output state when compiled again with same sources" do
    source = Savi::Source.new_example <<-SOURCE
    :actor Main
      :new (env)
        env.out.print("Hello, World")
    SOURCE

    ctx1 = Savi.compiler.test_compile([source], :namespace)
    ctx2 = Savi.compiler.test_compile([source], :namespace)

    ctx1.namespace[source].should eq ctx2.namespace[source]
  end

  it "complains when a type has the same name as another" do
    source = Savi::Source.new_example <<-SOURCE
    :class Redundancy
    :actor Redundancy
    SOURCE

    expected = <<-MSG
    This type conflicts with another declared type in the same library:
    from (example):2:
    :actor Redundancy
           ^~~~~~~~~~

    - the other type with the same name is here:
      from (example):1:
    :class Redundancy
           ^~~~~~~~~~
    MSG

    Savi.compiler.test_compile([source], :namespace)
      .errors.map(&.message).join("\n").should eq expected
  end

  it "complains when a function has the same name as another" do
    source = Savi::Source.new_example <<-SOURCE
    :class Example
      :fun same_name: "This is a contentious function!"
      :var same_name: "This is a contentious property!"
      :const same_name: "This is a contentious constant!"
    SOURCE

    expected = <<-MSG
    This name conflicts with others declared in the same type:
    from (example):2:
      :fun same_name: "This is a contentious function!"
           ^~~~~~~~~

    - a conflicting declaration is here:
      from (example):3:
      :var same_name: "This is a contentious property!"
           ^~~~~~~~~

    - a conflicting declaration is here:
      from (example):4:
      :const same_name: "This is a contentious constant!"
             ^~~~~~~~~
    MSG

    Savi.compiler.test_compile([source], :namespace)
      .errors.map(&.message).join("\n").should eq expected
  end

  it "complains when a type has the same name as another" do
    source = Savi::Source.new_example <<-SOURCE
    :class String
    SOURCE

    expected = <<-MSG
    This type's name conflicts with a mandatory built-in type:
    from (example):1:
    :class String
           ^~~~~~

    - the built-in type is defined here:
      from #{Savi.compiler.source_service.core_savi_library_path}/string.savi:1:
    :class val String
               ^~~~~~
    MSG

    Savi.compiler.test_compile([source], :namespace)
      .errors.map(&.message).join("\n").should eq expected
  end

  # TODO: Figure out how to test these in our test suite - they need a library.
  pending "complains when a bulk-imported type conflicts with another"
  pending "complains when an explicitly imported type conflicts with another"
  pending "complains when an explicitly imported type conflicts with another"
  pending "complains when a type name ends with an exclamation"

  it "won't have conflicts with a private type in the core Savi library" do
    source = Savi::Source.new_example <<-SOURCE
    :ffi LibPony // defined in core Savi, but private, so no conflict here
    SOURCE

    Savi.compiler.test_compile([source], :namespace)
  end

  # TODO: Figure out how to test these in our test suite - they need a library.
  pending "won't have conflicts with a private type in an imported library"
  pending "complains when trying to explicitly import a private type"
end
