# SPDX-License-Identifier: MIT

module StateMachines

export
    StateMachine,
    check_reached,
    can_reach,
    can_precede,
    get_reachabilities,
    can_transit,
    check_transit,
    is_terminal

struct TransitionError{S} <: Exception
    from :: S
    to   :: S
end

function Base.showerror(io::IO, e::TransitionError{S}) where {S}
    print(io, "TransitionError{$S}: can not transit from ", e.from, " to ", e.to)
end

struct UnreachedError{S} <: Exception
    from :: S
    to   :: S
end

function Base.showerror(io::IO, e::UnreachedError{S}) where {S}
    print(io, "UnreachedError{$S}: can not reach ", e.to, " from ", e.from)
end

struct StateMachine{S}
    transitions    :: Dict{S, Set{S}}
    reachabilities :: Dict{S, Set{S}}
end

function StateMachine(transitions_map::Pair{S, <:AbstractVector}...) where {S}
    transitions = Dict{S, Set{S}}(from => Set(tos) for (from, tos) in transitions_map)
    for transits in values(transitions)
        for transit in transits
            haskey(transitions, transit) || throw(ArgumentError(
                "transitions from $transit is not defined"
            ))
        end
    end
    reachabilities = get_reachabilities(transitions)
    return StateMachine{S}(transitions, reachabilities)
end

function check_reached(sm::StateMachine{S}, from::S, to::S) where {S}
    can_reach(sm, from, to) && return nothing
    throw(UnreachedError{S}(from, to))
end

function can_reach(sm::StateMachine{S}, from::S, to::S) where {S}
    return to in sm.reachabilities[from]
end

can_precede(sm::StateMachine{S}, from::S, to::S)  where {S} = can_reach(sm, to, from)

function get_reachabilities(transitions::Dict{S, Set{S}}) where {S}
    states = collect(keys(transitions))
    reachabilities = Dict{S, Set{S}}()
    for start in states
        reachables = Set{S}()
        transits = collect(transitions[start])
        while ! isempty(transits)
            state = pop!(transits)
            state in reachables && continue
            push!(reachables, state)
            append!(transits, transitions[state])
        end
        reachabilities[start] = reachables
    end
    return reachabilities
end

function can_transit(sm::StateMachine{S}, from::S, to::S) where {S}
    return to in sm.transitions[from]
end

function check_transit(sm::StateMachine{S}, from::S, to::S) where {S}
    can_transit(sm, from, to) && return nothing
    throw(TransitionError{S}(from, to))
end

function is_terminal(sm::StateMachine{S}, state::S) where {S}
    return isempty(sm.transitions[state])
end

end # module StateMachines
