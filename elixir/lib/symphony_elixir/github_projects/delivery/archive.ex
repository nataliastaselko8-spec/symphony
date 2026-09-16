defmodule SymphonyElixir.GitHubProjects.Delivery.Archive do
  @moduledoc "One-file ZIP reader with bounded inflation; never extracts to the filesystem."

  import Bitwise
  @name "development-evidence.json"
  @limit 2_097_152

  @spec read(binary(), String.t()) :: {:ok, binary()} | {:error, :invalid_evidence_archive}
  def read(archive, digest) do
    with true <- is_binary(archive) and byte_size(archive) in 22..5_242_880,
         true <- digest == "sha256:" <> Base.encode16(:crypto.hash(:sha256, archive), case: :lower),
         {:ok, entry} <- directory(archive),
         {:ok, compressed} <- local_file(archive, entry),
         {:ok, bytes} <- expand(entry.method, compressed),
         true <- byte_size(bytes) == entry.size and :erlang.crc32(bytes) == entry.crc do
      {:ok, bytes}
    else
      _ -> {:error, :invalid_evidence_archive}
    end
  rescue
    _ -> {:error, :invalid_evidence_archive}
  end

  defp directory(archive) do
    tail = binary_part(archive, byte_size(archive) - 22, 22)

    with <<0x06054B50::little-32, 0::little-32, 1::little-16, 1::little-16, sizes::binary-size(8), 0::16>> <- tail,
         <<length::little-32, offset::little-32>> = sizes,
         true <- offset + length == byte_size(archive) - 22,
         central = binary_part(archive, offset, length),
         <<
           0x02014B50::little-32,
           _versions::32,
           # Fixed central-directory header, followed by length-delimited fields.
           modes::binary-size(8),
           sizes::binary-size(12),
           lengths::binary-size(6),
           0::16,
           _internal::16,
           attributes::little-32,
           0::32,
           fields::binary
         >> <- central,
         <<flags::little-16, method::little-16, _time::32>> = modes,
         <<crc::little-32, compressed::little-32, size::little-32>> = sizes,
         <<name_length::little-16, extra_length::little-16, comment_length::little-16>> = lengths,
         <<name::binary-size(name_length), extra_and_comment::binary>> <- fields,
         <<_extra::binary-size(extra_length), _comment::binary-size(comment_length)>> <- extra_and_comment,
         true <- name == @name and size <= @limit and method in [0, 8],
         true <- band(flags, bnot(0x0808)) == 0 and band(attributes >>> 16, 0o170000) in [0, 0o100000] do
      {:ok, %{flags: flags, method: method, crc: crc, compressed: compressed, size: size, offset: offset}}
    else
      _ -> :error
    end
  end

  defp local_file(archive, entry) do
    <<0x04034B50::little-32, _version::16, header::binary-size(24), fields::binary>> = archive
    <<modes::binary-size(8), sizes::binary-size(12), lengths::binary-size(4)>> = header
    <<flags::little-16, method::little-16, _time::32>> = modes
    <<crc::little-32, compressed::little-32, size::little-32>> = sizes
    <<namesize::little-16, extrasize::little-16>> = lengths
    <<name::binary-size(namesize), _extra::binary-size(extrasize), rest::binary>> = fields

    data_end = 30 + namesize + extrasize + entry.compressed
    data = binary_part(rest, 0, entry.compressed)
    descriptor = binary_part(archive, data_end, entry.offset - data_end)

    valid =
      if band(flags, 8) == 0,
        do: {crc, compressed, size, descriptor} == {entry.crc, entry.compressed, entry.size, ""},
        else: descriptor?(descriptor, entry)

    if name == @name and flags == entry.flags and method == entry.method and valid, do: {:ok, data}, else: :error
  end

  defp descriptor?(<<0x08074B50::little-32, rest::binary>>, entry), do: descriptor?(rest, entry)

  defp descriptor?(<<crc::little-32, compressed::little-32, size::little-32>>, entry),
    do: {crc, compressed, size} == {entry.crc, entry.compressed, entry.size}

  defp descriptor?(_, _), do: false

  defp expand(0, bytes) when byte_size(bytes) <= @limit, do: {:ok, bytes}

  defp expand(8, compressed) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z, -15)
      result = inflate(z, compressed, "")
      :ok = :zlib.inflateEnd(z)
      result
    after
      :zlib.close(z)
    end
  end

  defp expand(_, _), do: :error

  defp inflate(z, input, accumulated) do
    {status, output} = :zlib.safeInflate(z, input)
    bytes = accumulated <> IO.iodata_to_binary(output)

    cond do
      byte_size(bytes) > @limit -> :error
      status == :finished -> {:ok, bytes}
      true -> inflate(z, [], bytes)
    end
  end
end
