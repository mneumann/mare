require "levenshtein"
require "./infer/reified" # TODO: can this be removed?

##
# TODO: Document this pass
#
class Mare::Compiler::TypeCheck
  alias MetaType = Infer::MetaType
  alias TypeParam = Infer::TypeParam
  alias ReifiedTypeAlias = Infer::ReifiedTypeAlias
  alias ReifiedType = Infer::ReifiedType
  alias ReifiedFunction = Infer::ReifiedFunction
  alias Info = Infer::Info

  def initialize
    @map = {} of ReifiedFunction => ForReifiedFunc
  end

  def run(ctx)
    # Collect this list of types to check, including types with no type params,
    # as well as partially reified types for those with type params.
    # TODO: This shouldn't need to be a separate step, right?
    rts = [] of ReifiedType
    ctx.program.libraries.each do |library|
      library.types.each do |t|
        t_link = t.make_link(library)
        rts.concat(ctx.infer[t_link].type_partial_reifications.map(&.single!))
      end
    end

    rts.each { |rt|
      ctx.subtyping.for_rt(rt).initialize_assertions(ctx)
    }

    # Now do the main type checking pass in each ReifiedType.
    rts.each do |rt|
      rt.defn(ctx).functions.each do |f|
        f_link = f.make_link(rt.link)
        f_cap_value = f.cap.value
        f_cap_value = "read" if f_cap_value == "box" # TODO: figure out if we can remove this Pony-originating semantic hack
        MetaType::Capability.new_maybe_generic(f_cap_value).each_cap.each do |f_cap|
          for_rf(ctx, rt, f_link, MetaType.new(f_cap)).run(ctx)
        end
      end
    end

    # Check the assertion list for each type, to confirm that it is a subtype
    # of any it claimed earlier, which we took on faith and now verify.
    rts.each { |rt|
      ctx.subtyping.for_rt(rt).check_assertions(ctx)
    }
  end

  def [](t_link : Program::Type::Link)
    @t_analyses[t_link]
  end

  def []?(t_link : Program::Type::Link)
    @t_analyses[t_link]?
  end

  def [](rf : ReifiedFunction)
    @map[rf].analysis
  end

  def []?(rf : ReifiedFunction)
    @map[rf]?.try(&.analysis)
  end

  private def for_rf(
    ctx : Context,
    rt : ReifiedType,
    f : Program::Function::Link,
    cap : MetaType,
  ) : ForReifiedFunc
    mt = MetaType.new(rt).override_cap(cap)
    rf = ReifiedFunction.new(rt, f, mt)
    @map[rf] ||= (
      refer_type = ctx.refer_type[f]
      classify = ctx.classify[f]
      completeness = ctx.completeness[f]
      pre_infer = ctx.pre_infer[f]
      infer = ctx.infer[f]
      subtyping = ctx.subtyping.for_rf(rf)
      ForReifiedFunc.new(ctx, rf,
        refer_type, classify, completeness, pre_infer, infer, subtyping
      )
    )
  end

  def self.validate_type_args(
    ctx : Context,
    type_check : ForReifiedFunc,
    node : AST::Node,
    mt : MetaType,
  )
    return unless mt.singular? # this skip partially reified type params
    rt = mt.single!
    rt_defn = rt.defn(ctx)
    infer = ctx.infer[rt.link]
    type_params = AST::Extract.type_params(rt_defn.params)
    arg_terms = node.is_a?(AST::Qualify) ? node.group.terms : [] of AST::Node

    # The minimum number of params is the number that don't have defaults.
    # The maximum number of params is the total number of them.
    type_params_min = type_params.select { |(_, _, default)| !default }.size
    type_params_max = type_params.size

    if rt.args.empty?
      if type_params_min == 0
        # If there are no type args or type params there's nothing to check.
        return
      else
        # If there are type params but no type args we have a problem.
        ctx.error_at node, "This type needs to be qualified with type arguments", [
          {rt_defn.params.not_nil!,
            "these type parameters are expecting arguments"}
        ]
        return
      end
    end

    # If this is an identifier referencing a different type, skip it;
    # it will have been validated at its referent location, and trying
    # to validate it here would break because we don't have the Qualify node.
    return if node.is_a?(AST::Identifier) \
      && !type_check.classify.further_qualified?(node)

    raise "inconsistent arguments" if arg_terms.size != rt.args.size

    # Check number of type args against number of type params.
    if rt.args.empty?
      ctx.error_at node, "This type needs to be qualified with type arguments", [
        {rt_defn.params.not_nil!, "these type parameters are expecting arguments"}
      ]
      return
    elsif rt.args.size > type_params_max
      params_pos = (rt_defn.params || rt_defn.ident).pos
      ctx.error_at node, "This type qualification has too many type arguments", [
        {params_pos, "at most #{type_params_max} type arguments were expected"},
      ].concat(arg_terms[type_params_max..-1].map { |arg|
        {arg.pos, "this is an excessive type argument"}
      })
      return
    elsif rt.args.size < type_params_min
      params = rt_defn.params.not_nil!
      ctx.error_at node, "This type qualification has too few type arguments", [
        {params.pos, "at least #{type_params_min} type arguments were expected"},
      ].concat(params.terms[rt.args.size..-1].map { |param|
        {param.pos, "this additional type parameter needs an argument"}
      })
      return
    end

    # Check each type arg against the bound of the corresponding type param.
    arg_terms.zip(rt.args).each_with_index do |(arg_node, arg), index|
      # Skip checking type arguments that contain type parameters.
      next unless arg.type_params.empty?

      arg = arg.simplify(ctx)

      arg_cap = arg.cap_only_inner.value.as(Infer::Cap)
      cap_set = infer.type_param_bound_cap_sets[index]
      unless cap_set.includes?(arg_cap)
        bound_pos =
          rt_defn.params.not_nil!.terms[index].as(AST::Group).terms.last.pos
        cap_set_string = "{" + cap_set.map(&.string).join(", ") + "}"
        ctx.error_at arg_node,
          "This type argument won't satisfy the type parameter bound", [
            {bound_pos, "the allowed caps are #{cap_set_string}"},
            {arg_node.pos, "the type argument cap is #{arg_cap.string}"},
          ]
        next
      end

      param_bound = rt.meta_type_of_type_param_bound(ctx, index, infer)
      next unless param_bound

      unless arg.satisfies_bound?(ctx, param_bound)
        bound_pos =
          rt_defn.params.not_nil!.terms[index].as(AST::Group).terms.last.pos
        ctx.error_at arg_node,
          "This type argument won't satisfy the type parameter bound", [
            {bound_pos, "the type parameter bound is #{param_bound.show_type}"},
            {arg_node.pos, "the type argument is #{arg.show_type}"},
          ]
        next
      end
    end
  end

  def self.verify_safety_of_runtime_type_match(
    ctx : Context,
    pos : Source::Pos,
    lhs_mt : MetaType,
    rhs_mt : MetaType,
    lhs_pos : Source::Pos,
    rhs_pos : Source::Pos,
  )
    # This is what we'll get for lhs after testing for rhs type at runtime
    # because at runtime, capabilities do not exist - we only check defns.
    isect_mt = lhs_mt.intersect(rhs_mt.strip_cap).simplify(ctx)

    # If the intersection comes up empty, the type check will never match.
    if isect_mt.unsatisfiable?
      ctx.error_at pos, "This type check will never match", [
        {rhs_pos,
          "the runtime match type, ignoring capabilities, " \
          "is #{rhs_mt.strip_cap.show_type}"},
        {lhs_pos,
          "which does not intersect at all with #{lhs_mt.show_type}"},
      ]
      return
    end

    # If the intersection isn't a subtype of the right hand side, then we know
    # the type descriptors can match but the capabilities would be unsafe.
    if !isect_mt.subtype_of?(ctx, rhs_mt)
      ctx.error_at pos,
        "This type check could violate capabilities", [
          {rhs_pos,
            "the runtime match type, ignoring capabilities, " \
            "is #{rhs_mt.strip_cap.show_type}"},
          {lhs_pos,
            "if it successfully matches, " \
            "the type will be #{isect_mt.show_type}"},
          {rhs_pos, "which is not a subtype of #{rhs_mt.show_type}"},
        ]
      return
    end
  end

  class ForReifiedFunc < Mare::AST::Visitor
    getter reified : ReifiedFunction
    private getter refer_type : ReferType::Analysis
    protected getter classify : Classify::Analysis # TODO: make private
    private getter completeness : Completeness::Analysis
    protected getter pre_infer : PreInfer::Analysis # TODO: make private
    private getter infer : Infer::FuncAnalysis
    private getter subtyping : SubtypingCache::ForReifiedFunc

    def initialize(ctx, @reified,
      @refer_type, @classify, @completeness, @pre_infer, @infer, @subtyping
    )
      @resolved_infos = {} of Info => MetaType
      @func = @reified.link.resolve(ctx).as(Program::Function)
    end

    def ret
      # The ident is used as a fake local variable that represents the return.
      @func.ident
    end

    def resolve(ctx : Context, info : Infer::Info) : MetaType?
      # If our type param reification doesn't match any of the conditions
      # for the layer associated with the given info, then
      # we will not do any typechecking here - we just return nil.
      return nil if subtyping.ignores_layer?(ctx, info.layer_index)

      @resolved_infos[info]? || begin
        mt = info.as_conduit?.try(&.resolve!(ctx, self)) \
          || @reified.meta_type_of(ctx, info, @infer)
        @resolved_infos[info] = mt || MetaType.unconstrained
        return nil unless mt

        okay = type_check_pre(ctx, info, mt)
        type_check(ctx, info, mt) if okay

        mt
      end
    end

    # Validate type arguments for FixedSingleton values.
    def type_check_pre(ctx : Context, info : Infer::FixedSingleton, mt : MetaType) : Bool
      TypeCheck.validate_type_args(ctx, self, info.node, mt)
      true
    end

    # Check completeness of self references inside a constructor.
    def type_check_pre(ctx : Context, info : Infer::Self, mt : MetaType) : Bool
      # If this is a complete self, no additional checks are required.
      unseen_fields = completeness.unseen_fields_for(info)
      return true unless unseen_fields

      # This represents the self type as opaque, with no field access.
      # We'll use this to guarantee that no usage of the current self object
      # will require  any access to the fields of the object.
      tag_self = mt.override_cap(Infer::Cap::TAG)
      total_constraint = info.total_downstream_constraint(ctx, self)
      return true if tag_self.within_constraints?(ctx, [total_constraint])

      # If even the non-tag self isn't within constraints, return true here
      # and let the later type_check code catch this problem.
      return true if !mt.within_constraints?(ctx, [total_constraint])

      # Walk through each constraint imposed on the self, and raise an error
      # for each one that is not satisfiable by a tag self.
      info.list_downstream_constraints(ctx, self).each do |pos, constraint|
        # If tag will meet the constraint, then this use of the self is okay.
        next if tag_self.within_constraints?(ctx, [constraint])

        # Otherwise, we must raise an error.
        ctx.error_at info.pos,
          "This usage of `@` shares field access to the object" \
          " from a constructor before all fields are initialized", [
            {pos,
              "if this constraint were specified as `tag` or lower" \
              " it would not grant field access"}
          ] + unseen_fields.map { |ident|
            {ident.pos, "this field didn't get initialized"}
          }
      end
      false
    end

    # Sometimes print a special case error message for Literal values.
    def type_check_pre(ctx : Context, info : Infer::Literal, mt : MetaType) : Bool
      # If we've resolved to a single concrete type already, move forward.
      return true if mt.singular? && mt.single!.link.is_concrete?

      # If we can't be satisfiably intersected with the downstream constraints,
      # move forward and let the standard type checker error happen.
      constrained_mt = mt.intersect(info.total_downstream_constraint(ctx, self))
      return true if constrained_mt.simplify(ctx).unsatisfiable?

      # Otherwise, print a Literal-specific error that includes peer hints,
      # as well as a call to action to use an explicit numeric type.
      error_info = info.describe_peer_hints(ctx, self)
      error_info.concat(info.describe_downstream_constraints(ctx, self))
      error_info.push({info.pos,
        "and the literal itself has an intrinsic type of #{mt.show_type}"
      })
      error_info.push({Source::Pos.none,
        "Please wrap an explicit numeric type around the literal " \
          "(for example: U64[#{info.pos.content}])"
      })
      ctx.error_at info,
        "This literal value couldn't be inferred as a single concrete type",
        error_info
      false
    end

    # Sometimes print a special case error message for ArrayLiteral values.
    def type_check_pre(ctx : Context, info : Infer::ArrayLiteral, mt : MetaType) : Bool
      # If the array cap is not ref or "lesser", we must recover to the
      # higher capability, meaning all element expressions must be sendable.
      array_cap = mt.cap_only_inner
      unless array_cap.supertype_of?(MetaType::Capability::REF)
        term_mts = info.terms.compact_map { |term| resolve(ctx, term) }
        unless term_mts.all?(&.alias.is_sendable?)
          ctx.error_at info.pos, "This array literal can't have a reference cap of " \
            "#{array_cap.inspect} unless all of its elements are sendable",
              info.describe_downstream_constraints(ctx, self)
        end
      end

      true
    end

    # Check runtime match safety for TypeCondition expressions.
    def type_check_pre(ctx : Context, info : Infer::TypeCondition, mt : MetaType) : Bool
      lhs_mt = resolve(ctx, info.lhs)
      rhs_mt = resolve(ctx, info.rhs)

      # TODO: move that function here into this file/module.
      TypeCheck.verify_safety_of_runtime_type_match(ctx, info.pos,
        lhs_mt,
        rhs_mt,
        info.lhs.pos,
        info.rhs.pos,
      ) if lhs_mt && rhs_mt

      true
    end
    def type_check_pre(ctx : Context, info : Infer::TypeConditionForLocal, mt : MetaType) : Bool
      lhs_info = @pre_infer[info.refine]
      lhs_info = lhs_info.info if lhs_info.is_a?(Infer::LocalRef)
      rhs_info = info.refine_type
      lhs_mt = resolve(ctx, lhs_info)
      rhs_mt = resolve(ctx, rhs_info)

      # TODO: move that function here into this file/module.
      TypeCheck.verify_safety_of_runtime_type_match(ctx, info.pos,
        lhs_mt,
        rhs_mt,
        lhs_info.as(Infer::NamedInfo).first_viable_constraint_pos,
        rhs_info.pos,
      ) if lhs_mt && rhs_mt

      true
    end

    def type_check_pre(ctx : Context, info : Infer::FromCall, mt : MetaType) : Bool
      receiver_mt = resolve(ctx, info.lhs)
      return false unless receiver_mt

      call_defns = receiver_mt.find_callable_func_defns(ctx, info.member)

      problems = [] of {Source::Pos, String}
      call_defns.each do |(call_mt, call_defn, call_func)|
        next unless call_defn
        next unless call_func
        call_func_link = call_func.make_link(call_defn.link)

        # Determine the correct capability to reify, checking for cap errors.
        reify_cap, autorecover_needed =
          info.follow_call_check_receiver_cap(ctx, @func, call_mt, call_func, problems)

        # Check the number of arguments.
        info.follow_call_check_args(ctx, self, call_func, problems)

        # Check whether yield block presence matches the function's expectation.
        other_pre_infer = ctx.pre_infer[call_func_link]
        func_does_yield = other_pre_infer.yield_out_infos.any?
        if info.yield_block && !func_does_yield
          problems << {info.yield_block.not_nil!.pos, "it has a yield block"}
          problems << {call_func.ident.pos,
            "but '#{call_defn.defn(ctx).ident.value}.#{info.member}' has no yields"}
        elsif !info.yield_block && func_does_yield
          problems << {
            other_pre_infer.yield_out_infos.first.first_viable_constraint_pos,
            "it has no yield block but " \
              "'#{call_defn.defn(ctx).ident.value}.#{info.member}' does yield"
          }
        end

        # Check if auto-recovery of the receiver is possible.
        if autorecover_needed
          receiver = MetaType.new(call_defn, reify_cap.cap_only_inner.value.as(Infer::Cap))
          other_rf = ReifiedFunction.new(call_defn, call_func_link, receiver)
          ret_mt = other_rf.meta_type_of_ret(ctx)
          info.follow_call_check_autorecover_cap(ctx, self, call_func, ret_mt) \
            if ret_mt
        end
      end
      ctx.error_at info,
        "This function call doesn't meet subtyping requirements", problems \
          unless problems.empty?

      true
    end

    # Other types of Info nodes do not have extra type checks.
    def type_check_pre(ctx : Context, info : Infer::Info, mt : MetaType) : Bool
      true # There is nothing extra here.
    end

    def type_check(ctx, info : Infer::DynamicInfo, meta_type : Infer::MetaType)
      return if info.downstreams_empty?

      # TODO: print a different error message when the downstream constraints are
      # internally conflicting, even before adding this meta_type into the mix.
      if !meta_type.ephemeralize.within_constraints?(ctx, [
        info.total_downstream_constraint(ctx, self)
      ])
        extra = info.describe_downstream_constraints(ctx, self)
        extra << {info.pos,
          "but the type of the #{info.described_kind} was #{meta_type.show_type}"}
        this_would_be_possible_if = info.this_would_be_possible_if
        extra << this_would_be_possible_if if this_would_be_possible_if

        ctx.error_at info.downstream_use_pos, "The type of this expression " \
          "doesn't meet the constraints imposed on it",
            extra
      end

      # If aliasing makes a difference, we need to evaluate each constraint
      # that has nonzero aliases with an aliased version of the meta_type.
      if meta_type != meta_type.strip_ephemeral.alias
        meta_type_alias = meta_type.strip_ephemeral.alias

        # TODO: Do we need to do anything here to weed out union types with
        # differing capabilities of compatible terms? Is it possible that
        # the type that fulfills the total_downstream_constraint is not compatible
        # with the ephemerality requirement, while some other union member is?
        info.downstreams_each.each do |use_pos, other_info, aliases|
          next unless aliases > 0

          constraint = resolve(ctx, other_info).as(Infer::MetaType?)
          next unless constraint

          if !meta_type_alias.within_constraints?(ctx, [constraint])
            extra = info.describe_downstream_constraints(ctx, self)
            extra << {info.pos,
              "but the type of the #{info.described_kind} " \
              "(when aliased) was #{meta_type_alias.show_type}"
            }
            this_would_be_possible_if = info.this_would_be_possible_if
            extra << this_would_be_possible_if if this_would_be_possible_if

            ctx.error_at use_pos, "This aliasing violates uniqueness " \
              "(did you forget to consume the variable?)",
              extra
          end
        end
      end
    end

    # For all other info types we do nothing.
    # TODO: Should we do something?
    def type_check(ctx, info : Infer::Info, meta_type : Infer::MetaType)
    end

    def run(ctx)
      @pre_infer.each_info { |info| resolve(ctx, info) }

      # Return types of constant "functions" are very restrictive.
      if @func.has_tag?(:constant)
        numeric_rt = ReifiedType.new(ctx.namespace.prelude_type("Numeric"))
        numeric_mt = MetaType.new_nominal(numeric_rt)

        ret_mt = @resolved_infos[@pre_infer[ret]]
        ret_rt = ret_mt.single?.try(&.defn)
        is_val = ret_mt.cap_only.inner == MetaType::Capability::VAL
        unless is_val && ret_rt.is_a?(ReifiedType) && ret_rt.link.is_concrete? && (
          ret_rt.not_nil!.link.name == "String" ||
          ret_mt.subtype_of?(ctx, numeric_mt) ||
          (ret_rt.not_nil!.link.name == "Array" && begin
            elem_mt = ret_rt.args.first
            elem_rt = elem_mt.single?.try(&.defn)
            elem_is_val = elem_mt.cap_only.inner == MetaType::Capability::VAL
            is_val && elem_rt.is_a?(ReifiedType) && elem_rt.link.is_concrete? && (
              elem_rt.not_nil!.link.name == "String" ||
              elem_mt.subtype_of?(ctx, numeric_mt)
            )
          end)
        )
          ctx.error_at ret, "The type of a constant may only be String, " \
            "a numeric type, or an immutable Array of one of these", [
              {@func.ret || @func.body || ret, "but the type is #{ret_mt.show_type}"}
            ]
        end
      end

      # Parameters must be sendable when the function is asynchronous,
      # or when it is a constructor with elevated capability.
      require_sendable =
        if @func.has_tag?(:async)
          "An asynchronous function"
        elsif @func.has_tag?(:constructor) \
        && !resolve(ctx, @pre_infer[ret]).not_nil!.subtype_of?(ctx, MetaType.cap(Infer::Cap::REF))
          "A constructor with elevated capability"
        end
      if require_sendable
        @func.params.try do |params|

          errs = [] of {Source::Pos, String}
          params.terms.each do |param|
            param_mt = resolve(ctx, @pre_infer[param]).not_nil!

            unless param_mt.is_sendable?
              # TODO: Remove this hacky special case.
              next if param_mt.show_type.starts_with? "CPointer"

              errs << {param.pos,
                "this parameter type (#{param_mt.show_type}) is not sendable"}
            end
          end

          ctx.error_at @func.cap.pos,
            "#{require_sendable} must only have sendable parameters", errs \
              unless errs.empty?
        end
      end

      nil
    end
  end
end
