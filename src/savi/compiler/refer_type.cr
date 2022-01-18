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
    protected getter cache_deps_additional_namespaces : Hash(Source, Namespace::Analysis)

    def initialize(parent : Analysis? = nil)
      @parent = StructRef(Analysis).new(parent) if parent
      @infos = {} of AST::Identifier => Refer::Info
      @params = {} of String => Refer::TypeParam
      @redirects = {} of Refer::Info => Refer::Info
      @cache_deps_additional_namespaces = {} of Source => Namespace::Analysis
    end

    protected def observe_ident(ident : AST::Identifier, info : Refer::Info)
      @infos[ident] = redirect_for?(info) || info
    end

    def [](ident : AST::Identifier) : Refer::Info
      @infos[ident]
    end

    def []?(ident : AST::Identifier) : Refer::Info?
      @infos[ident]?
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
    getter namespace : Namespace::Analysis
    def initialize(@analysis, @namespace)
    end

    def find_type?(ctx, node : AST::Identifier)
      return Refer::Self::INSTANCE if node.value == "@"

      found = @analysis.type_param_for?(node.value)
      return found if found

      if node.pos.source == namespace.source
        found = namespace[node.value]?
      else
        # If the identifier comes from a foreign source file, we need to use
        # the distinct namespace analysis associated with that source file.
        foreign_namespace = ctx.namespace[node.pos.source]?
        if foreign_namespace
          found = foreign_namespace[node.value]?
          # If found in a foreign namespace analysis, we need to accure that
          # analysis as a cache-invalidating dependency.
          if found
            analysis.cache_deps_additional_namespaces[node.pos.source] =
              foreign_namespace
          end
        end
      end

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
      touch(ctx, node) if node.is_a?(AST::Identifier)
      node
    rescue exc : Exception
      raise Error.compiler_hole_at(node, exc)
    end

    # For an Identifier, resolve it to any known type if possible.
    # Otherwise, leave it missing from our infos map.
    def touch(ctx, node : AST::Identifier)
      info = find_type?(ctx, node)
      @analysis.observe_ident(node, info) if info
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
      prev = ctx.prev_ctx.try(&.refer_type)

      prev_namespaces = prev.try(&.[]?(t_link)
        .try(&.cache_deps_additional_namespaces
          .keys.map { |source| ctx.namespace[source] }
        )
      )

      deps = {namespace, prev_namespaces}
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

        # Take the new set of cache dep additional namespaces into account.
        new_namespaces = visitor.analysis
          .cache_deps_additional_namespaces.values
        new_deps = {namespace, new_namespaces}
        set_type_alias_cache_deps(t, t_link, new_deps)

        visitor.analysis
      end
    end

    def analyze_type(ctx, t, t_link) : Analysis
      namespace = ctx.namespace[t.ident.pos.source]
      prev = ctx.prev_ctx.try(&.refer_type)

      prev_namespaces = prev.try(&.[]?(t_link)
        .try(&.cache_deps_additional_namespaces
          .keys.map { |source| ctx.namespace[source] }
        )
      )

      deps = {namespace, prev_namespaces}
      maybe_from_type_cache(ctx, prev, t, t_link, deps) do
        t_analysis = Analysis.new
        observe_type_params(ctx, t, t_link, t_analysis)

        # Run as a visitor on the ident itself and every type param.
        visitor = Visitor.new(t_analysis, namespace)
        t.ident.accept(ctx, visitor)
        t.params.try(&.accept(ctx, visitor))

        # Take the new set of cache dep additional namespaces into account.
        new_namespaces = visitor.analysis
          .cache_deps_additional_namespaces.values
        new_deps = {namespace, new_namespaces}
        set_type_cache_deps(t, t_link, new_deps)

        visitor.analysis
      end
    end

    def analyze_func(ctx, f, f_link, t_analysis) : Analysis
      namespace = ctx.namespace[f.ident.pos.source]
      prev = ctx.prev_ctx.try(&.refer_type)

      prev_namespaces = prev.try(&.[]?(f_link)
        .try(&.cache_deps_additional_namespaces
          .keys.map { |source| ctx.namespace[source] }
        )
      )

      deps = {namespace, prev_namespaces}
      maybe_from_func_cache(ctx, prev, f, f_link, deps) do
        f_analysis = Analysis.new(t_analysis)
        visitor = Visitor.new(f_analysis, namespace)

        f.ast.accept(ctx, visitor)

        # Take the new set of cache dep additional namespaces into account.
        new_namespaces = visitor.analysis
          .cache_deps_additional_namespaces.values
        new_deps = {namespace, new_namespaces}
        set_func_cache_deps(f, f_link, new_deps)

        visitor.analysis
      end
    end
  end
end
