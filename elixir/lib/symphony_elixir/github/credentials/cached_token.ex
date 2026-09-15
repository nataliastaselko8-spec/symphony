defmodule SymphonyElixir.GitHub.Credentials.Cache.Token do
  @moduledoc false
  @derive {Inspect, only: [:expires_at]}
  @enforce_keys [:token, :expires_at]
  defstruct [:token, :expires_at]
end
