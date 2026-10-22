# Elixir host: driving Temper.Dave.RepairAgent from plain Elixir

A `mix new`-shaped project with path deps on the three mix projects
`bin/temper-elixir build -b elixir` writes under `temper.out/elixir/`.
Its one test file drives the repair loop from the host side, the way Jam
Pilot (notedance_viewer) will, and reads every result back through the
generated getters into plain maps.

    /Users/bg/code/dave/bin/temper-elixir build -b elixir
    cd probes/elixir-host && mix deps.get && mix test

`scripts/matrix.sh` deletes and rebuilds `temper.out/elixir`; rebuild
before running this if the matrix ran since.

What it proves is in `test/host_test.exs` (the repair loop) and
`test/compose_host_test.exs` (the composer's loop, including a cut-off
assembled from a stream); the recipe distilled from it is in the decision
graph under the repair-agent goal.
