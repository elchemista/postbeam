# Preserve the imported SMTP callback API and protocol branch structure.
# credo:disable-for-this-file Credo.Check.Readability.FunctionNames
# credo:disable-for-this-file Credo.Check.Readability.PredicateFunctionNames
# Copyright 2009 Andrew Thompson <andrew@hijacked.us>. All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
#   1. Redistributions of source code must retain the above copyright notice,
#      this list of conditions and the following disclaimer.
#   2. Redistributions in binary form must reproduce the above copyright
#      notice, this list of conditions and the following disclaimer in the
#      documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE FREEBSD PROJECT ``AS IS'' AND ANY EXPRESS OR
# IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO
# EVENT SHALL THE FREEBSD PROJECT OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
# INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
# (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
# LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
# ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
# SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

defmodule Postbeam.SMTP.Util do
  @moduledoc "Address parsing, MIME identifiers, timestamps and SMTP authentication helpers."
  if Mix.env() == :test do
    @compile [:export_all, :nowarn_export_all]
  end

  require Record

  Record.defrecordp(:hostent, :hostent,
    h_name: :undefined,
    h_aliases: [],
    h_addrtype: :undefined,
    h_length: :undefined,
    h_addr_list: []
  )

  @typep name_address() :: {charlist() | :undefined, charlist()}
  def mxlookup(domain) do
    domain = if is_binary(domain), do: String.to_charlist(domain), else: domain

    case :inet_res.lookup(domain, :in, :mx) do
      [] -> Enum.map(:inet_res.lookup(domain, :in, :a), &{10, :inet.ntoa(&1)})
      result -> Enum.sort(result)
    end
  end

  @spec guess_FQDN() :: charlist()
  def guess_FQDN() do
    guess_fqdn()
  end

  @doc "Returns the local fully qualified hostname, falling back to localhost on lookup errors."
  @spec guess_fqdn() :: charlist()
  def guess_fqdn() do
    with {:ok, hostname} <- :inet.gethostname(),
         {:ok, hostent(h_name: fqdn)} <- :inet.gethostbyname(hostname) do
      fqdn
    else
      {:error, _reason} -> ~c"localhost"
    end
  end

  @spec compute_cram_digest(binary(), binary()) :: binary()
  def compute_cram_digest(key, data) do
    :crypto.mac(:hmac, :md5, key, data) |> Base.encode16(case: :lower)
  end

  @spec get_cram_string(charlist()) :: charlist()
  def get_cram_string(hostname) do
    :erlang.binary_to_list(
      :base64.encode(
        :lists.flatten(
          :io_lib.format(~c"<~B.~B@~s>", [
            :rand.uniform(4_294_967_295),
            :rand.uniform(4_294_967_295),
            hostname
          ])
        )
      )
    )
  end

  @spec trim_crlf(charlist()) :: charlist()
  def trim_crlf(string) do
    :string.strip(:string.strip(string, :right, 10), :right, 13)
  end

  def rfc5322_timestamp() do
    {{year, month, day}, {hour, minute, second}} = :calendar.local_time()
    n_day = :calendar.day_of_the_week(year, month, day)
    do_w = :lists.nth(n_day, [~c"Mon", ~c"Tue", ~c"Wed", ~c"Thu", ~c"Fri", ~c"Sat", ~c"Sun"])

    mo_y =
      :lists.nth(month, [
        ~c"Jan",
        ~c"Feb",
        ~c"Mar",
        ~c"Apr",
        ~c"May",
        ~c"Jun",
        ~c"Jul",
        ~c"Aug",
        ~c"Sep",
        ~c"Oct",
        ~c"Nov",
        ~c"Dec"
      ])

    :io_lib.format(~c"~s, ~b ~s ~b ~2..0b:~2..0b:~2..0b ~s", [
      do_w,
      day,
      mo_y,
      year,
      hour,
      minute,
      second,
      zone()
    ])
  end

  def zone() do
    time = :erlang.universaltime()
    local_time = :calendar.universal_time_to_local_time(time)

    diff_secs =
      :calendar.datetime_to_gregorian_seconds(local_time) -
        :calendar.datetime_to_gregorian_seconds(time)

    format_zone(diff_secs)
  end

  @doc "Formats a UTC offset in seconds as an RFC 5322 offset, including fractional hours."
  @spec format_zone(integer()) :: binary()
  def format_zone(seconds) when is_integer(seconds) do
    sign = if seconds < 0, do: "-", else: "+"
    minutes = div(abs(seconds), 60)
    hours = minutes |> div(60) |> Integer.to_string() |> String.pad_leading(2, "0")
    remainder = minutes |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")
    sign <> hours <> remainder
  end

  def generate_message_id() do
    fqdn = guess_FQDN()

    md5 =
      for <<x <- :erlang.md5(:erlang.term_to_binary([unique_id(), fqdn]))>>,
        into: [],
        do: :io_lib.format(~c"~2.16.0b", [x])

    :io_lib.format(~c"<~s@~s>", [md5, fqdn])
  end

  def generate_message_boundary() do
    fqdn = guess_FQDN()

    [
      ~c"_=",
      for(<<x <- :erlang.md5(:erlang.term_to_binary([unique_id(), fqdn]))>>,
        into: [],
        do: :io_lib.format(~c"~2.36.0b", [x])
      ),
      ~c"=_"
    ]
  end

  defp unique_id() do
    {:erlang.system_time(), :erlang.unique_integer()}
  end

  def combine_rfc822_addresses([]) do
    <<>>
  end

  def combine_rfc822_addresses(addresses) do
    :erlang.iolist_to_binary(combine_rfc822_addresses(addresses, []))
  end

  defp combine_rfc822_addresses([], [32, 44 | acc]) do
    :lists.reverse(acc)
  end

  defp combine_rfc822_addresses([{:undefined, email} | rest], acc) do
    combine_rfc822_addresses(rest, [32, 44, email | acc])
  end

  defp combine_rfc822_addresses([{[], email} | rest], acc) do
    combine_rfc822_addresses(rest, [32, 44, email | acc])
  end

  defp combine_rfc822_addresses([{<<>>, email} | rest], acc) do
    combine_rfc822_addresses(rest, [32, 44, email | acc])
  end

  defp combine_rfc822_addresses([{name, email} | rest], acc) do
    quoted = [opt_quoted(name), ~c" <", email, ~c">"]
    combine_rfc822_addresses(rest, [32, 44, quoted | acc])
  end

  defp opt_quoted(b) when is_binary(b) do
    opt_quoted(:erlang.binary_to_list(b))
  end

  defp opt_quoted(s) when is_list(s) do
    no_controls =
      :lists.map(
        fn
          c when c < 32 -> 32
          c -> c
        end,
        s
      )

    case :lists.any(&is_special/1, no_controls) do
      false ->
        no_controls

      true ->
        :lists.flatten([
          34,
          :lists.map(
            fn
              34 -> ~c"\\\""
              92 -> ~c"\\\\"
              c -> c
            end,
            no_controls
          ),
          34
        ])
    end
  end

  defp is_special(char), do: char in [40, 41, 60, 62, 64, 44, 59, 58, 92, 34, 46, 91, 93, 39]

  @spec parse_rfc5322_addresses(charlist() | binary()) ::
          {:ok, list(name_address())} | {:error, any()}
  def parse_rfc5322_addresses(b) when is_binary(b) do
    case :unicode.characters_to_list(b) do
      chars when is_list(chars) -> parse_rfc5322_addresses(chars)
      {kind, _, _} when kind in [:error, :incomplete] -> {:error, :invalid_utf8}
    end
  end

  def parse_rfc5322_addresses(s) when is_list(s) do
    case :postbeam_smtp_rfc5322_scan.string(s) do
      {:ok, tokens, _l} ->
        f = fn {name, {:addr, local, domain}} -> {name, local ++ ~c"@" ++ domain} end

        case :postbeam_smtp_rfc5322_parse.parse(tokens) do
          {:ok, {:mailbox_list, addr_list}} -> {:ok, :lists.map(f, addr_list)}
          {:ok, {:group, {_groupame, addr_list}}} -> {:ok, :lists.map(f, addr_list)}
          {:error, _} = err -> err
        end

      {:error, reason, _l} ->
        {:error, reason}
    end
  end

  @spec parse_rfc822_addresses(charlist() | binary()) ::
          {:ok, list(name_address())} | {:error, any()}
  def parse_rfc822_addresses(b) when is_binary(b) do
    case :unicode.characters_to_list(b) do
      chars when is_list(chars) -> parse_rfc822_addresses(chars)
      {kind, _, _} when kind in [:error, :incomplete] -> {:error, :invalid_utf8}
    end
  end

  def parse_rfc822_addresses(s) when is_list(s) do
    scanned = :lists.reverse([{:"$end", 0} | scan_rfc822(s, [])])
    :postbeam_smtp_rfc822_parse.parse(scanned)
  end

  defp scan_rfc822([], acc) do
    acc
  end

  defp scan_rfc822([ch | r], acc) when ch <= 32 do
    scan_rfc822(r, acc)
  end

  defp scan_rfc822([34 | r], acc) do
    {token, rest} = scan_rfc822_scan_endquote(r, [], false)
    scan_rfc822(rest, [{:string, 0, token} | acc])
  end

  defp scan_rfc822([44 | rest], acc) do
    scan_rfc822(rest, [{:",", 0} | acc])
  end

  defp scan_rfc822([60 | rest], acc) do
    {token, r} = scan_rfc822_scan_endpointybracket(rest)
    scan_rfc822(r, [{:>, 0}, {:string, 0, token}, {:<, 0} | acc])
  end

  defp scan_rfc822(string, acc) do
    case :re.run(string, ~c"^([^ <>,]+)(.*)", [{:capture, :all_but_first, :list}]) do
      {:match, [token, rest]} -> scan_rfc822(rest, [{:string, 0, token} | acc])
      :nomatch -> [{:string, 0, string} | acc]
    end
  end

  defp scan_rfc822_scan_endpointybracket(string) do
    case :re.run(string, ~c"(.*?)>(.*)", [{:capture, :all_but_first, :list}]) do
      {:match, [token, rest]} -> {token, rest}
      :nomatch -> {string, []}
    end
  end

  defp scan_rfc822_scan_endquote([92 | r], acc, in_escape) do
    scan_rfc822_scan_endquote(r, acc, not in_escape)
  end

  defp scan_rfc822_scan_endquote([34 | r], acc, true) do
    scan_rfc822_scan_endquote(r, [34 | acc], false)
  end

  defp scan_rfc822_scan_endquote([34 | rest], acc, false) do
    {:lists.reverse(acc), rest}
  end

  defp scan_rfc822_scan_endquote([ch | rest], acc, _) do
    scan_rfc822_scan_endquote(rest, [ch | acc], false)
  end
end
