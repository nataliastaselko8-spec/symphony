defmodule SymphonyElixir.GitHubProjects.Delivery.JSON do
  @moduledoc "Bounded JSON decoding that rejects duplicate object keys."

  @spec decode(term(), pos_integer()) :: {:ok, term()} | {:error, :invalid_delivery_json}
  def decode(raw, limit \\ 2_097_152) do
    with true <- is_binary(raw) and byte_size(raw) <= limit,
         {:ok, value} <- Jason.decode(raw, objects: :ordered_objects) do
      {:ok, unpack(value)}
    else
      _ -> {:error, :invalid_delivery_json}
    end
  catch
    :duplicate_key -> {:error, :invalid_delivery_json}
  end

  defp unpack(%Jason.OrderedObject{values: pairs}) do
    if length(Enum.uniq_by(pairs, &elem(&1, 0))) != length(pairs), do: throw(:duplicate_key)
    Map.new(pairs, fn {key, value} -> {key, unpack(value)} end)
  end

  defp unpack(values) when is_list(values), do: Enum.map(values, &unpack/1)
  defp unpack(value), do: value
end
