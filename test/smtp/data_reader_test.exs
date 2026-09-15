defmodule Postbeam.SMTP.DataReaderTest do
  use ExUnit.Case, async: true
  alias Postbeam.SMTP.Session.DataReader

  defmodule Chunks do
    def recv(ref, 0, 1000) do
      case Process.get(ref) do
        [chunk | rest] ->
          Process.put(ref, rest)
          {:ok, chunk}

        [] ->
          {:error, :closed}
      end
    end
  end

  defp read(chunks, options \\ [], max_size \\ :infinity) do
    ref = make_ref()
    Process.put(ref, chunks)
    result = DataReader.read(Chunks, ref, max_size, options)
    remaining = IO.iodata_to_binary(Process.delete(ref))

    case result do
      {:receive_data, body, rest} -> {:ok, body, rest <> remaining}
      {:receive_data, {:error, reason}} -> {:error, reason}
    end
  end

  test "framing works at every split, including a terminator spread over five packets" do
    wire = "first\r\nsecond\r\n.\r\nQUIT\r\n"

    for split <- 1..(byte_size(wire) - 1) do
      first = binary_part(wire, 0, split)
      second = binary_part(wire, split, byte_size(wire) - split)
      assert read([first, second]) == {:ok, "first\r\nsecond", "QUIT\r\n"}
    end

    assert read(for <<byte <- wire>>, do: <<byte>>) == {:ok, "first\r\nsecond", "QUIT\r\n"}
  end

  test "an empty message can end immediately after the DATA command" do
    assert read([".", "\r", "\nQUIT\r\n"]) == {:ok, "", "QUIT\r\n"}
  end

  test "bare newline policy is independent of packet boundaries" do
    for {wire, expected} <- [{"a\nb", "a\r\nb"}, {"a\rb", "a\r\nb"}, {"a\r\nb", "a\r\nb"}] do
      chunks = for <<byte <- wire <> "\r\n.\r\n">>, do: <<byte>>
      assert read(chunks, allow_bare_newlines: :fix) == {:ok, expected, ""}
      assert read(chunks, allow_bare_newlines: :ignore) == {:ok, wire, ""}

      if wire != expected do
        assert read(chunks) == {:error, :bare_newline}
        assert read(chunks, allow_bare_newlines: :strip) == {:ok, "ab", ""}
      end
    end
  end

  test "the size limit also applies to a complete message in a single packet" do
    assert read(["12345\r\n.\r\n"], [], 4) == {:error, :size_exceeded}
    assert read(["1234\r\n.\r\n"], [], 4) == {:ok, "1234", ""}
    assert read(["123456789", "123456789"], [], 4) == {:error, :size_exceeded}
  end
end
