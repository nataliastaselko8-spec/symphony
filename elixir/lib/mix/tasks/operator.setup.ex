defmodule Mix.Tasks.Operator.Setup do
  alias SymphonyElixir.Operator.Credential
  @shortdoc "Create a local operator credential in an existing private Linux directory"
  @moduledoc "Run with --path /absolute/private/operator-token. Never overwrites or prints the credential."
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    case args do
      ["--path", path] ->
        case Credential.create(path) do
          :ok -> Mix.shell().info("Operator credential created. Read it locally to sign in; do not add it to git.")
          {:error, reason} -> Mix.raise("Operator setup failed: #{reason}. Use an existing controller-owned 0700 directory.")
        end

      _ ->
        Mix.raise("Usage: mix operator.setup --path /absolute/private/operator-token")
    end
  end
end
