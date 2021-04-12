module Mare::Compiler::Infer
  struct Tether
    def initialize(@info : Info, @below : StructRef(Tether)? = nil)
    end

    def self.via(info : Info, list : Array(Tether)) : Array(Tether)
      list.map { |below| new(info, StructRef(Tether).new(below)) }
    end

    def self.chain(info : Info, querent : Info) : Array(Tether)
      if info == querent
        [] of Tether
      elsif info.tether_terminal?
        [new(info)]
      else
        via(info, info.tethers(querent))
      end
    end

    def root : Info
      below = @below
      below ? below.root : @info
    end

    def to_a : Array(Info)
      below = @below
      below ? below.to_a.tap(&.push(@info)) : [@info]
    end

    def constraint_span(ctx : Context, infer : Visitor) : Span
      below = @below
      if below
        @info.tether_upward_transform_span(ctx, infer, below.constraint_span(ctx, infer))
      else
        @info.tether_resolve_span(ctx, infer)
      end
    end

    def includes?(other_info) : Bool
      @info == other_info || @below.try(&.includes?(other_info)) || false
    end
  end

  abstract class Info
    property pos : Source::Pos = Source::Pos.none
    property! layer_index : Int32 # Corresponding to TypeContext::Analysis
    property override_describe_kind : String?

    def to_s
      "#<#{self.class.name.split("::").last} #{pos.inspect}>"
    end

    abstract def add_downstream(use_pos : Source::Pos, info : Info, aliases : Int32)

    def as_conduit? : Conduit?
      nil # if non-nil, a conduit will be used instead of a span.
    end
    def as_upstream_conduits : Array(Conduit)
      conduit = as_conduit?
      if conduit
        conduit.flatten
      else
        [Conduit.direct(self)]
      end
    end
    def resolve_span!(ctx : Context, infer : Visitor)
      raise NotImplementedError.new("resolve_span! for #{self.class}")
    end

    abstract def tethers(querent : Info) : Array(Tether)
    def tether_terminal?
      false
    end
    def tether_upward_transform_span(ctx : Context, infer : Visitor, span : Span) : Span
      raise NotImplementedError.new("tether_upward_transform_span for #{self.class}:\n#{pos.show}")
    end
    def tether_resolve_span(ctx : Context, infer : Visitor)
      raise NotImplementedError.new("tether_resolve_span for #{self.class}:\n#{pos.show}")
    end

    # Most Info types ignore hints, but a few override this method to see them,
    # or to pass them along to other nodes that may wish to see them.
    def add_peer_hint(peer : Info)
    end

    # In the rare case that an Info subclass needs to dynamically pretend to be
    # a different downstream constraint, it can override this method.
    # If you need to report multiple positions, also override the other method
    # below called as_multiple_downstream_constraints.
    # This will prevent upstream DynamicInfos from eagerly resolving you.
    def as_downstream_constraint_meta_type(ctx : Context, type_check : TypeCheck::ForReifiedFunc) : MetaType?
      type_check.resolve(ctx, self)
    end

    # In the rare case that an Info subclass needs to dynamically pretend to be
    # multiple different downstream constraints, it can override this method.
    # This is only used to report positions in more detail, and it is expected
    # that the intersection of all MetaTypes here is the same as the resolve.
    def as_multiple_downstream_constraints(ctx : Context, type_check : TypeCheck::ForReifiedFunc) : Array({Source::Pos, MetaType})?
      nil
    end
  end

  abstract class DynamicInfo < Info
    # Must be implemented by the child class as an required hook.
    abstract def describe_kind : String

    def described_kind
      override_describe_kind || describe_kind
    end

    # May be implemented by the child class as an optional hook.
    def adds_alias; 0 end

    # Values flow downstream as the program executes;
    # the value flowing into a downstream must be a subtype of the downstream.
    # Type information can be inferred in either direction, but certain
    # Info node types are fixed, meaning that they act only as constraints
    # on their upstreams, and are not influenced at all by upstream info nodes.
    @downstreams = [] of Tuple(Source::Pos, Info, Int32)
    def add_downstream(use_pos : Source::Pos, info : Info, aliases : Int32)
      @downstreams << {use_pos, info, aliases + adds_alias}
      after_add_downstream(use_pos, info, aliases)
    end
    def downstreams_empty?
      @downstreams.empty?
    end
    def downstream_use_pos
      @downstreams.first[0]
    end
    def downstreams_each; @downstreams.each; end

    # May be implemented by the child class as an optional hook.
    def after_add_downstream(use_pos : Source::Pos, info : Info, aliases : Int32)
    end

    def downstream_tethers(querent : Info) : Array(Tether)
      @downstreams.flat_map do |pos, info, aliases|
        Tether.chain(info, querent).as(Array(Tether))
      end
    end

    def tethers(querent : Info) : Array(Tether)
      downstream_tethers(querent)
    end

    def tether_constraint_spans(ctx : Context, infer : Visitor)
      tethers(self).map(&.constraint_span(ctx, infer).as(Span))
    end

    # When we need to take into consideration the downstreams' constraints
    # in order to infer our type from them, we can use this to collect all
    # those constraints into one intersection of them all.
    def total_downstream_constraint(ctx : Context, type_check : TypeCheck::ForReifiedFunc)
      MetaType.new_intersection(
        @downstreams.compact_map do |_, other_info, _|
          other_info.as_downstream_constraint_meta_type(ctx, type_check).as(MetaType?)
        end
      )
    end

    def list_downstream_constraints(ctx : Context, type_check : TypeCheck::ForReifiedFunc)
      list = Array({Source::Pos, MetaType}).new
      @downstreams.each do |_, info, _|
        multi = info.as_multiple_downstream_constraints(ctx, type_check)
        if multi
          list.concat(multi)
        else
          mt = type_check.resolve(ctx, info)
          list.push({info.pos, mt}) if mt
        end
      end
      list.to_h.to_a
    end

    def describe_downstream_constraints(ctx : Context, type_check : TypeCheck::ForReifiedFunc)
      list_downstream_constraints(ctx, type_check).map { |other_pos, mt|
        {other_pos, "it is required here to be a subtype of #{mt.show_type}"}
      }
    end

    # This property can be set to give a hint in the event of a typecheck error.
    property this_would_be_possible_if : Tuple(Source::Pos, String)?
  end

  abstract class NamedInfo < DynamicInfo
    @explicit : Info?
    @upstreams = [] of Tuple(Info, Source::Pos)

    def initialize(@pos, @layer_index)
    end

    def upstream_infos; @upstreams.map(&.first) end

    def adds_alias; 1 end

    def first_viable_constraint_pos : Source::Pos
      (downstream_use_pos unless downstreams_empty?)
      @upstreams[0]?.try(&.[1]) ||
      @pos
    end

    def explicit? : Bool
      !!@explicit
    end

    def set_explicit(explicit : Info)
      raise "already set_explicit" if @explicit
      raise "shouldn't have an upstream yet" unless @upstreams.empty?

      @explicit = explicit
      @pos = explicit.pos
    end

    def as_conduit? : Conduit?
      # If we have an explicit type, we are not a conduit.
      return nil if @explicit

      # Only do conduit for Local variables, not any other NamedInfo.
      # TODO: Can/should we remove this limitation somehow,
      # or at least move this method override to that subclass instead?
      return nil unless is_a?(Local)

      # If the first immediate upstream is another NamedInfo, conduit to it.
      return nil if @upstreams.empty?
      return nil unless (upstream = @upstreams.first.first).is_a?(NamedInfo)
      Conduit.direct(upstream)
    end

    def resolve_span!(ctx : Context, infer : Visitor) : Span
      explicit = @explicit

      if explicit
        explicit_span = infer.resolve(ctx, explicit)

        if !explicit_span.any_mt?(&.cap_only?)
          # If we have an explicit type that is more than just a cap, return it.
          explicit_span
        elsif !@upstreams.empty?
          # If there are upstreams, use the explicit cap applied to the type of
          # each span entry of the upstreams, which becomes the canonical span.
          # TODO: use all upstreams if we can avoid infinite recursion
          upstream_span = infer.resolve(ctx, @upstreams.first.first)
          upstream_span.combine_mt(explicit_span) { |upstream_mt, cap_mt|
            upstream_mt.strip_cap.intersect(cap_mt)
          }
        else
          # If we have no upstreams and an explicit cap, return a span with
          # the empty trait called `Any` intersected with that cap.
          explicit_span.transform_mt do |explicit_mt|
            any = MetaType.new_nominal(infer.prelude_reified_type(ctx, "Any"))
            any.intersect(explicit_mt)
          end
        end
      elsif !@upstreams.empty? && (upstream_span = resolve_upstream_span(ctx, infer))
        # If we only have upstreams to go on, return the first upstream span.
        # TODO: use all upstreams if we can avoid infinite recursion
        upstream_span
      elsif !downstreams_empty?
        # If we only have downstream tethers, just do our best with those.
        Span.reduce_combine_mts(
          tether_constraint_spans(ctx, infer)
        ) { |accum, mt| accum.intersect(mt) }
        .not_nil!
        .transform_mt(&.strip_ephemeral) # TODO: add this?
      else
        # If we get here, we've failed and don't have enough info to continue.
        Span.error self,
          "This #{described_kind} needs an explicit type; it could not be inferred"
      end
      .transform_mt(&.strip_ephemeral)
    end

    def tethers(querent : Info) : Array(Tether)
      results = [] of Tether
      results.concat(Tether.chain(@explicit.not_nil!, querent)) if @explicit
      @downstreams.each do |pos, info, aliases|
        results.concat(Tether.chain(info, querent))
      end
      results
    end

    def after_add_downstream(use_pos : Source::Pos, info : Info, aliases : Int32)
      return if @explicit

      @upstreams.each do |upstream, upstream_pos|
        upstream.add_downstream(use_pos, info, aliases)
      end
    end

    def tether_upward_transform_span(ctx : Context, infer : Visitor, span : Span) : Span
      # TODO: aliasing/ephemerality
      span
    end

    def assign(ctx : Context, upstream : Info, upstream_pos : Source::Pos)
      @upstreams << {upstream, upstream_pos}

      if @explicit
        upstream.add_downstream(upstream_pos, @explicit.not_nil!, 0)
      else
        upstream.add_downstream(upstream_pos, self, 0)
      end
    end

    # By default, a NamedInfo will only treat the first assignment as relevant
    # for inferring when there is no explicit, but some subclasses may override.
    def infer_from_all_upstreams? : Bool; false end
    private def resolve_upstream_span(ctx : Context, infer : Visitor) : Span?
      use_upstream_infos =
        infer_from_all_upstreams? ? upstream_infos : [upstream_infos.first]

      upstream_spans =
        use_upstream_infos.flat_map(&.as_upstream_conduits).compact_map do |upstream_conduit|
          next if upstream_conduit.directly_references?(self)
          upstream_conduit.resolve_span!(ctx, infer)
        end

      Span.reduce_combine_mts(upstream_spans) { |accum, mt| accum.unite(mt) }
    end
  end

  class ErrorInfo < Info
    getter error : Error

    def pos; error.pos; end

    def layer_index; 0; end

    def describe_kind; ""; end

    def initialize(*args)
      @error = Error.build(*args)
    end

    def add_downstream(use_pos : Source::Pos, info : Info, aliases : Int32)
      nil
    end

    def tethers(querent : Info) : Array(Tether)
      [] of Tether
    end

    def resolve_span!(ctx : Context, infer : Visitor) : Span
      Span.new(Span::ErrorPropagate.new(error))
    end
  end

  abstract class FixedInfo < DynamicInfo # TODO: rename or split DynamicInfo to make this line make more sense
    def tether_terminal?
      true
    end

    def tether_resolve_span(ctx : Context, infer : Visitor)
      infer.resolve(ctx, self)
    end
  end

  class FixedPrelude < FixedInfo
    getter name : String

    def describe_kind : String; "expression" end

    def initialize(@pos, @layer_index, @name)
    end

    def resolve_span!(ctx : Context, infer : Visitor) : Span
      infer.prelude_type_span(ctx, @name)
    end
  end

  class FixedTypeExpr < FixedInfo
    getter node : AST::Node

    def describe_kind : String; "type expression" end

    def initialize(@pos, @layer_index, @node)
    end

    def resolve_span!(ctx : Context, infer : Visitor) : Span
      infer.unwrap_lazy_parts_of_type_expr_span(ctx,
        infer.type_expr_span(ctx, @node)
      )
    end
  end

  class FixedEnumValue < FixedInfo
    getter node : AST::Node

    def describe_kind : String; "expression" end

    def initialize(@pos, @layer_index, @node)
    end

    def resolve_span!(ctx : Context, infer : Visitor) : Span
      infer.unwrap_lazy_parts_of_type_expr_span(ctx,
        infer.type_expr_span(ctx, @node)
      )
    end
  end

  class FixedSingleton < FixedInfo
    getter node : AST::Node
    getter type_param_ref : Refer::TypeParam?

    def describe_kind : String; "singleton value for this type" end

    def initialize(@pos, @layer_index, @node, @type_param_ref = nil)
    end

    def resolve_span!(ctx : Context, infer : Visitor) : Span
      # If this node is further qualified, we don't want to both resolving it,
      # and doing so would trigger errors during type argument validation,
      # because the type arguments haven't been applied yet; they will be
      # applied in a different FixedSingleton that wraps this one in range.
      # We don't have to resolve it because nothing will ever be its downstream.
      return Span.simple(MetaType.unconstrained) \
        if @node.is_a?(AST::Identifier) \
        && infer.classify.further_qualified?(@node)

      infer.unwrap_lazy_parts_of_type_expr_span(ctx,
        infer.type_expr_span(ctx, @node).transform_mt(&.override_cap(Infer::Cap::NON))
      )
    end
  end

  class Self < FixedInfo
    def describe_kind : String; "receiver value" end

    def initialize(@pos, @layer_index)
    end

    def resolve_span!(ctx : Context, infer : Visitor) : Span
      infer.self_type_expr_span(ctx)
    end
  end

  class FromConstructor < FixedInfo
    def describe_kind : String; "constructed object" end

    def initialize(@pos, @layer_index, @cap : String)
    end

    def resolve_span!(ctx : Context, infer : Visitor) : Span
      infer.self_ephemeral_with_cap(ctx, @cap)
    end
  end

  class AddressOf < DynamicInfo
    getter variable : Info

    def describe_kind : String; "address of this variable" end

    def initialize(@pos, @layer_index, @variable)
    end
  end

  class ReflectionOfType < DynamicInfo
    getter reflect_type : Info

    def describe_kind : String; "type reflection" end

    def initialize(@pos, @layer_index, @reflect_type)
    end

    def resolve_span!(ctx : Context, infer : Visitor) : Span
      # Take note of this reflection.
      infer.analysis.reflections.add(self)

      infer.prelude_type_span(ctx, "ReflectionOfType")
        .combine_mt(infer.resolve(ctx, @reflect_type)) { |target_mt, arg_mt|
          MetaType.new(ReifiedType.new(target_mt.single!.link, [arg_mt]))
        }
    end
  end

  class Literal < DynamicInfo
    getter peer_hints

    def describe_kind : String; "literal value" end

    def initialize(@pos, @layer_index, @possible : MetaType)
      @peer_hints = [] of Info
    end

    def add_peer_hint(peer : Info)
      @peer_hints << peer
    end

    def describe_peer_hints(ctx : Context, type_check : TypeCheck::ForReifiedFunc)
      @peer_hints.compact_map do |peer|
        mt = type_check.resolve(ctx, peer)
        next unless mt
        {peer.pos, "it is suggested here that it might be a #{mt.show_type}"}
      end
    end

    def resolve_span!(ctx : Context, infer : Visitor) : Span
      simple_span = Span.simple(@possible)

      # Look at downstream tether constraints to try to resolve the literal
      # to a more specific type than the simple "possible" type indicated by it.
      constrained_span =
        Span.reduce_combine_mts(
          tether_constraint_spans(ctx, infer)
        ) { |accum, mt| accum.intersect(mt) }.try { |constraint_span|
          constraint_span.combine_mt(simple_span) { |constraint_mt, mt|
            constrained_mt = mt.intersect(constraint_mt)
            constrained_mt.unsatisfiable? ? @possible : constrained_mt
          }
        } || simple_span

      peer_hints_span = Span.reduce_combine_mts(
        @peer_hints.map { |peer| infer.resolve(ctx, peer).as(Span) }
      ) { |accum, mt| accum.intersect(mt) }

      constrained_span
      .maybe_fallback_based_on_mt_simplify([
        # If we don't satisfy the constraints, go with our simply type
        # and let the type checker print a message about why it doesn't work.
        {:mt_unsatisfiable, simple_span},

        # If, after constraining, we are still not a single concrete type,
        # try to apply peer hints to the constrained type if any are available.
        {:mt_non_singular_concrete,
          if peer_hints_span
            constrained_span.combine_mt(peer_hints_span) { |constrained_mt, peers_mt|
              hinted_mt = constrained_mt.intersect(peers_mt)
              hinted_mt.unsatisfiable? ? @possible : hinted_mt
            }
            .maybe_fallback_based_on_mt_simplify([
              # If, with peer hints, we are still not a single concrete type,
              # there's nothing more to try, so we return the simple type.
              {:mt_non_singular_concrete, simple_span}
            ])
          else
            simple_span
          end
        }
      ])
    end
  end

  class LocalRef < Info
    getter info : DynamicInfo
    getter ref : Refer::Local

    def describe_kind : String; info.describe_kind end

    def initialize(@info, @layer_index, @ref)
    end

    def pos
      @info.pos
    end

    def add_downstream(use_pos : Source::Pos, info : Info, aliases : Int32)
      @info.add_downstream(use_pos, info, aliases)
    end

    def tethers(querent : Info) : Array(Tether)
      @info.tethers(querent)
    end

    def add_peer_hint(peer : Info)
      @info.add_peer_hint(peer)
    end

    def as_conduit? : Conduit?
      Conduit.direct(@info)
    end
  end

  class FuncBody < NamedInfo
    getter early_returns : Array(JumpReturn)
    def initialize(pos, layer_index, @early_returns)
      super(pos, layer_index)

      early_returns.each(&.term.try(&.add_downstream(@pos, self, 0)))
    end
    def describe_kind : String; "function body" end

    def infer_from_all_upstreams? : Bool; true end
  end

  class Local < NamedInfo
    def describe_kind : String; "local variable" end
  end

  class Param < NamedInfo
    def describe_kind : String; "parameter" end
  end

  class YieldIn < NamedInfo
    def describe_kind : String; "yielded argument" end
  end

  class YieldOut < NamedInfo
    def describe_kind : String; "yielded result" end
  end

  class Field < DynamicInfo
    getter name : String

    def initialize(@pos, @layer_index, @name)
      @upstreams = [] of Info
    end

    def describe_kind : String; "field reference" end

    def assign(ctx : Context, upstream : Info, upstream_pos : Source::Pos)
      upstream.add_downstream(upstream_pos, self, 0)
      @upstreams << upstream
    end

    def resolve_span!(ctx : Context, infer : Visitor) : Span
      infer.self_type_expr_span(ctx).transform_mt_to_span do |call_mt|
        call_defn = call_mt.single!
        call_func = call_defn.defn(ctx).functions.find do |f|
          f.ident.value == @name && f.has_tag?(:field)
        end.not_nil!

        call_link = call_func.make_link(call_defn.link)
        infer.depends_on_call_ret_span(ctx, call_defn, call_func, call_link,
            call_mt.cap_only_inner.value.as(Cap))
      end
    rescue error : Error
      Span.new(Span::ErrorPropagate.new(error))
    end

    def tether_terminal?
      true
    end

    def tether_resolve_span(ctx : Context, infer : Visitor)
      infer.resolve(ctx, self)
    end
  end

  class FieldRead < DynamicInfo
    getter :field

    def initialize(@field : Field, @origin : Self)
      @layer_index = @field.layer_index
    end

    def describe_kind : String; "field read" end

    def pos
      @field.pos
    end

    def resolve_span!(ctx : Context, infer : Visitor) : Span
      origin_span = infer.resolve(ctx, @origin)
      field_span = infer.resolve(ctx, @field)
      origin_span.combine_mt(field_span) { |o, f| f.viewed_from(o).alias }
    end
  end

  class FieldExtract < DynamicInfo
    def initialize(@field : Field, @origin : Self)
      @layer_index = @field.layer_index
    end

    def describe_kind : String; "field extraction" end

    def pos
      @field.pos
    end

    def resolve_span!(ctx : Context, infer : Visitor) : Span
      origin_span = infer.resolve(ctx, @origin)
      field_span = infer.resolve(ctx, @field)
      origin_span.combine_mt(field_span) { |o, f| f.extracted_from(o).ephemeralize }
    end
  end

  abstract class JumpInfo < Info
    getter term : Info
    def initialize(@pos, @layer_index, @term)
    end

    def describe_kind : String; "control flow jump" end

    abstract def error_jump_name

    def add_downstream(use_pos : Source::Pos, info : Info, aliases : Int32)
      Error.at use_pos,
        "\"#{error_jump_name}\" expression never returns any value"
    end

    def tethers(querent : Info) : Array(Tether)
      term.tethers(querent)
    end

    def resolve_span!(ctx : Context, infer : Visitor) : Span
      # A jump expression has no result value, so the resolved type is always
      # unconstrained - the term's type goes to the jump's catching entity.
      Span.simple(MetaType.unconstrained)
    end
  end

  class JumpError < JumpInfo
    def error_jump_name; "error!" end
  end

  class JumpReturn < JumpError
    def error_jump_name; "return" end
  end

  class JumpBreak < JumpError
    def error_jump_name; "break" end
  end

  class JumpContinue < JumpError
    def error_jump_name; "continue" end
  end

  class Sequence < Info
    getter terms : Array(Info)
    getter final_term : Info

    def describe_kind : String; "sequence" end

    def initialize(pos, @layer_index, @terms)
      @final_term = @terms.empty? ? FixedPrelude.new(pos, @layer_index, "None") : @terms.last
      @pos = @final_term.pos
    end

    def add_downstream(use_pos : Source::Pos, info : Info, aliases : Int32)
      final_term.add_downstream(use_pos, info, aliases)
    end

    def tethers(querent : Info) : Array(Tether)
      final_term.tethers(querent)
    end

    def add_peer_hint(peer : Info)
      final_term.add_peer_hint(peer)
    end

    def as_conduit? : Conduit?
      Conduit.direct(@final_term)
    end
  end

  # TODO: add some kind of logic for analyzing exhausted choices,
  # as well as necessary/sufficient conditions for each branch to be in play
  # letting us better specialize the codegen later by eliminating impossible
  # branches in particular reifications of this type or function.
  abstract class Phi < DynamicInfo
    getter fixed_bool : Info
    getter branches : Array({Info?, Info, Bool})

    def describe_kind : String; "choice block" end

    def initialize(@pos, @layer_index, @branches, @fixed_bool)
      prior_bodies = [] of Info
      @branches.each do |cond, body, body_jumps_away|
        next if body_jumps_away
        body.add_downstream(@pos, self, 0)
        prior_bodies.each { |prior_body| body.add_peer_hint(prior_body) }
        prior_bodies << body
      end

      # Each condition must evaluate to a type of Bool.
      @branches.each do |cond, body, body_jumps_away|
        cond.add_downstream(pos, @fixed_bool, 1) if cond
      end
    end

    def as_conduit? : Conduit?
      # TODO: Keep in separate span points instead of union if any of the conds
      # can be statically determinable, leaving room for specialization.
      Conduit.union(
        @branches.compact_map do |cond, body, body_jumps_away|
          body unless body_jumps_away
        end
      )
    end

    def tether_upward_transform_span(ctx : Context, infer : Visitor, span : Span) : Span
      # TODO: account for unreachable branches? maybe? maybe not?
      span
    end

    def as_downstream_constraint_meta_type(ctx : Context, type_check : TypeCheck::ForReifiedFunc) : MetaType
      total_downstream_constraint(ctx, type_check)
    end

    def as_multiple_downstream_constraints(ctx : Context, type_check : TypeCheck::ForReifiedFunc) : Array({Source::Pos, MetaType})?
      @downstreams.flat_map do |pos, info, aliases|
        multi = info.as_multiple_downstream_constraints(ctx, type_check)
        next multi if multi

        mt = info.as_downstream_constraint_meta_type(ctx, type_check)
        next {info.pos, mt} if mt

        [] of {Source::Pos, MetaType}
      end
    end
  end

  class Loop < Phi
    getter early_breaks : Array(JumpBreak)
    getter early_continues : Array(JumpContinue)

    def initialize(pos, layer_index, branches, fixed_bool, @early_breaks, @early_continues)
      super(pos, layer_index, branches, fixed_bool)

      early_breaks.each(&.term.add_downstream(@pos, self, 0))
      early_continues.each(&.term.add_downstream(@pos, self, 0))
    end
  end

  class Choice < Phi
  end

  class TypeParamCondition < FixedInfo
    getter refine : Refer::TypeParam
    getter lhs : Info
    getter refine_type : Info
    getter positive_check : Bool

    def describe_kind : String; "type parameter condition" end

    def initialize(@pos, @layer_index, @refine, @lhs, @refine_type, @positive_check)
    end

    def resolve_span!(ctx : Context, infer : Visitor) : Span
      infer.prelude_type_span(ctx, "Bool")
    end
  end

  class TypeCondition < FixedInfo
    getter lhs : Info
    getter rhs : Info
    getter positive_check : Bool

    def describe_kind : String; "type condition" end

    def initialize(@pos, @layer_index, @lhs, @rhs, @positive_check)
    end

    def resolve_span!(ctx : Context, infer : Visitor) : Span
      infer.prelude_type_span(ctx, "Bool")
    end
  end

  class TypeConditionForLocal < FixedInfo
    getter refine : AST::Node
    getter refine_type : Info
    getter positive_check : Bool

    def describe_kind : String; "type condition" end

    def initialize(@pos, @layer_index, @refine, @refine_type, @positive_check)
    end

    def resolve_span!(ctx : Context, infer : Visitor) : Span
      infer.prelude_type_span(ctx, "Bool")
    end
  end

  class TypeConditionStatic < FixedInfo
    getter lhs : Info
    getter rhs : Info
    getter positive_check : Bool

    def describe_kind : String; "static type condition" end

    def initialize(@pos, @layer_index, @lhs, @rhs, @positive_check)
    end

    def resolve_span!(ctx : Context, infer : Visitor) : Span
      infer.prelude_type_span(ctx, "Bool")
    end
  end

  class Refinement < DynamicInfo
    getter refine : Info
    getter refine_type : Info
    getter positive_check : Bool

    def describe_kind : String; "type refinement" end

    def initialize(@pos, @layer_index, @refine, @refine_type, @positive_check)
    end

    def resolve_span!(ctx : Context, infer : Visitor) : Span
      infer.resolve(ctx, @refine)
      .combine_mt(infer.resolve(ctx, @refine_type)) { |lhs_mt, rhs_mt|
        rhs_mt = rhs_mt.strip_cap.negate if !@positive_check
        lhs_mt.intersect(rhs_mt)
      }
    end
  end

  class Consume < Info
    getter local : Info

    def describe_kind : String; "consumed reference" end

    def initialize(@pos, @layer_index, @local)
    end

    def as_conduit? : Conduit?
      Conduit.ephemeralize(@local)
    end

    def add_downstream(use_pos : Source::Pos, info : Info, aliases : Int32)
      @local.add_downstream(use_pos, info, aliases - 1)
    end

    def tethers(querent : Info) : Array(Tether)
      Tether.chain(@local, querent)
    end

    def add_peer_hint(peer : Info)
      @local.add_peer_hint(peer)
    end
  end

  class RecoverUnsafe < Info
    getter body : Info

    def describe_kind : String; "recover block" end

    def initialize(@pos, @layer_index, @body)
    end

    def add_downstream(use_pos : Source::Pos, info : Info, aliases : Int32)
      # TODO: Make recover safe.
      # @body.add_downstream(use_pos, info, aliases)
    end

    def tethers(querent : Info) : Array(Tether)
      Tether.chain(@body, querent)
    end

    def tether_upward_transform_span(ctx : Context, infer : Visitor, span : Span) : Span
      span.transform_mt(&.strip_cap)
    end

    def add_peer_hint(peer : Info)
      @body.add_peer_hint(peer)
    end
  end

  class FromAssign < Info
    getter lhs : NamedInfo
    getter rhs : Info

    def describe_kind : String; "assign result" end

    def initialize(@pos, @layer_index, @lhs, @rhs)
    end

    def add_downstream(use_pos : Source::Pos, info : Info, aliases : Int32)
      @lhs.add_downstream(use_pos, info, aliases)
    end

    def tethers(querent : Info) : Array(Tether)
      Tether.chain(@lhs, querent)
    end

    def add_peer_hint(peer : Info)
      @lhs.add_peer_hint(peer)
    end

    def as_conduit? : Conduit?
      Conduit.alias(@lhs)
    end
  end

  class FromYield < Info
    getter yield_in : Info
    getter terms : Array(Info)

    def describe_kind : String; "value returned by the yield block" end

    def initialize(@pos, @layer_index, @yield_in, @terms)
    end

    def add_downstream(use_pos : Source::Pos, info : Info, aliases : Int32)
      @yield_in.add_downstream(use_pos, info, aliases)
    end

    def tethers(querent : Info) : Array(Tether)
      Tether.chain(@yield_in, querent)
    end

    def add_peer_hint(peer : Info)
      @yield_in.add_peer_hint(peer)
    end

    def as_conduit? : Conduit?
      Conduit.direct(@yield_in)
    end
  end

  class ArrayLiteral < DynamicInfo
    getter terms : Array(Info)

    def describe_kind : String; "array literal" end

    def initialize(@pos, @layer_index, @terms)
    end

    def after_add_downstream(use_pos : Source::Pos, info : Info, aliases : Int32)
      # Only do this after the first downstream is added.
      return unless @downstreams.size == 1

      elem_downstream = ArrayLiteralElementAntecedent.new(@downstreams.first[1].pos, @layer_index, self)
      @terms.each do |term|
        term.add_downstream(downstream_use_pos, elem_downstream, 0)
      end
    end

    def tether_upward_transform_span(ctx : Context, infer : Visitor, span : Span) : Span
      span
    end

    def possible_antecedents_span(ctx, infer) : Span?
      array_info = self
      tether_spans = tether_constraint_spans(ctx, infer)

      return nil if tether_spans.empty?

      ante_span =
        Span
        .reduce_combine_mts(tether_spans) { |accum, mt| accum.intersect(mt) }
        .not_nil!
        .transform_mt { |mt|
          ante_mts = mt.each_reachable_defn_with_cap(ctx).compact_map { |rt, cap|
            # TODO: Support more element antecedent detection patterns.
            if rt.link.name == "Array" && rt.args.size == 1
              array_mt = MetaType.new_nominal(rt).intersect(MetaType.new(cap))
              array_mt
            end
          }
          ante_mts.empty? ? MetaType.unconstrained : MetaType.new_union(ante_mts)
        }

      ante_span unless ante_span.any_mt?(&.unconstrained?)
    end

    def resolve_span!(ctx : Context, infer : Visitor) : Span
      # By default, an array literal has a cap of `ref`.
      # TODO: span should allow ref, val, trn, or iso cap possibilities.
      array_cap = MetaType::Capability::REF

      ante_span = possible_antecedents_span(ctx, infer)

      elem_spans = terms.map { |term| infer.resolve(ctx, term).as(Span) }
      elem_span = Span
        .reduce_combine_mts(elem_spans) { |accum, mt| accum.unite(mt) }
        .try(&.transform_mt(&.alias))

      if ante_span
        if elem_span
          ante_span.combine_mt_to_span(elem_span) { |ante_mt, elem_mt|
            # We know/assert that the antecedent MetaType is in the form of
            # a cap intersected with an Array ReifiedType, so we know that
            # we can get the element MetaType from the ReifiedType's type args.
            ante_elem_mt = ante_mt.single!.args[0]
            fallback_rt = infer.prelude_reified_type(ctx, "Array", [elem_mt])
            fallback_mt = MetaType.new(fallback_rt).intersect(MetaType.cap("ref"))

            # We may need to unwrap lazy elements from this inner layer.
            ante_elem_mt = infer
              .unwrap_lazy_parts_of_type_expr_span(ctx, Span.simple(ante_elem_mt))
              .inner.as(Span::Terminal).meta_type

            # For every pair of element MetaType and antecedent MetaType,
            # Treat the antecedent MetaType as the default, but
            # fall back to using the element MetaType if the intersection
            # of those two turns out to be unsatisfiable.
            Span.simple_with_fallback(ante_mt,
              ante_elem_mt.intersect(elem_mt.ephemeralize), [
                {:mt_unsatisfiable, Span.simple(fallback_mt)}
              ]
            )
          }
        else
          ante_span
        end
      else
        if elem_span
          # TODO: is this "transform_mt_using" call even doing anything?
          array_span = elem_span.transform_mt_using(self) { |elem_mt, maybe_self_mt|
            array_cap = maybe_self_mt.try(&.inner.as(MetaType::Capability)) || MetaType::Capability::REF

            rt = infer.prelude_reified_type(ctx, "Array", [elem_mt])
            mt = MetaType.new(rt, array_cap.value.as(Cap))

            mt
          }
        else
          Span.error(pos, "The type of this empty array literal " \
            "could not be inferred (it needs an explicit type)")
        end
      end

      # Take note of the function calls implied (used later for reachability).
      .tap { |array_span|
        infer.analysis.called_func_spans[self] = {
          array_span.transform_mt(&.override_cap(Cap::REF)), # always use ref
          ["new", "<<"]
        }
      }
    end
  end

  class ArrayLiteralElementAntecedent < DynamicInfo
    getter array : ArrayLiteral

    def describe_kind : String; "array element" end

    def initialize(@pos, @layer_index, @array)
    end

    def as_conduit? : Conduit?
      Conduit.array_literal_element_antecedent(@array)
    end

    def tethers(querent : Info) : Array(Tether)
      Tether.chain(@array, querent)
    end

    def tether_upward_transform_span(ctx : Context, infer : Visitor, span : Span) : Span
      infer.unwrap_lazy_parts_of_type_expr_span(ctx,
        span.transform_mt do |meta_type|
          results = [] of MetaType

          meta_type.simplify(ctx).each_reachable_defn(ctx).each do |rt|
            # TODO: Support more element antecedent detection patterns.
            if rt.link.name == "Array" \
            && rt.args.size == 1
              results << rt.args.first.simplify(ctx)
            end
          end

          # TODO: support multiple antecedents gracefully?
          if results.size != 1
            next MetaType.unconstrained
          end

          results.first.not_nil!
        end
      )
    end
  end

  class FromCall < DynamicInfo
    getter lhs : Info
    getter member : String
    getter args : AST::Group?
    getter yield_params : AST::Group?
    getter yield_block : AST::Group?
    getter ret_value_used : Bool

    def initialize(@pos, @layer_index, @lhs, @member, @args, @yield_params, @yield_block, @ret_value_used)
    end

    def describe_kind : String; "return value" end

    def tethers(querent : Info) : Array(Tether)
      Tether.chain(@lhs, querent)
    end

    def tether_upward_transform_span(ctx : Context, infer : Visitor, span : Span) : Span
      # TODO: is it possible to use the meta_type passed to us above,
      # at least in some cases, instead of eagerly resolving here?
      infer.resolve(ctx, self)
    end

    def resolve_receiver_span(ctx : Context, infer : Visitor) : Span
      infer.analysis.called_func_spans[self]?.try(&.first) || begin
        call_receiver_span = infer.resolve(ctx, @lhs)
          .transform_mt_to_span(&.gather_call_receiver_span(ctx, @pos, infer, @member))

        # Save the call defn span to the analysis (used later for reachability).
        infer.analysis.called_func_spans[self] = {call_receiver_span, @member}

        call_receiver_span
      end
    end

    def resolve_span!(ctx : Context, infer : Visitor) : Span
      lhs_span = infer.resolve(ctx, @lhs)

      resolve_receiver_span(ctx, infer).combine_mt_to_span(lhs_span) { |call_receiver_mt, lhs_mt|
        union_member_spans = call_receiver_mt.map_each_union_member { |union_member_mt|
          intersection_term_spans = union_member_mt.map_each_intersection_term_and_or_cap { |term_mt|
            call_mt = union_member_mt
            call_defn = term_mt.single!
            call_func = call_defn.defn(ctx).find_func!(@member)
            call_link = call_func.make_link(call_defn.link)

            # If this is a constructor, we know what the result type will be
            # without needing to actually depend on the other analysis' span.
            if call_func.has_tag?(:constructor)
              new_mt = call_mt
                .intersect(lhs_mt)
                .strip_cap
                .intersect(MetaType.cap(call_func.cap.value))
                .ephemeralize

              next Span.simple(new_mt)
            end

            infer
              .depends_on_call_ret_span(ctx, call_defn, call_func, call_link,
                call_mt.cap_only_inner.value.as(Cap))
              .transform_mt(&.ephemeralize)
          }
          Span.reduce_combine_mts(intersection_term_spans) { |accum, mt| accum.intersect(mt) }.not_nil!
        }
        Span.reduce_combine_mts(union_member_spans) { |accum, mt| accum.unite(mt) }.not_nil!
      }
    end

    def follow_call_check_receiver_cap(ctx : Context, calling_func, call_mt, call_func, problems)
      call = self
      call_cap_mt = call_mt.cap_only
      autorecover_needed = false

      call_func_cap = MetaType::Capability.new_maybe_generic(call_func.cap.value)
      call_func_cap_mt = MetaType.new(call_func_cap)

      # The required capability is the receiver capability of the function,
      # unless it is an asynchronous function, in which case it is tag.
      required_cap = call_func_cap
      required_cap = MetaType::Capability.new(Cap::TAG) \
        if call_func.has_tag?(:async) && !call_func.has_tag?(:constructor)

      receiver_okay =
        if required_cap.value.is_a?(Cap)
          call_cap_mt.subtype_of?(ctx, MetaType.new(required_cap))
        else
          call_cap_mt.satisfies_bound?(ctx, MetaType.new(required_cap))
        end

      # Enforce the capability restriction of the receiver.
      if receiver_okay
        # For box functions only, we reify with the actual cap on the caller side.
        # Or rather, we use "ref", "box", or "val", depending on the caller cap.
        # For all other functions, we just use the cap from the func definition.
        reify_cap =
          if required_cap.value == Cap::BOX
            case call_cap_mt.inner.as(MetaType::Capability).value
            when Cap::ISO, Cap::TRN, Cap::REF then MetaType.cap(Cap::REF)
            when Cap::VAL then MetaType.cap(Cap::VAL)
            else MetaType.cap(Cap::BOX)
            end
          # TODO: This shouldn't be a special case - any generic cap should be accepted.
          elsif required_cap.value.is_a?(Set(MetaType::Capability))
            call_cap_mt
          else
            call_func_cap_mt
          end
      elsif call_func.has_tag?(:constructor)
        # Constructor calls ignore cap of the original receiver.
        reify_cap = call_func_cap_mt
      elsif call_cap_mt.ephemeralize.subtype_of?(ctx, MetaType.new(required_cap))
        # We failed, but we may be able to use auto-recovery.
        # Take note of this and we'll finish the auto-recovery checks later.
        autorecover_needed = true
        # For auto-recovered calls, always use the cap of the func definition.
        reify_cap = call_func_cap_mt
      else
        # We failed entirely; note the problem and carry on.
        problems << {call_func.cap.pos,
          "the type #{call_mt.inner.inspect} isn't a subtype of the " \
          "required capability of '#{required_cap}'"}

        # If the receiver of the call is the self (the receiver of the caller),
        # then we can give an extra hint about changing its capability to match.
        if @lhs.is_a?(Self)
          problems << {calling_func.cap.pos, "this would be possible if the " \
            "calling function were declared as `:fun #{required_cap}`"}
        end

        # We already failed subtyping for the receiver cap, but pretend
        # for now that we didn't for the sake of further checks.
        reify_cap = call_func_cap_mt
      end

      if autorecover_needed \
      && required_cap.value != Cap::REF && required_cap.value != Cap::BOX
        problems << {call_func.cap.pos,
          "the function's required receiver capability is `#{required_cap}` " \
          "but only a `ref` or `box` function can be auto-recovered"}

        problems << {@lhs.pos,
          "auto-recovery was attempted because the receiver's type is " \
          "#{call_mt.inner.inspect}"}
      end

      {reify_cap, autorecover_needed}
    end

    def follow_call_check_args(ctx : Context, infer, call_func, problems)
      call = self

      # Just check the number of arguments.
      # We will check the types in another Info type (TowardCallParam)
      arg_count = call.args.try(&.terms.size) || 0
      max = AST::Extract.params(call_func.params).size
      min = AST::Extract.params(call_func.params).count { |(ident, type, default)| !default }
      func_pos = call_func.ident.pos

      if arg_count > max
        max_text = "#{max} #{max == 1 ? "argument" : "arguments"}"
        params_pos = call_func.params.try(&.pos) || call_func.ident.pos
        problems << {call.pos, "the call site has too many arguments"}
        problems << {params_pos, "the function allows at most #{max_text}"}
      elsif arg_count < min
        min_text = "#{min} #{min == 1 ? "argument" : "arguments"}"
        params_pos = call_func.params.try(&.pos) || call_func.ident.pos
        problems << {call.pos, "the call site has too few arguments"}
        problems << {params_pos, "the function requires at least #{min_text}"}
      end
    end

    def follow_call_check_autorecover_cap(
      ctx : Context,
      type_check : TypeCheck::ForReifiedFunc,
      call_func : Program::Function,
      ret_mt : MetaType
    )
      call = self

      # If autorecover of the receiver cap was needed to make this call work,
      # we now have to confirm that arguments and return value are all sendable.
      problems = [] of {Source::Pos, String}

      unless ret_mt.is_sendable? || !call.ret_value_used
        problems << {(call_func.ret || call_func.ident).pos,
          "the return type #{ret_mt.show_type} isn't sendable " \
          "and the return value is used (the return type wouldn't matter " \
          "if the calling side entirely ignored the return value)"}
      end

      # TODO: It should be safe to pass in a TRN if the receiver is TRN,
      # so is_sendable? isn't quite liberal enough to allow all valid cases.
      call.args.try(&.terms.each do |arg|
        resolved_arg = type_check.resolve(ctx, type_check.pre_infer[arg])
        if resolved_arg && !resolved_arg.alias.is_sendable?
          problems << {arg.pos,
            "the argument (when aliased) has a type of " \
            "#{resolved_arg.alias.show_type}, which isn't sendable"}
        end
      end)

      ctx.error_at call,
        "This function call won't work unless the receiver is ephemeral; " \
        "it must either be consumed or be allowed to be auto-recovered. "\
        "Auto-recovery didn't work for these reasons",
          problems unless problems.empty?
    end
  end

  class FromCallYieldOut < DynamicInfo
    getter call : FromCall
    getter index : Int32

    def describe_kind : String; "value yielded to this block" end

    def initialize(@pos, @layer_index, @call, @index)
    end

    def tether_terminal?
      true
    end

    def tether_resolve_span(ctx : Context, infer : Visitor)
      infer.resolve(ctx, self)
    end

    def resolve_span!(ctx : Context, infer : Visitor) : Span
      @call.resolve_receiver_span(ctx, infer).transform_mt_to_span { |call_receiver_mt|
        union_member_spans = call_receiver_mt.map_each_union_member { |union_member_mt|
          intersection_term_spans = union_member_mt.map_each_intersection_term_and_or_cap { |term_mt|
            call_defn = term_mt.single!
            call_func = call_defn.defn(ctx).find_func!(@call.member)
            call_link = call_func.make_link(call_defn.link)

            raw_ret_span = infer
              .depends_on_call_yield_out_span(ctx, call_defn, call_func, call_link,
                term_mt.cap_only_inner.value.as(Cap), @index)

            unless raw_ret_span
              call_name = "#{call_defn.defn(ctx).ident.value}.#{@call.member}"
              next Span.error(pos,
                "This yield block parameter will never be received", [
                  {call_func.ident.pos, "'#{call_name}' does not yield it"}
                ]
              )
            end

            raw_ret_span.not_nil!
          }
          Span.reduce_combine_mts(intersection_term_spans) { |accum, mt| accum.intersect(mt) }.not_nil!
        }
        Span.reduce_combine_mts(union_member_spans) { |accum, mt| accum.unite(mt) }.not_nil!
      }
    end
  end

  class TowardCallYieldIn < DynamicInfo
    getter call : FromCall

    def describe_kind : String; "expected for the yield result" end

    def initialize(@pos, @layer_index, @call)
    end

    def resolve_span!(ctx : Context, infer : Visitor) : Span
      none = MetaType.new(infer.prelude_reified_type(ctx, "None"))

      @call.resolve_receiver_span(ctx, infer).transform_mt_to_span { |call_receiver_mt|
        union_member_spans = call_receiver_mt.map_each_union_member { |union_member_mt|
          intersection_term_spans = union_member_mt.map_each_intersection_term_and_or_cap { |term_mt|
            call_defn = term_mt.single!
            call_func = call_defn.defn(ctx).find_func!(@call.member)
            call_link = call_func.make_link(call_defn.link)

            raw_ret_span = infer
              .depends_on_call_yield_in_span(ctx, call_defn, call_func, call_link,
                term_mt.cap_only_inner.value.as(Cap))

            next Span.simple(MetaType.unconstrained) unless raw_ret_span

            raw_ret_span.not_nil!
          }
          Span.reduce_combine_mts(intersection_term_spans) { |accum, mt| accum.intersect(mt) }.not_nil!
        }
        Span.reduce_combine_mts(union_member_spans) { |accum, mt| accum.intersect(mt) }.not_nil!
      }.transform_mt { |mt|
        # If the type requirement is None, treat it as unconstrained,
        # so that the caller need not specify an explicit None.
        # TODO: consider adding a special case Void type like Swift has?
        mt == none ? MetaType.unconstrained : mt
      }
    end
  end

  class TowardCallParam < DynamicInfo
    getter call : FromCall
    getter index : Int32

    def describe_kind : String; "parameter for this argument" end

    def initialize(@pos, @layer_index, @call, @index)
    end

    def tether_terminal?
      true
    end

    def tether_resolve_span(ctx : Context, infer : Visitor)
      resolve_span!(ctx, infer) # TODO: should this be infer.resolve(ctx, self) instead?
    end

    def as_multiple_downstream_constraints(ctx : Context, type_check : TypeCheck::ForReifiedFunc) : Array({Source::Pos, MetaType})?
      rf = type_check.reified
      results = [] of {Source::Pos, MetaType}

      ctx.infer[rf.link].each_called_func_within(ctx, rf, for_info: @call) { |other_info, other_rf|
        next unless other_info == call

        param_mt = other_rf.meta_type_of_param(ctx, @index)
        next unless param_mt

        param = other_rf.link.resolve(ctx).params.not_nil!.terms.[@index]
        pre_infer = ctx.pre_infer[other_rf.link]
        param_info = pre_infer[param]
        param_info = param_info.lhs if param_info.is_a?(FromAssign)
        param_info = param_info.as(Param)
        results << {param_info.first_viable_constraint_pos, param_mt}
      }

      results
    end

    def resolve_span!(ctx : Context, infer : Visitor) : Span
      @call.resolve_receiver_span(ctx, infer).transform_mt_to_span { |call_receiver_mt|
        union_member_spans = call_receiver_mt.map_each_union_member { |union_member_mt|
          intersection_term_spans = union_member_mt.map_each_intersection_term_and_or_cap { |term_mt|
            call_defn = term_mt.single!
            call_func = call_defn.defn(ctx).find_func!(@call.member)
            call_link = call_func.make_link(call_defn.link)

            param_span = infer
              .depends_on_call_param_span(ctx, call_defn, call_func, call_link,
                term_mt.cap_only_inner.value.as(Cap), @index)

            next Span.simple(MetaType.unconstrained) unless param_span

            param_span
          }
          Span.reduce_combine_mts(intersection_term_spans) { |accum, mt| accum.intersect(mt) }.not_nil!
        }
        Span.reduce_combine_mts(union_member_spans) { |accum, mt| accum.intersect(mt) }.not_nil!
      }
    end
  end
end
