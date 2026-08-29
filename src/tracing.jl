# SPDX-License-Identifier: MIT

mutable struct Atomic{T}
    @atomic x::T
end

const JOB_TRACE_GLOBAL_SEQUENCE = Atomic{UInt64}(UInt64(0))

next_job_trace_global_sequence() = @atomic JOB_TRACE_GLOBAL_SEQUENCE.x += 1

const DEFAULT_JOB_TRACE_ENABLED = Atomic{Bool}(false)

enable_job_global_tracing() = @atomic DEFAULT_JOB_TRACE_ENABLED.x = true

disable_job_global_tracing() = @atomic DEFAULT_JOB_TRACE_ENABLED.x = false

is_job_global_tracing_on() = @atomic DEFAULT_JOB_TRACE_ENABLED.x
