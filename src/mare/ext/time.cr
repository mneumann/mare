require "time"

struct Time
  def self.show(name : String, indent : Int32 = 0, &block : Nil -> U) : U forall U
    result: U? = nil
    time = Time.measure { result = block.call(nil) }
    puts "#{" " * indent}#{time} - #{name}"
    result.as(U)
  end
end
