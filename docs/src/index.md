# JackBaboon

Julia executor with limited concurrency.

## API

```@docs
    Executor
    execute!
    submit!
    Base.isopen(::Executor)
    Base.close(::Executor)
    isclosed
    iscrashed
    iscancelrequested
    isqueued
    ispending
    iscanceled
    isrunning
    iscompleted
    stop!
    isstopping
    isstopped
    isfailed
    isfinal
    Base.wait(::JackBaboon.Handle)
    Base.fetch(::JackBaboon.Handle)
    ExecutorClosedError
    ExecutorRejectedError
    JobCancelledError
    ExecutorInternalError
```
