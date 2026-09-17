defmodule SymphonyElixir.Operator.Credential do
  @moduledoc "Local high-entropy login credential, kept in a private controller-owned Linux directory."
  import Bitwise

  @spec read(String.t()) :: {:ok, binary()} | {:error, atom()}
  def read(path) do
    with :ok <- parent(path),
         {:ok, stat} <- File.lstat(path),
         true <- stat.type == :regular and stat.links == 1 and band(stat.mode, 0o077) == 0 and stat.uid == uid(),
         true <- stat.size in 43..128,
         {:ok, value} <- File.read(path),
         value = String.trim(value),
         {:ok, bytes} <- Base.url_decode64(value, padding: false),
         true <- byte_size(bytes) >= 32 do
      {:ok, :crypto.hash(:sha256, value)}
    else
      _ -> {:error, :invalid_operator_credential}
    end
  end

  @spec create(String.t()) :: :ok | {:error, atom()}
  def create(path) do
    with :ok <- parent(path),
         {:ok, file} <- File.open(path, [:write, :exclusive, :binary]) do
      try do
        with :ok <- File.chmod(path, 0o600), :ok <- IO.binwrite(file, Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false) <> "\n"), do: :file.sync(file)
      after
        File.close(file)
      end
    else
      _ -> {:error, :credential_creation_failed}
    end
  end

  defp parent(path) do
    with true <- :os.type() == {:unix, :linux} and is_binary(path) and String.starts_with?(path, "/") and Path.expand(path) == path,
         true <- not String.starts_with?(path, "/mnt/") and not String.contains?(path, ["\\", <<0>>]),
         {:ok, stat} <- File.lstat(Path.dirname(path)),
         true <- stat.type == :directory and band(stat.mode, 0o077) == 0 and stat.uid == uid(),
         true <- plain_parents?(Path.dirname(path)) do
      :ok
    else
      _ -> {:error, :private_operator_directory_required}
    end
  end

  defp plain_parents?("/"), do: true

  defp plain_parents?(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} -> not File.exists?(Path.join(path, ".git")) and plain_parents?(Path.dirname(path))
      _ -> false
    end
  end

  defp uid do
    {value, 0} = System.cmd("id", ["-u"])
    value |> String.trim() |> String.to_integer()
  end
end
