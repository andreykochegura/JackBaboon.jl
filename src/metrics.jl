# SPDX-License-Identifier: MIT

mutable struct Metrics
    @atomic rejected  :: Int
    @atomic queued    :: Int
    @atomic started   :: Int
    @atomic completed :: Int
    @atomic stopped   :: Int
    @atomic cancelled :: Int
    @atomic failed    :: Int
    @atomic backlog   :: Int
    @atomic active    :: Int
end

Metrics() = Metrics(0, 0, 0, 0, 0, 0, 0, 0, 0)

snapshot(m::Metrics; kw...)::NamedTuple =
    merge(NamedTuple{fieldnames(Metrics)}(
        Base.getproperty(m, field, :sequentially_consistent)
            for field in fieldnames(Metrics)), kw)
