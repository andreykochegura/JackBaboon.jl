# SPDX-License-Identifier: MIT

struct TransitionError{S} <: Exception
    from :: S
    to   :: S
end

function Base.showerror(io::IO, e::TransitionError) 
    print(io, "TransitionError: can not transit from ", e.from, " to ", e.to)
end

can_transit(transitions, from::S, to::S) where {S} =
    to in transitions[from]

check_transit(transitions, from::S, to::S) where {S} = 
    can_transit(transitions, from, to) ? nothing : throw(TransitionError{S}(from, to))
