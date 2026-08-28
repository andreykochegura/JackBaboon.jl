# SPDX-License-Identifier: MIT

mutable struct JobTraceSequence
    @atomic x :: UInt64
end

const JOB_TRACE_GLOBAL_SEQUENCE = JobTraceSequence(0)

next_job_trace_global_sequence() = @atomic JOB_TRACE_GLOBAL_SEQUENCE.x += 1

const DEFAULT_JOB_TRACE_ENABLED = Ref{Bool}(false)

enable_job_global_tracing() = DEFAULT_JOB_TRACE_ENABLED[] = true

disable_job_global_tracing() = DEFAULT_JOB_TRACE_ENABLED[] = false
