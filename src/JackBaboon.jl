# SPDX-License-Identifier: MIT

module JackBaboon

import Base: Semaphore, release, acquire
import UUIDs: uuid4, UUID

export
    Executor,
    #Base.close,
    #Base.isopen,
    iscrashed,
    isclosed,
    execute!,
    submit!,

    #Handle
    cancel!,
    iscreated,
    isqueued,
    ispending,
    isrunning,
    isfailed,
    iscompleted,
    iscancelling,
    iscanceled,
    isfinal,

    ExecutorInternalError,
    ExecutorClosedError,
    ExecutorTerminatedError,
    ExecutorRejectedError,
    JobCancelledError


include("cancel_tokens.jl")
include("transitions.jl")
include("handles.jl")
include("executors.jl")


end  # of module JackBaboon
