class Mare::Compiler::Flagger < Mare::AST::Visitor
  alias RID = UInt64
  
  # This visitor marks the given node and all nodes within as value_not_needed.
  class ValueNotNeededVisitor < Mare::AST::Visitor
    def visit(node)
      node.value_not_needed!
      node
    end
  end
  
  def self.run(ctx)
    ctx.program.types.each do |t|
      t.functions.each do |f|
        new.run(f)
      end
    end
  end
  
  def run(func)
    func.params.try { |params| params.accept(self) }
    func.body.try { |body| body.accept(self) }
  end
  
  # This visitor never replaces nodes, it just touches them and returns them.
  def visit(node)
    touch(node)
    node
  end
  
  # An Operator can never have a value, so its value should never be needed.
  def touch(op : AST::Operator)
    op.value_not_needed!
  end
  
  def touch(group : AST::Group)
    case group.style
    when "(", ":"
      # In a sequence-style group, only the value of the final term is needed.
      group.terms.each(&.value_not_needed!)
      group.terms.last.value_needed! unless group.terms.empty?
    when " "
      if group.terms.size == 2
        # Treat this as an explicit type qualification, such as in the case
        # of a local assignment with an explicit type. The value isn't used.
        group.terms[1].accept(ValueNotNeededVisitor.new)
      else
        raise NotImplementedError.new(group.to_a.inspect)
      end
    end
  end
  
  # However, in a Qualify, a value is needed in all terms of its Group.
  def touch(qualify : AST::Qualify)
    qualify.group.terms.each(&.value_needed!)
  end
  
  def touch(relate : AST::Relate)
    case relate.op.value
    when "."
      # In a member access Relate, a value is not needed for the right side.
      # A value is only needed for the left side and the overall access node.
      rhs = relate.rhs
      rhs.value_not_needed!
      rhs.term.value_not_needed! if rhs.is_a?(AST::Qualify)
    end
  end
  
  def touch(node : AST::Node)
    # On all other nodes, do nothing.
  end
end
