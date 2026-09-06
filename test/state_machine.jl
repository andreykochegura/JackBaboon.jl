# SPDX-License-Identifier: MIT

include("common.jl")

@testset "State machine" begin
    S = JackBaboon.StateMachines
    @test_throws ArgumentError S.StateMachine(1 => [2])
    sm = S.StateMachine(1 => [2], 2 => [3], 3 => [])
    @test S.can_reach(sm, 1, 2)
    @test S.can_reach(sm, 1, 3)
    @test S.can_reach(sm, 2, 3)
    @test ! S.can_reach(sm, 1, 1)
    @test ! S.can_reach(sm, 2, 1)
    @test ! S.can_reach(sm, 3, 1)
    @test ! S.can_reach(sm, 3, 2)
    @test S.can_transit(sm, 1, 2)
    @test S.can_transit(sm, 2, 3)
    @test ! S.can_transit(sm, 1, 1)
    @test ! S.can_transit(sm, 1, 3)
    @test ! S.can_transit(sm, 3, 2)
    @test ! S.can_transit(sm, 3, 1)
    @test S.is_terminal(sm, 3)
    @test_throws S.TransitionError S.check_transit(sm, 1, 3)
    @test_throws "TransitionError" S.check_transit(sm, 1, 3)
    @test_throws S.UnreachedError S.check_reached(sm, 2, 1)
    @test_throws "UnreachedError" S.check_reached(sm, 2, 1)
end
