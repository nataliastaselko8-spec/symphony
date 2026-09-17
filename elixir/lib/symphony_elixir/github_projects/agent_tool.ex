defmodule SymphonyElixir.GitHubProjects.AgentTool do
  @moduledoc "Tools bound to one live controller session; model arguments never select authority."
  alias SymphonyElixir.DeliveryRuntime
  @names ~w(project_context project_start project_report project_block project_prepare_pr project_handoff)

  @spec specs() :: [map()]
  def specs do
    Enum.map(@names, fn name ->
      fields =
        case name do
          n when n in ~w(project_report project_block) -> ~w(body)
          "project_prepare_pr" -> ~w(sha title body)
          "project_handoff" -> ~w(operation_id)
          _ -> []
        end

      %{
        "name" => name,
        "description" => description(name),
        "inputSchema" => %{"type" => "object", "properties" => Map.new(fields, &{&1, %{"type" => "string"}}), "required" => fields, "additionalProperties" => false}
      }
    end)
  end

  @spec execute(String.t(), term(), keyword()) :: map()
  def execute(name, arguments, opts) do
    handle = Keyword.get(opts, :delivery)
    result = if name in @names and is_map(arguments) and match?(%{runtime: _, gate: _, nonce: _}, handle), do: DeliveryRuntime.tool(handle, name, arguments), else: {:error, :task_tool_not_authorized}

    case result do
      {:ok, value} -> %{"success" => true, "output" => Jason.encode!(value)}
      {:error, reason} -> %{"success" => false, "output" => inspect(reason)}
    end
  end

  defp description("project_context"), do: "Read this task's retained cycle, branch, PR and budget."
  defp description("project_start"), do: "Request Agent working for this admitted task. Does not start another worker."
  defp description("project_report"), do: "Update this issue's single persistent progress report."
  defp description("project_block"), do: "Retain work and request human help. Ends this worker."
  defp description("project_prepare_pr"), do: "Prepare an immutable commit for controller publication. Returns an operation ID; does not publish yet."
  defp description("project_handoff"), do: "Submit the prepared operation and end work. The controller publishes and waits for CI; this is not PR-ready confirmation."
end
