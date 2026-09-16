defmodule SymphonyElixir.GitHubProjects.Delivery.Settings do
  @moduledoc "Pinned controller policy for finite, read-only delivery observations."

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.DeliveryGate.Settings, as: GateSettings
  alias SymphonyElixir.GitHub.Credentials
  alias SymphonyElixir.GitHubProjects.Settings, as: ProjectSettings

  @defaults %{
    "deployment_workflow" => ".github/workflows/deploy-development.yml",
    "pr_workflow" => ".github/workflows/pr-ci.yml",
    "verify_workflow" => ".github/workflows/verify.yml",
    "contract_path" => ".github/scripts/deployment-evidence-contract.json",
    "producer_path" => ".github/scripts/deployment-evidence.py",
    "ci_gate_path" => ".github/scripts/ci-gate.py",
    "environment" => "development"
  }
  @required ~w(contract_commit contract_sha256)

  @spec parse(Schema.t()) :: {:ok, map()} | {:error, atom()}
  def parse(%Schema{delivery: %{observer: supplied}} = config) when is_map(supplied) do
    policy = Map.merge(@defaults, supplied)

    with true <- config.tracker.kind == "github_projects",
         true <- Enum.all?(Map.keys(supplied), &(&1 in (Map.keys(@defaults) ++ @required))),
         true <- sha?(policy["contract_commit"]) and digest?(policy["contract_sha256"]),
         true <- Enum.all?(Map.drop(policy, @required ++ ["environment"]), fn {_, path} -> path?(path) end),
         true <- is_binary(policy["environment"]) and policy["environment"] != "",
         true <- config.delivery.base_branch == "dev",
         {:ok, project} <- ProjectSettings.parse(config.tracker),
         {:ok, reference} <- Credentials.reference(config.tracker.provider, :delivery_read),
         {:ok, gate} <- GateSettings.from_config(config) do
      {:ok, %{policy: policy, reference: reference, repo: reference.repo, project: project, tracker: config.tracker, gate: gate}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_delivery_observer_settings}
    end
  end

  def parse(_), do: {:error, :invalid_delivery_observer_settings}

  @spec sha?(term()) :: boolean()
  def sha?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{40}\z/, value)

  @spec digest?(term()) :: boolean()
  def digest?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  @spec id?(term()) :: boolean()
  def id?(value), do: is_integer(value) and value > 0 and value <= 9_007_199_254_740_991

  @spec paths(map()) :: [String.t()]
  def paths(policy), do: policy |> Map.drop(@required ++ ["environment"]) |> Map.values() |> Enum.uniq() |> Enum.sort()

  defp path?(value) do
    is_binary(value) and Regex.match?(~r/\A\.github\/(workflows|scripts)\/[A-Za-z0-9_-]+\.(yml|yaml|json|py)\z/, value)
  end
end
