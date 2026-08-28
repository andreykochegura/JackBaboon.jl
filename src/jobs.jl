# SPDX-License-Identifier: MIT

struct Job
    f
    handle :: Handle
end

Job(@nospecialize(f);) = Job(f, Handle())
