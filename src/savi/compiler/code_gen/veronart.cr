class Savi::Compiler::CodeGen::VeronaRT
  # Set to true only for debugging CodeGen of programs; otherwise, false.
  # TODO: Should this be configurable by a flag at runtime?
  USE_SYSTEMATIC_TESTING = true

  # The size by which every Cown object is padded with runtime-internal data.
  # We cheat the size smaller by point pointer here because we know the first
  # pointer is the type descriptor, which we still try not to touch directly,
  # except in cases where we are mimicking with non-runtime-allocated objects.
  OBJECT_PAD_SIZE = 8 * (3 - 1)                               # TODO: cross-platform - not only the outer 8, but also the inner 3 is platform-dependent...
  COWN_PAD_SIZE = 8 * ((USE_SYSTEMATIC_TESTING ? 12 : 8) - 1) # TODO: cross-platform - not only the outer 8, but also the inner 12 and 8 are platform-dependent...

  getter desc
  getter obj

  def initialize(llvm : LLVM::Context, target_machine : LLVM::TargetMachine)
    # Standard types.
    @void     = llvm.void.as(LLVM::Type)
    @ptr      = llvm.int8.pointer.as(LLVM::Type)
    @pptr     = llvm.int8.pointer.pointer.as(LLVM::Type)
    @i1       = llvm.int1.as(LLVM::Type)
    @i1_false = llvm.int1.const_int(0).as(LLVM::Value)
    @i1_true  = llvm.int1.const_int(1).as(LLVM::Value)
    @i8       = llvm.int8.as(LLVM::Type)
    @i16      = llvm.int16.as(LLVM::Type)
    @i32      = llvm.int32.as(LLVM::Type)
    @i32_ptr  = llvm.int32.pointer.as(LLVM::Type)
    @i32_0    = llvm.int32.const_int(0).as(LLVM::Value)
    @i64      = llvm.int64.as(LLVM::Type)
    @isize    = llvm.intptr(target_machine.data_layout).as(LLVM::Type)
    @f32      = llvm.float.as(LLVM::Type)
    @f64      = llvm.double.as(LLVM::Type)

    # Verona runtime types.
    @alloc = llvm.struct_create_named("_.RTAlloc").as(LLVM::Type)
    @alloc_ptr = @alloc.pointer.as(LLVM::Type)
    @desc = llvm.struct_create_named("_.RTDescriptor").as(LLVM::Type)
    @desc_ptr = @desc.pointer.as(LLVM::Type)
    @action_desc = llvm.struct_create_named("_.RTActionDescriptor").as(LLVM::Type)
    @action_desc_ptr = @action_desc.pointer.as(LLVM::Type)
    @action = llvm.struct_create_named("_.RTAction").as(LLVM::Type)
    @action_ptr = @action.pointer.as(LLVM::Type)
    @obj_stack = llvm.struct_create_named("_.RTObjectStack").as(LLVM::Type)
    @obj_stack_ptr = @obj_stack.pointer.as(LLVM::Type)
    @obj = llvm.struct_create_named("_.RTObject").as(LLVM::Type)
    @obj_ptr = @obj.pointer.as(LLVM::Type)
    @obj_pad = @i8.array(OBJECT_PAD_SIZE).as(LLVM::Type)
    @cown = llvm.struct_create_named("_.RTCown").as(LLVM::Type)
    @cown_ptr = @cown.pointer.as(LLVM::Type)
    @cown_pad = @i8.array(COWN_PAD_SIZE).as(LLVM::Type)
    @trace_fn = LLVM::Type.function([@obj_ptr, @obj_stack_ptr], @void).as(LLVM::Type)
    @trace_fn_ptr = @trace_fn.pointer.as(LLVM::Type)
    @final_fn = LLVM::Type.function([@obj_ptr], @void).as(LLVM::Type)
    @final_fn_ptr = @final_fn.pointer.as(LLVM::Type)
    @notify_fn = LLVM::Type.function([@obj_ptr], @void).as(LLVM::Type)
    @notify_fn_ptr = @notify_fn.pointer.as(LLVM::Type)
    @action_fn = LLVM::Type.function([@action_ptr], @void).as(LLVM::Type)
    @action_fn_ptr = @action_fn.pointer.as(LLVM::Type)
    @action_trace_fn = LLVM::Type.function([@action_ptr, @obj_stack_ptr], @void).as(LLVM::Type)
    @action_trace_fn_ptr = @action_trace_fn.pointer.as(LLVM::Type)
    @main_inner_fn = LLVM::Type.function([@ptr], @void).as(LLVM::Type)
    @main_inner_fn_ptr = @main_inner_fn.pointer.as(LLVM::Type)
  end

  def gen_runtime_decls(g : CodeGen)
    align_width = 8_u64 # TODO: cross-platform
    [
      {"RTAlloc_get", [] of LLVM::Type, @alloc_ptr, [
        LLVM::Attribute::NoUnwind, LLVM::Attribute::ReadNone,
      ]},
      {"RTAlloc_alloc", [@alloc_ptr, @isize], @ptr, [
        LLVM::Attribute::NoUnwind, LLVM::Attribute::InaccessibleMemOrArgMemOnly,
        {LLVM::AttributeIndex::ReturnIndex, LLVM::Attribute::NoAlias},
        {LLVM::AttributeIndex::ReturnIndex, LLVM::Attribute::Dereferenceable, align_width},
        {LLVM::AttributeIndex::ReturnIndex, LLVM::Attribute::Alignment, align_width},
      ]},
      {"RTObjectStack_push", [@obj_stack_ptr, @obj_ptr], @void, [
        LLVM::Attribute::NoUnwind, LLVM::Attribute::InaccessibleMemOrArgMemOnly,
      ]},
      {"RTObject_new_iso", [@alloc_ptr, @desc_ptr], @obj_ptr, [
        LLVM::Attribute::NoUnwind, LLVM::Attribute::InaccessibleMemOrArgMemOnly,
        {LLVM::AttributeIndex::ReturnIndex, LLVM::Attribute::NoAlias},
        {LLVM::AttributeIndex::ReturnIndex, LLVM::Attribute::Dereferenceable, align_width + OBJECT_PAD_SIZE},
        {LLVM::AttributeIndex::ReturnIndex, LLVM::Attribute::Alignment, align_width},
      ]},
      {"RTObject_new_mut", [@alloc_ptr, @desc_ptr, @obj_ptr], @obj_ptr, [
        LLVM::Attribute::NoUnwind, LLVM::Attribute::InaccessibleMemOrArgMemOnly,
        {LLVM::AttributeIndex::ReturnIndex, LLVM::Attribute::NoAlias},
        {LLVM::AttributeIndex::ReturnIndex, LLVM::Attribute::Dereferenceable, align_width + OBJECT_PAD_SIZE},
        {LLVM::AttributeIndex::ReturnIndex, LLVM::Attribute::Alignment, align_width},
      ]},
      {"RTObject_get_descriptor", [@obj_ptr], @desc_ptr, [
        LLVM::Attribute::NoUnwind, LLVM::Attribute::InaccessibleMemOrArgMemOnly, LLVM::Attribute::ReadOnly,
      ]},
      {"RTObject_region_merge", [@alloc_ptr, @obj_ptr, @obj_ptr], @void, [
        LLVM::Attribute::NoUnwind, LLVM::Attribute::InaccessibleMemOrArgMemOnly,
      ]},
      {"RTObject_region_freeze", [@alloc_ptr, @obj_ptr], @void, [
        LLVM::Attribute::NoUnwind, LLVM::Attribute::InaccessibleMemOrArgMemOnly,
      ]},
      {"RTImmutable_acquire", [@obj_ptr], @void, [
        LLVM::Attribute::NoUnwind, LLVM::Attribute::InaccessibleMemOrArgMemOnly,
      ]},
      {"RTImmutable_release", [@obj_ptr, @alloc_ptr], @void, [
        LLVM::Attribute::NoUnwind, LLVM::Attribute::InaccessibleMemOrArgMemOnly,
      ]},
      {"RTCown_new", [@alloc_ptr, @desc_ptr], @cown_ptr, [
        LLVM::Attribute::NoUnwind, LLVM::Attribute::InaccessibleMemOrArgMemOnly,
        {LLVM::AttributeIndex::ReturnIndex, LLVM::Attribute::NoAlias},
        {LLVM::AttributeIndex::ReturnIndex, LLVM::Attribute::Dereferenceable, align_width + COWN_PAD_SIZE},
        {LLVM::AttributeIndex::ReturnIndex, LLVM::Attribute::Alignment, align_width},
      ]},
      {"RTCown_acquire", [@cown_ptr], @void, [
        LLVM::Attribute::NoUnwind, LLVM::Attribute::InaccessibleMemOrArgMemOnly,
      ]},
      {"RTCown_release", [@cown_ptr, @alloc_ptr], @void, [
        LLVM::Attribute::NoUnwind, LLVM::Attribute::InaccessibleMemOrArgMemOnly,
      ]},
      {"RTAction_new", [@alloc_ptr, @action_desc_ptr], @action_ptr, [
        LLVM::Attribute::NoUnwind, LLVM::Attribute::InaccessibleMemOrArgMemOnly,
        {LLVM::AttributeIndex::ReturnIndex, LLVM::Attribute::NoAlias},
        {LLVM::AttributeIndex::ReturnIndex, LLVM::Attribute::Dereferenceable, align_width},
        {LLVM::AttributeIndex::ReturnIndex, LLVM::Attribute::Alignment, align_width},
      ]},
      {"RTAction_schedule", [@action_ptr, @cown_ptr.pointer, @isize], @void, [
        LLVM::Attribute::NoUnwind, LLVM::Attribute::InaccessibleMemOrArgMemOnly,
      ]},
      {"RTSystematicTestHarness_run", [@i32, @pptr, @main_inner_fn_ptr, @ptr], @void,
        [] of LLVM::Attribute
      },
      {"puts", [@ptr], @i32, [] of LLVM::Attribute},
    ]
  end

  # TODO: Remove these when we can stop calling them from Savi programs.
  def gen_hacky_stubs(g)
    fn = g.mod.functions["pony_os_stdout"]
    g.gen_func_start(fn)
    g.builder.ret g.builder.bit_cast(@ptr.null, fn.return_type)
    g.gen_func_end

    fn = g.mod.functions["pony_os_stderr"]
    g.gen_func_start(fn)
    g.builder.ret g.builder.bit_cast(@ptr.null, fn.return_type)
    g.gen_func_end
  end

  def gen_alloc_ctx_get(g : CodeGen)
    g.builder.call(g.mod.functions["RTAlloc_get"], "ALLOC_CTX")
  end

  @current_root_thread_local : LLVM::Value?
  def gen_current_root_thread_local(g : CodeGen)
    (@current_root_thread_local ||= begin
      desc = g.mod.globals.add(@obj_ptr, "CURRENT.ROOT")
      desc.linkage = LLVM::Linkage::LinkerPrivate
      desc.thread_local = true
      desc

      desc.initializer = @obj_ptr.null

      desc
    end).not_nil!
  end

  def gen_current_root_get(g : CodeGen)
    g.builder.load(gen_current_root_thread_local(g), "CURRENT.ROOT")
  end

  def gen_current_root_set(g : CodeGen, value : LLVM::Value)
    g.builder.store(value, gen_current_root_thread_local(g))
  end

  DESC_ID                    = 0
  DESC_TRACE_FN              = 1
  DESC_TRACE_POSSIBLY_ISO_FN = 2
  DESC_FINAL_FN              = 3
  DESC_NOTIFY_FN             = 4

  # This defines the generic LLVM struct type for what a type descriptor holds.
  # The type descriptor for each type uses a more specific version of this.
  # The order and sizes here must exactly match what is expected by the runtime,
  # and they should correlate to the constants above.
  def gen_desc_basetype
    @desc.struct_set_body [
      @isize,         # 0: size
      @trace_fn_ptr,  # 1: trace fn
      @trace_fn_ptr,  # 2: trace possibly iso fn
      @final_fn_ptr,  # 3: final fn
      @notify_fn_ptr, # 4: notified fn
      # TODO: id, traits bitmap, vtable
    ]

    @action_desc.struct_set_body [
      @isize,               # 0: size
      @action_fn_ptr,       # 1: action fn
      @action_trace_fn_ptr, # 2: action trace fn
    ]
  end

  # This defines a more specific struct type than the above function,
  # tailored to the specific type definition and its virtual table size.
  # The actual type descriptor value for the type is an instance of this.
  def gen_desc_type(g : CodeGen, type_def : Reach::Def, vtable_size : Int32) : LLVM::Type
    g.llvm.struct [
      @isize,         # 0: size
      @trace_fn_ptr,  # 1: trace fn
      @trace_fn_ptr,  # 2: trace possibly iso fn
      @final_fn_ptr,  # 3: final fn
      @notify_fn_ptr, # 4: notified fn
      # TODO: id, traits bitmap, vtable
    ], "#{type_def.llvm_name}.DESC"
  end

  def di_runtime_member_info(debug : DebugInfo)
    # TODO: Expose runtime member info, like PonyRT does.
    {} of Int32 => {String, LLVM::Type, LibLLVMExt::Metadata}
  end

  # This defines a global constant for the type descriptor of a type,
  # which is held as the first value in an object, used for identifying its
  # type at runtime, as well as a host of other functions related to dealing
  # with objects in the runtime, such as allocating them and tracing them.
  def gen_desc(g : CodeGen, gtype : GenType)
    type_def = gtype.type_def

    desc = g.mod.globals.add(gtype.desc_type, "#{type_def.llvm_name}.DESC")
    desc.linkage = LLVM::Linkage::LinkerPrivate
    desc.global_constant = true
    desc
  end

  # This populates the descriptor for the given type with its initialized data.
  def gen_desc_init(g : CodeGen, gtype : GenType, vtable)
    desc = gtype.desc
    type_def = gtype.type_def

    abi_size = g.abi_size_of(gtype.struct_type)

    trace_fn =
      if type_def.is_simple_value?(g.ctx)
        @trace_fn_ptr.null
      else
        g.mod.functions.add("#{type_def.llvm_name}.TRACE".gsub(/\W/, "_"), @trace_fn)
      end

    trace_possibly_iso_fn =
      if type_def.is_actor?(g.ctx) \
      || gtype.fields.any?(&.last.is_possibly_iso?)
        g.mod.functions.add("#{type_def.llvm_name}.TRACEPOSSIBLYISO".gsub(/\W/, "_"), @trace_fn)
      else
        @trace_fn_ptr.null
      end

    desc.initializer = gtype.desc_type.const_struct [
      @isize.const_int(abi_size),     # 0: size
      trace_fn.to_value,              # 1: trace fn
      trace_possibly_iso_fn.to_value, # 2: trace possibly iso fn
      @final_fn_ptr.null,             # 3: final fn TODO: @#{llvm_name}.FINAL
      @notify_fn_ptr.null,            # 4: notified fn TODO: @#{llvm_name}.NOTIFY
      # TODO: id, traits bitmap, vtable
    ]

    desc
  end

  @desc_empty : LLVM::Value?
  def gen_desc_empty(g : CodeGen)
    (@desc_empty ||= begin
      abi_size = g.abi_size_of(@desc_ptr) + g.abi_size_of(@obj_pad)

      desc = g.mod.globals.add(@desc, "EMPTY.DESC")
      desc.linkage = LLVM::Linkage::LinkerPrivate
      desc.global_constant = true
      desc

      desc.initializer = @desc.const_struct [
        @isize.const_int(abi_size), # 0: size
        @trace_fn_ptr.null,         # 1: trace fn
        @trace_fn_ptr.null,         # 2: trace possibly iso fn
        @final_fn_ptr.null,         # 3: final fn
        @notify_fn_ptr.null,        # 4: notified fn
      ]

      desc
    end).not_nil!
  end

  def gen_vtable_gep_get(g, desc, name)
    raise NotImplementedError.new("Verona runtime: gen_vtable_gep_get")
  end

  def gen_traits_gep_get(g, desc, name)
    raise NotImplementedError.new("Verona runtime: gen_vtable_traits_get")
  end

  def gen_type_name_get(g, desc, name)
    raise NotImplementedError.new("Verona runtime: gen_type_name_get")
  end

  def gen_struct_type(g : CodeGen, gtype : GenType)
    elements = [] of LLVM::Type

    # All struct types start with the type descriptor (abbreviated "desc").
    # Even types with no desc have a singleton with a desc.
    # The values without a desc do not use this fields struct at all anyway.
    elements << gtype.desc_type.pointer

    # Different runtime objects have a different sized opaque pad at the start
    # that holds all of the runtime-internal data that we shouldn't touch.
    if gtype.type_def.is_actor?(g.ctx)
      # Actors are cowns, and thus have a cown pad.
      elements << @cown_pad
      # Actors need an iso root region, which is an empty object with region md.
      elements << @obj_ptr
    elsif !gtype.type_def.has_allocation?(g.ctx) || gtype.type_def.is_abstract?(g.ctx)
      # Objects that aren't runtime-allocated need no opaque pad at all,
      # because they don't need to hold any runtime-internal data.
      nil
    else
      elements << @obj_pad
    end

    # The sub-struct containing the fields of the type is the last element.
    elements << gtype.fields_struct_type

    # The struct was previously opaque with no body. We now fill it in here.
    gtype.struct_type.struct_set_body(elements)
  end

  def gen_get_desc(g : CodeGen, value : LLVM::Value)
    # Verona hacks the lower bits of the desc pointer, so we don't want to
    # reach to it directly. Instead we call the runtime function to get it.
    g.builder.call(
      g.mod.functions["RTObject_get_descriptor"],
      [g.builder.bit_cast(value, @obj_ptr)],
    )
  end

  def gen_main(g : CodeGen)
    # Declare the inner main function that this one will eventually invoke.
    gen_main_inner(g)

    # Declare other temporary stubs needed for now.
    gen_hacky_stubs(g)

    # Declare the main function.
    main = g.mod.functions.add("main", [@i32, @pptr, @pptr], @i32)
    main.linkage = LLVM::Linkage::External

    g.gen_func_start(main)

    argc = main.params[0].tap &.name=("argc")
    argv = main.params[1].tap &.name=("argv")
    envp = main.params[2].tap &.name=("envp")

    # Get the current alloc_ctx and hold on to it.
    alloc_ctx = gen_alloc_ctx_get(g)
    g.func_frame.alloc_ctx = alloc_ctx

    env = gen_alloc_object_iso(g, g.gtypes["Env"], "env")
    # TODO: call the Env.new constructor?
    gen_iso_freeze_region(g, env)

    if USE_SYSTEMATIC_TESTING
      g.builder.call(g.mod.functions["RTSystematicTestHarness_run"], [
        argc,
        argv,
        g.mod.functions["main.INNER"].to_value,
        g.builder.bit_cast(env, @ptr),
      ])
    else
      raise NotImplementedError.new("verona runtime init without test harness") # TODO
    end

    g.builder.ret(@i32.const_int(0)) # TODO: programs with a nonzero exit code

    g.gen_func_end
  end

  def gen_main_inner(g : CodeGen)
    fn = g.mod.functions.add("main.INNER", [@ptr], @void)
    g.gen_func_start(fn)

    # We receive the Env object as an opaque void pointer. Cast it to Env here.
    env = g.builder.bit_cast(
      fn.params[0].tap &.name=("env.OPAQUE"),
      g.gtypes["Env"].struct_ptr,
      "env",
    )

    # Acquire the Env object an extra time, since Main.new fails to do this.
    # TODO: Add lifetime analysis and codegen for acquiring stuff into scope.
    gen_val_acquire_into_scope(g, env)

    # Create the Main actor.
    main_actor = gen_alloc_actor(g, g.gtype_main, "main")

    # Call the Main actor's asynchronous constructor function, passing the Env.
    g.builder.call(g.gtype_main["new"].send_llvm_func, [main_actor, env])

    # Release the Env object, now that the program is otherwise done.
    # This is the counterpart to the implicit acquire at its original creation.
    gen_val_release_from_scope(g, env)

    g.builder.ret
    g.gen_func_end
  end

  # When an assignment cast may need to happen, classify the kind of type.
  def cast_kind_of(g : CodeGen, type_ref : Reach::Ref, pos : Source::Pos) : Symbol
    # For now we only have supported this logic for singular types.
    raise NotImplementedError.new(type_ref.show_type) unless type_ref.singular?
    type_def = type_ref.single_def!(g.ctx)

    # We don't handle lifetime of simple value types.
    return :simple_value if type_def.is_simple_value?(g.ctx)
    return :no_allocation if !type_def.has_allocation?(g.ctx)

    case type_ref.cap_only.cap_value
    when Infer::Cap::ISO then :iso
    when Infer::Cap::ISO_ALIASED then :iso_aliased
    when Infer::Cap::REF then :ref
    when Infer::Cap::BOX then :box
    when Infer::Cap::VAL then :val
    when Infer::Cap::NON then :non
    when Infer::Cap::TAG
      Error.at pos, "Only actors are allowed to be tag on Verona" \
        unless type_def.is_actor?(g.ctx)

      :actor
    else
      raise NotImplementedError.new("VeronaRT#cast_kind_of #{type_ref.show_type}")
    end
  end

  # When an assignment cast needs to happen, take the runtime-appropriate
  # action needed to convert from one type kind to a different type kind.
  def gen_cast_value(
    g : CodeGen,
    value : LLVM::Value,
    from_kind : Symbol,
    to_kind : Symbol,
    from_type : Reach::Ref,
    to_type : Reach::Ref,
    from_expr : AST::Node
  ) : LLVM::Value
    case {from_kind, to_kind}
    when {:ref, :box}
      # A mutable reference downgrades to read-only with no action needed.
      value
    when {:iso, :iso_aliased}
      # An iso ephemeral can be captured as an iso with no action needed.
      value
    when {:iso, :ref}, {:iso, :box}
      # When an ephemeral iso is moved to a local mutable cap,
      # it needs to be merged into the current local mutable region.
      gen_iso_merge_into_current_region(g, value)
    when {:iso, :val}
      # TODO: find a way to have both compile-time and runtime String'val
      raise NotImplementedError.new("runtime-alloc'd String'val in Verona") \
        if value.type == g.gtypes["String"].struct_ptr

      # When an ephemeral iso is moved to an immutable cap,
      # it needs to be frozen, rendering its whole region immutable.
      gen_iso_freeze_region(g, value)
    when {:non, _}
      # Constructor call receiver casts hit this case, but we don't
      # have to do anything here to account for it - simply return the value.
      value # TODO: Can this hacky special case be avoided?
    when {:box, :val}, {:box, :ref}
      # In-method box receiver casts hit this case, due to specialization, but
      # there's nothing to do to account for it - simply return the value.
      value # TODO: Can this hacky special case be avoided?
    else
      raise NotImplementedError.new(
        "#{{from_kind, to_kind}}:\n" + from_expr.pos.show)
    end
  end

  # For every expression whose value is generated, hook into the value and
  # maybe take an action based on the given lifetime info.
  def gen_expr_post(g : CodeGen, expr : AST::Node, value : LLVM::Value)
    infos = g.ctx.lifetime[g.func_frame.gfunc.not_nil!.reach_func][expr]?
    return value unless infos

    infos.each do |info|
      case info
      when Lifetime::PassAsArgument
        kind = cast_kind_of(g, g.type_of(expr), expr.pos)
        case kind
        when :simple_value, :no_allocation
          # Do nothing - we don't track lifetime of bare values.
        when :val
          # Don't acquire String'val - right now these are all compile-time
          # constant values instead of being runtime allocated.
          # TODO: find a way to have both compile-time and runtime String'val
          no_acquire = g.gtype_of(expr) == g.gtypes["String"]

          gen_val_acquire_into_scope(g, value) unless no_acquire
        when :actor
          gen_actor_acquire_into_scope(g, value)
        else
          raise NotImplementedError.new("VeronaRT PassAsArgument #{kind}")
        end
      when Lifetime::ReleaseFromScope
        local_defn = g.func_frame.any_defn_for_local(info.local)
        kind = cast_kind_of(g, g.type_of(local_defn), local_defn.pos)
        case kind
        when :simple_value, :no_allocation
          # Do nothing - we don't track lifetime of bare values.
        when :ref
          # We do nothing - ref objects are traced only from their iso root,
          # so we need not pay attention to those references as they come and go.
        when :val
          # Don't release String'val - right now these are all compile-time
          # constant values instead of being runtime allocated.
          # TODO: find a way to have both compile-time and runtime String'val
          no_release = g.gtype_of(local_defn) == g.gtypes["String"]

          gen_val_release_from_scope(g,
            g.builder.load(
              g.func_frame.current_locals[info.local],
              info.local.name,
            )
          ) unless no_release
        when :actor
          gen_actor_release_from_scope(g, value)
        else
          raise NotImplementedError.new("VeronaRT ReleaseFromScope #{kind}")
        end
      else
        raise NotImplementedError.new(info)
      end
    end

    value
  end

  def gen_iso_merge_into_current_region(g : CodeGen, value : LLVM::Value)
    g.builder.call(g.mod.functions["RTObject_region_merge"], [
      g.alloc_ctx,
      gen_current_root_get(g),
      g.builder.bit_cast(value, @obj_ptr, "#{value.name}.OPAQUE"),
    ])
    value
  end

  def gen_iso_freeze_region(g : CodeGen, value : LLVM::Value)
    g.builder.call(g.mod.functions["RTObject_region_freeze"], [
      g.alloc_ctx,
      g.builder.bit_cast(value, @obj_ptr, "#{value.name}.OPAQUE"),
    ])
    value
  end

  def gen_val_acquire_into_scope(g : CodeGen, value : LLVM::Value)
    g.builder.call(g.mod.functions["RTImmutable_acquire"], [
      g.builder.bit_cast(value, @obj_ptr, "#{value.name}.OPAQUE"),
    ])
    value
  end

  def gen_val_release_from_scope(g : CodeGen, value : LLVM::Value)
    g.builder.call(g.mod.functions["RTImmutable_release"], [
      g.builder.bit_cast(value, @obj_ptr, "#{value.name}.OPAQUE"),
      g.alloc_ctx,
    ])
    value
  end

  def gen_actor_acquire_into_scope(g : CodeGen, value : LLVM::Value)
    g.builder.call(g.mod.functions["RTCown_acquire"], [
      g.builder.bit_cast(value, @cown_ptr, "#{value.name}.OPAQUE"),
    ])
    value
  end

  def gen_actor_release_from_scope(g : CodeGen, value : LLVM::Value)
    g.builder.call(g.mod.functions["RTCown_release"], [
      g.builder.bit_cast(value, @cown_ptr, "#{value.name}.OPAQUE"),
      g.alloc_ctx,
    ])
    value
  end

  # This generates the code that allocates an object of the given type.
  # This is the first step before actually calling the constructor of it.
  def gen_alloc(g : CodeGen, gtype : GenType, from_expr : AST::Node, name : String)
    if gtype.type_def.is_actor?(g.ctx)
      gen_alloc_actor(g, gtype, name)
    elsif g.type_of(from_expr).is_singular_iso?
      gen_alloc_object_iso(g, gtype, name)
    else
      gen_alloc_object(g, gtype, name)
    end
  end

  def gen_alloc_struct(g : CodeGen, llvm_type : LLVM::Type, name)
    raise NotImplementedError.new("gen_alloc for non-objects in Verona")
  end

  def gen_alloc_object(g : CodeGen, gtype : GenType, name)
    allocated = g.builder.call(g.mod.functions["RTObject_new_mut"], [
      g.alloc_ctx,
      g.gen_get_desc_opaque(gtype),
      gen_current_root_get(g),
    ], "#{name}.OPAQUE")
    g.builder.bit_cast(allocated, gtype.struct_ptr, name)
  end

  def gen_alloc_object_iso(g : CodeGen, gtype : GenType, name)
    allocated = g.builder.call(g.mod.functions["RTObject_new_iso"], [
      g.alloc_ctx,
      g.gen_get_desc_opaque(gtype),
    ], "#{name}.OPAQUE")
    g.builder.bit_cast(allocated, gtype.struct_ptr, name)
  end

  def gen_alloc_actor(g : CodeGen, gtype : GenType, name)
    allocated = g.builder.call(g.mod.functions["RTCown_new"], [
      g.alloc_ctx,
      g.gen_get_desc_opaque(gtype),
    ], "#{name}.OPAQUE")
    actor = g.builder.bit_cast(allocated, gtype.struct_ptr, "#{name}.OPAQUE")

    # Every actor object needs an iso root allocated for region bookkeeping.
    iso_root = g.builder.call(g.mod.functions["RTObject_new_iso"], [
      g.alloc_ctx,
      gen_desc_empty(g),
    ], "#{name}.ROOT")
    g.builder.store(
      iso_root,
      g.builder.struct_gep(actor, 2, "#{name}.ROOT.GEP")
    )

    actor
  end

  def gen_alloc_action(g : CodeGen, action_desc, action_type, name)
    allocated = g.builder.call(g.mod.functions["RTAction_new"], [
      g.alloc_ctx,
      action_desc,
    ], "#{name}.OPAQUE")
    g.builder.bit_cast(allocated, action_type.pointer, name)
  end

  def gen_action_type(g : CodeGen, gtype : GenType, gfunc : GenFunc, params_types)
    element_types = [@action_desc_ptr]
    element_types.concat(params_types)
    g.llvm.struct element_types
  end

  def gen_action_desc(g : CodeGen, gtype : GenType, gfunc : GenFunc, action_type)
    abi_size = g.abi_size_of(action_type)
    action_fn = gen_action_func(g, gtype, gfunc, action_type)

    desc = g.mod.globals.add(@action_desc, "#{gfunc.llvm_name}.ACTIONDESC")
    desc.linkage = LLVM::Linkage::LinkerPrivate
    desc.global_constant = true

    desc.initializer = @action_desc.const_struct [
      @isize.const_int(abi_size), # 0: size
      action_fn.to_value,         # 1: action fn
      @action_trace_fn_ptr.null,  # 2: TODO: action trace fn
    ]

    desc
  end

  def gen_action_func(g : CodeGen, gtype : GenType, gfunc : GenFunc, action_type)
    fn = g.mod.functions.add("#{gfunc.llvm_name}.ACTION", @action_fn)
    g.gen_func_start(fn)

    # Destructure args from the message.
    args = [] of LLVM::Value
    action = g.builder.bit_cast(fn.params[0], action_type.pointer, "ACTION")
    gfunc.llvm_func.params.types.each_with_index do |param_type, i|
      arg_gep = g.builder.struct_gep(action, i + 1, "ACTION.#{i + 1}.GEP")
      args << g.builder.load(arg_gep, "ACTION.#{i + 1}")
    end

    # Set the current root to be the root object stored in this actor.
    gen_current_root_set(g,
      g.builder.load(
        g.builder.struct_gep(args[0], 2, "@.ROOT.GEP"),
        "@.ROOT",
      )
    )

    # Finally, call the function itself, with the program logic inside it.
    g.builder.call(gfunc.llvm_func, args)

    g.builder.ret
    g.gen_func_end
    fn
  end

  def gen_intrinsic_cpointer_alloc(g : CodeGen, params, llvm_type, elem_size_value)
    g.builder.bit_cast(
      g.builder.call(g.mod.functions["RTAlloc_alloc"], [
        g.alloc_ctx,
        g.builder.mul(params[0], @isize.const_int(elem_size_value)),
      ]),
      llvm_type,
    )
  end

  def gen_intrinsic_cpointer_realloc(g : CodeGen, params, llvm_type, elem_size_value)
    # Unfortunately, snmalloc currently doesn't have a clear choice for realloc.
    # We should just implement our own wrapper for its alloc/free/etc.
    raise NotImplementedError.new("gen_intrinsic_cpointer_realloc for Verona")
  end

  def gen_send_impl(g : CodeGen, gtype : GenType, gfunc : GenFunc)
    action_type = gen_action_type(g, gtype, gfunc, gfunc.llvm_func.params.types)
    action_desc = gen_action_desc(g, gtype, gfunc, action_type)

    fn = gfunc.send_llvm_func
    g.gen_func_start(fn)

    # Create the action object to be scheduled.
    action = gen_alloc_action(g, action_desc, action_type, "ACTION")

    # Fill the action with the arguments we were passed.
    fn.params.to_a.each_with_index do |param, i|
      arg_gep = g.builder.struct_gep(action, i + 1, "ACTION.#{i + 1}.GEP")
      g.builder.store(param, arg_gep)
    end

    # Create the list of cowns to be acquired for the action.
    # Since this is always a list of one, it can be modeled as an alloca
    # whose "address" we take to be the argument for the cown list.
    cown = g.builder.bit_cast(fn.params[0], @cown_ptr)
    cown_alloca = g.builder.alloca(@cown_ptr, "COWN.ALLOCA")
    g.builder.store(cown, cown_alloca)

    # Schedule the action to executed when the cown is available.
    g.builder.call(g.mod.functions["RTAction_schedule"], [
      g.builder.bit_cast(action, @action_ptr),
      cown_alloca,
      @isize.const_int(1),
    ])

    # Call release for this Cown.
    # TODO: Handle this with appropriate lifetime tracking instead.
    gen_actor_release_from_scope(g, cown)

    g.builder.ret(g.gen_none)
    g.gen_func_end
  end

  def gen_desc_fn_impls(g : CodeGen, gtype : GenType)
    gen_trace_impl(g, gtype)
    gen_trace_possibly_iso_impl(g, gtype)
  end

  def gen_trace_impl(g : CodeGen, gtype : GenType)
    # Get the reference to the trace function declared earlier.
    # We'll fill in the implementation of that function now.
    fn = g.mod.functions["#{gtype.type_def.llvm_name}.TRACE".gsub(/\W/, "_")]?
    return unless fn

    fn.unnamed_addr = true
    fn.call_convention = LLVM::CallConvention::C
    fn.linkage = LLVM::Linkage::External

    g.gen_func_start(fn)

    receiver = g.builder.bit_cast(fn.params[0], gtype.struct_ptr, "@")
    obj_stack = fn.params[1]

    # For actors, it is necessary to trace the iso root.
    if gtype.type_def.is_actor?(g.ctx)
      g.builder.call(g.mod.functions["RTObjectStack_push"], [
        obj_stack,
        g.builder.load(
          g.builder.struct_gep(receiver, 2, "@.ROOT.GEP"),
          "@.ROOT",
        )
      ])
    end

    gtype.fields.each do |name, field_ref|
      # TODO: Trace the fields that need tracing.
    end

    g.builder.ret
    g.gen_func_end
  end

  def gen_trace_possibly_iso_impl(g : CodeGen, gtype : GenType)
    # Get the reference to the trace function declared earlier.
    # We'll fill in the implementation of that function now.
    fn = g.mod.functions["#{gtype.type_def.llvm_name}.TRACEPOSSIBLYISO".gsub(/\W/, "_")]?
    return unless fn

    fn.unnamed_addr = true
    fn.call_convention = LLVM::CallConvention::C
    fn.linkage = LLVM::Linkage::External

    g.gen_func_start(fn)

    receiver = g.builder.bit_cast(fn.params[0], gtype.struct_ptr, "@")
    obj_stack = fn.params[1]

    # For actors, it is necessary to trace the iso root.
    if gtype.type_def.is_actor?(g.ctx)
      g.builder.call(g.mod.functions["RTObjectStack_push"], [
        obj_stack,
        g.builder.load(
          g.builder.struct_gep(receiver, 2, "@.ROOT.GEP"),
          "@.ROOT",
        )
      ])
    end

    gtype.fields.each do |name, field_ref|
      next unless field_ref.is_possibly_iso?

      # TODO: Trace here and also in gen_trace_impl.
      raise NotImplementedError.new("trace possibly iso field in Verona")
    end

    g.builder.ret
    g.gen_func_end
  end
end
