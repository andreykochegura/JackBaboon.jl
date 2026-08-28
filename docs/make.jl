# SPDX-License-Identifier: MIT

# julia --project=docs docs/make.jl 

using Documenter
using JackBaboon

makedocs(
    sitename = "JackBaboon",
    modules = [JackBaboon],
    format = Documenter.HTML(),
)

deploydocs(
    repo = "github.com/andreykochegura/JackBaboon.jl.git",
)
