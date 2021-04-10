require "bit_array"

# Seriously, what's the fun of having a BitArray type in Crystal's stdlib
# if you can't even do bitwise operations on them?! We'll have our fun here.
struct BitArray
  # Return a new BitArray whose bits are the union of those in self and other.
  # Raises an ArgumentError if the two BitArrays are not the same size.
  def |(other : BitArray) : BitArray
    result = BitArray.new(@size)
    @bits.copy_to(result.@bits, malloc_size)
    result.apply_bitwise_or_from(other)
    result
  end
  protected def apply_bitwise_or_from(other : BitArray)
    raise ArgumentError.new \
      "other BitArray has size #{other.size} but our size is #{size}" \
        unless other.size == size

    malloc_size.times do |i|
      @bits[i] |= other.@bits[i]
    end

    self
  end

  # Return a new BitArray whose bits are the union of those in self and other.
  # Raises an ArgumentError if the two BitArrays are not the same size.
  def &(other : BitArray) : BitArray
    result = BitArray.new(@size)
    @bits.copy_to(result.@bits, malloc_size)
    result.apply_bitwise_and_from(other)
    result
  end
  protected def apply_bitwise_and_from(other : BitArray)
    raise ArgumentError.new \
      "other BitArray has size #{other.size} but our size is #{size}" \
        unless other.size == size

    malloc_size.times do |i|
      @bits[i] &= other.@bits[i]
    end

    self
  end
end
