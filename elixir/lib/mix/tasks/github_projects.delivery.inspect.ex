defmodule Mix.Tasks.GithubProjects.Delivery.Inspect do
  use Mix.Task

  alias SymphonyElixir.GitHubProjects.Delivery.Inspection

  @moduledoc "Read-only delivery report. Exit 0: observed; 1: incomplete/error; 2: confirmed blocker."

  @shortdoc "Inspect GitHub delivery without starting Symphony or its workers"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("compile")
    {status, output} = Inspection.cli(args)
    Mix.shell().info(output)
    if status != 0, do: exit({:shutdown, status})
  end
end
