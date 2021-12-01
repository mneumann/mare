require "./pass/analyze"

##
# The purpose of the ReferType pass is to resolve identifiers that can be
# found to be type declarations/aliases. The resolutions of the identifiers
# are kept as output state available to future passes wishing to retrieve
# information as to what a given identifier refers. This pass is separate
# from the later Refer pass, so that type identifiers can be lexically resolved
# in this pass before other kinds of info is resolved functionally in that pass.
#
# This pass does not mutate the Program topology.
# This pass does not mutate the AST.
# This pass does not raise any compilation errors.
# This pass keeps state at the per-type and per-function level.
# This pass produces output state at the per-type and per-function level.
#
module Savi::Compiler::ReferType
  struct Analysis
    @parent : StructRef(Analysis)?

    def initialize(parent : Analysis? = nil)
      @parent = StructRef(Analysis).new(parent) if parent
      @infos = {} of AST::Node => Refer::Info
      @params = {} of String => Refer::TypeParam
      @redirects = {} of Refer::Info => Refer::Info
    end

    protected def observe_info(node : AST::Node, info : Refer::Info)
      @infos[node] = redirect_for?(info) || info
    end

    def [](node : AST::Node) : Refer::Info
      @infos[node]
    end

    def []?(node : AST::Node) : Refer::Info?
      @infos[node]?
    end

    protected def observe_type_param(param : Refer::TypeParam)
      @params[param.ident.value] = param
    end

    def type_param_for?(name : String)
      @params[name]? || @parent.try(&.type_param_for?(name))
    end

    # TODO: Can this be protected?
    def redirect(from : Refer::Info, to : Refer::Info)
      raise "can't redirect from unresolved" if from.is_a?(Refer::Unresolved)
      @redirects[from] = to
    end

    def redirect_for?(from : Refer::Info) : Refer::Info?
      @redirects[from]? || @parent.try(&.redirect_for?(from))
    end
  end

  class Visitor < Savi::AST::Visitor
    getter analysis : Analysis
    getter namespace : Namespace::SourceAnalysis
    def initialize(@analysis, @namespace)
    end

    def find_type?(ctx, node : AST::Identifier)
      return Refer::Self::INSTANCE if node.value == "@"

      found = @analysis.type_param_for?(node.value)
      return found if found

      find_type_in_namespace?(ctx, node.value)
    end

    def find_type_in_namespace?(ctx, name : String)
      found = @namespace[name]?
      case found
      when Program::Type::Link
        Refer::Type.new(found)
      when Program::TypeAlias::Link
        Refer::TypeAlias.new(found)
      when Program::TypeWithValue::Link
        Refer::Type.new(found.resolve(ctx).target, found)
      else
        nil
      end
    end

    # This visitor never replaces nodes, it just touches them and returns them.
    def visit(ctx, node)
      touch(ctx, node)
      node
    rescue exc : Exception
      raise Error.compiler_hole_at(node, exc)
    end

    # For an Identifier, resolve it to any known type if possible.
    # Otherwise, leave it missing from our infos map.
    def touch(ctx, node : AST::Identifier)
      info = find_type?(ctx, node)
      @analysis.observe_info(node, info) if info
    end

    # For a Relate node, if it is a dot where the left side refers to a type,
    # then it may possibly be the name of a nested/namespaced type.
    def touch(ctx, node : AST::Relate)
      return unless node.op.value == "."

      lhs_info = @analysis[node.lhs]?
      return unless lhs_info.is_a?(Refer::Type)

      rhs = node.rhs
      return unless rhs.is_a?(AST::Identifier)

      info = find_type_in_namespace?(ctx, "#{lhs_info.link.name}.#{rhs.value}")
      @analysis.observe_info(node, info) if info
    end

    # For a Call node, if we can tell that the left side refers to a type,
    # then it may possibly be the name of a nested/namespaced type.
    def touch(ctx, node : AST::Call)
      return if node.args || node.yield_params || node.yield_block

      lhs_info = @analysis[node.receiver]?
      return unless lhs_info.is_a?(Refer::Type)

      rhs = node.ident

      info = find_type_in_namespace?(ctx, "#{lhs_info.link.name}.#{rhs.value}")
      @analysis.observe_info(node, info) if info
    end

    # For all other AST node types, do nothing.
    def touch(ctx, node : AST::Node)
    end
  end

  class Pass < Compiler::Pass::Analyze(Analysis, Analysis, Analysis)
    def observe_type_params(ctx, t, t_link, t_analysis)
      # If the type has type parameters, collect them into the params map.
      t.params.try do |type_params|
        type_params.terms.each_with_index do |param, index|
          param_ident, param_bound, param_default = AST::Extract.type_param(param)
          t_analysis.observe_type_param(
            Refer::TypeParam.new(
              t_link,
              index,
              param_ident,
              param_bound || AST::Identifier.new("any").from(param),
              param_default,
            )
          )
        end
      end
    end

    def analyze_type_alias(ctx, t, t_link) : Analysis
      namespace = ctx.namespace[t.ident.pos.source]
      deps = namespace
      prev = ctx.prev_ctx.try(&.refer_type)

      maybe_from_type_alias_cache(ctx, prev, t, t_link, deps) do
        t_analysis = Analysis.new
        observe_type_params(ctx, t, t_link, t_analysis)

        # Run as a visitor on the ident itself and every type param.
        visitor = Visitor.new(t_analysis, namespace)
        t.ident.accept(ctx, visitor)
        t.params.try(&.accept(ctx, visitor))

        # Additionally, run on the target expression as well
        # (this is the part that is unique to a TypeAlias vs a Type).
        t.target.accept(ctx, visitor)

        visitor.analysis
      end
    end

    def analyze_type(ctx, t, t_link) : Analysis
      namespace = ctx.namespace[t.ident.pos.source]
      deps = namespace
      prev = ctx.prev_ctx.try(&.refer_type)

      maybe_from_type_cache(ctx, prev, t, t_link, deps) do
        t_analysis = Analysis.new
        observe_type_params(ctx, t, t_link, t_analysis)

        # Run as a visitor on the ident itself and every type param.
        visitor = Visitor.new(t_analysis, namespace)
        t.ident.accept(ctx, visitor)
        t.params.try(&.accept(ctx, visitor))

        visitor.analysis
      end
    end

    def analyze_func(ctx, f, f_link, t_analysis) : Analysis
      namespace = ctx.namespace[f.ident.pos.source]
      deps = namespace
      prev = ctx.prev_ctx.try(&.refer_type)

      maybe_from_func_cache(ctx, prev, f, f_link, deps) do
        f_analysis = Analysis.new(t_analysis)
        visitor = Visitor.new(f_analysis, namespace)

        f.ast.accept(ctx, visitor)

        visitor.analysis
      end
    end
  end
end
