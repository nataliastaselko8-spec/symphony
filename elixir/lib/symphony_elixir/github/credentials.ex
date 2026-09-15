defmodule SymphonyElixir.GitHub.Credentials do
  @moduledoc """
  Controller-owned GitHub App credentials with immutable scope and no token fallback.
  """

  alias SymphonyElixir.GitHub.Credentials.{Cache, Reference}

  @spec reference(map(), atom()) :: {:ok, Reference.t()} | {:error, atom()}
  def reference(provider, profile), do: Reference.new(provider, profile)

  @spec token(Reference.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def token(%Reference{} = reference, opts \\ []) do
    call(Keyword.get(opts, :credentials_cache, Cache), {:token, reference})
  end

  @spec invalidate(Reference.t(), String.t(), keyword()) :: :ok | {:error, atom()}
  def invalidate(%Reference{} = reference, token, opts \\ []) when is_binary(token) do
    call(Keyword.get(opts, :credentials_cache, Cache), {:invalidate, reference, token})
  end

  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(provider), do: Reference.secret_environment_names(provider)

  defp call(cache, message) do
    GenServer.call(cache, message, 60_000)
  catch
    :exit, _reason -> {:error, :github_credentials_unavailable}
  end
end
