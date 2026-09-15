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

defmodule Postbeam.SMTP.DKIM do
  @moduledoc "DKIM signing and canonicalization for already encoded MIME messages."

  alias Postbeam.SMTP.Binary
  alias Postbeam.SMTP.MIME
  @spec sign(list(binary()), binary(), MIME.dkim_options()) :: list(binary())
  @doc "Prepends a DKIM signature to encoded headers using the supplied signing options."
  def sign(headers, body, opts) do
    headers_to_sign = :proplists.get_value(:h, opts, ["from", "to", "subject", "date"])
    s_did = :proplists.get_value(:d, opts)
    selector = :proplists.get_value(:s, opts)

    optional_tags =
      :lists.foldl(
        fn key, acc ->
          case :proplists.get_value(key, opts) do
            :undefined -> acc
            value -> [{key, value} | acc]
          end
        end,
        [],
        [:t, :x]
      )

    {hdrs_can_t, body_can_t} = can = :proplists.get_value(:c, opts, {:relaxed, :simple})
    algorithm = :proplists.get_value(:a, opts, :"rsa-sha256")
    private_key = :proplists.get_value(:private_key, opts)
    can_body = canonicalize_body(body, body_can_t)
    body_hash = dkim_hash_body(can_body)

    tags = [
      {:v, 1},
      {:a, algorithm},
      {:bh, body_hash},
      {:c, can},
      {:d, s_did},
      {:h, headers_to_sign},
      {:s, selector} | optional_tags
    ]

    headers1 = dkim_filter_headers(headers, headers_to_sign)
    can_headers = canonicalize_headers(headers1, hdrs_can_t)

    [dkim_header_no_b] =
      canonicalize_headers([dkim_make_header([{:b, :undefined} | tags])], hdrs_can_t)

    data_hash = dkim_hash_data(can_headers, dkim_header_no_b)
    signature = dkim_sign(data_hash, algorithm, private_key)
    dkim_header = dkim_make_header([{:b, signature} | tags])
    [dkim_header | headers]
  end

  @spec dkim_filter_headers([binary()], [binary()]) :: [binary()]
  defp dkim_filter_headers(headers, headers_to_sign) do
    keyed_headers =
      for hdr <- headers,
          into: [],
          do:
            (
              [name, _] = :binary.split(hdr, ":")
              {Binary.strip(Binary.to_lower(name)), hdr}
            )

    with_undef =
      for name <- headers_to_sign,
          into: [],
          do:
            MIME.get_header_value(
              Binary.to_lower(name),
              keyed_headers
            )

    for hdr <- with_undef, hdr !== :undefined, into: [], do: hdr
  end

  @doc "Canonicalizes encoded headers with the selected DKIM algorithm."
  @spec canonicalize_headers([binary()], :simple | :relaxed) :: [binary()]
  def canonicalize_headers(headers, :simple) do
    headers
  end

  def canonicalize_headers(headers, :relaxed) do
    dkim_canonic_hdrs_relaxed(headers)
  end

  @spec dkim_canonic_hdrs_relaxed([binary()]) :: [binary()]
  defp dkim_canonic_hdrs_relaxed([hdr | rest]) do
    [name, value] = :binary.split(hdr, ":")
    low_strip_name = Binary.to_lower(Binary.strip(name))
    unfolded_hdr_value = :binary.replace(value, "\r\n", <<>>, [:global])

    single_ws_value =
      :re.replace(unfolded_hdr_value, ~c"[\t ]+", ~c" ", [:global, return: :binary])

    stripped_with_name =
      <<low_strip_name::binary, ":", Binary.strip(single_ws_value)::binary>>

    [stripped_with_name | dkim_canonic_hdrs_relaxed(rest)]
  end

  defp dkim_canonic_hdrs_relaxed([]) do
    []
  end

  @doc "Canonicalizes a body for DKIM; relaxed body canonicalization is unsupported."
  @spec canonicalize_body(binary(), :simple | :relaxed) :: binary()
  def canonicalize_body(<<>>, :simple) do
    "\r\n"
  end

  def canonicalize_body(body, :simple) do
    :re.replace(body, ~c"(\r\n)*$", ~c"\r\n", return: :binary)
  end

  def canonicalize_body(_body, :relaxed) do
    throw({:not_supported, :dkim_body_relaxed})
  end

  @spec dkim_hash_body(binary()) :: binary()
  defp dkim_hash_body(canonic_body) do
    :crypto.hash(:sha256, canonic_body)
  end

  @spec dkim_hash_data([binary()], binary()) :: binary()
  defp dkim_hash_data(canonic_headers, dkim_header) do
    joined_headers = for hdr <- canonic_headers, into: <<>>, do: <<hdr::binary, "\r\n">>
    :crypto.hash(:sha256, <<joined_headers::binary, dkim_header::binary>>)
  end

  @doc "Reports whether the public_key application supports Ed25519 signing."
  @spec ed25519_supported?() :: boolean()
  def ed25519_supported?, do: ed25519_supported()

  @doc "Reports whether Ed25519 signing is available; prefer `ed25519_supported?/0`."
  @spec ed25519_supported() :: boolean()
  def ed25519_supported do
    {:ok, public_key_app_version_string} = :application.get_key(:public_key, :vsn)

    public_key_app_version_list =
      :lists.map(&:erlang.list_to_integer/1, :string.tokens(public_key_app_version_string, ~c"."))

    public_key_app_version_list >= [1, 11, 2]
  end

  @spec dkim_get_algorithm_digest(:"rsa-sha256" | :"ed25519-sha256") :: :sha256 | :none
  defp dkim_get_algorithm_digest(algorithm) do
    case algorithm do
      :"rsa-sha256" ->
        :sha256

      :"ed25519-sha256" ->
        case ed25519_supported() do
          true -> :none
          false -> throw(~c"DKIM with Ed25519 requires Erlang/OTP 24.1+")
        end
    end
  end

  @spec dkim_sign(
          binary(),
          :"rsa-sha256" | :"ed25519-sha256",
          {:pem_plain, binary()} | {:pem_encrypted, binary(), charlist()}
        ) :: binary()
  defp dkim_sign(data_hash, algorithm, {:pem_plain, priv_bin}) do
    [priv_entry] = :public_key.pem_decode(priv_bin)
    digest = dkim_get_algorithm_digest(algorithm)
    key = :public_key.pem_entry_decode(priv_entry)
    :public_key.sign({:digest, data_hash}, digest, key)
  end

  defp dkim_sign(data_hash, algorithm, {:pem_encrypted, enc_priv_bin, passwd}) do
    [enc_priv_entry] = :public_key.pem_decode(enc_priv_bin)
    digest = dkim_get_algorithm_digest(algorithm)
    key = :public_key.pem_entry_decode(enc_priv_entry, passwd)
    :public_key.sign({:digest, data_hash}, digest, key)
  end

  @spec dkim_make_header([{atom() | binary(), term()}]) :: binary()
  defp dkim_make_header(tags) do
    rev_tags = :lists.reverse(tags)

    encoded_tags =
      Binary.join(
        for({k, v} <- rev_tags, into: [], do: dkim_encode_tag(k, v)),
        "; "
      )

    Binary.join(
      MIME.encode_headers([{"DKIM-Signature", encoded_tags}]),
      "\r\n"
    )
  end

  @spec dkim_encode_tag(atom() | binary(), term()) :: binary()
  defp dkim_encode_tag(:v, 1) do
    "v=1"
  end

  defp dkim_encode_tag(:a, algorithm) do
    <<"a=", :erlang.atom_to_binary(algorithm, :utf8)::binary>>
  end

  defp dkim_encode_tag(:b, :undefined) do
    "b="
  end

  defp dkim_encode_tag(:b, v) do
    b64_sign = :base64.encode(v)
    <<"b=", b64_sign::binary>>
  end

  defp dkim_encode_tag(:bh, v) do
    b64_sign = :base64.encode(v)
    <<"bh=", b64_sign::binary>>
  end

  defp dkim_encode_tag(:c, {hdrs, :simple}) do
    <<"c=", :erlang.atom_to_binary(hdrs, :utf8)::binary, "/simple">>
  end

  defp dkim_encode_tag(:d, domain) do
    <<"d=", domain::binary>>
  end

  defp dkim_encode_tag(:h, hdrs) do
    joined =
      Binary.join(
        for(h <- hdrs, into: [], do: Binary.to_lower(h)),
        ":"
      )

    <<"h=", joined::binary>>
  end

  defp dkim_encode_tag(:i, v) do
    q_p_value = dkim_qp_tag_value(v)
    <<"i=", q_p_value::binary>>
  end

  defp dkim_encode_tag(:l, int_val) do
    bin_val = :erlang.list_to_binary(:erlang.integer_to_list(int_val))
    <<"l=", bin_val::binary>>
  end

  defp dkim_encode_tag(:q, ["dns/txt"]) do
    "q=dns/txt"
  end

  defp dkim_encode_tag(:s, selector) do
    <<"s=", selector::binary>>
  end

  defp dkim_encode_tag(:t, :now) do
    dkim_encode_tag(:t, :calendar.universal_time())
  end

  defp dkim_encode_tag(:t, date_time) do
    bin_ts = datetime_to_bin_timestamp(date_time)
    <<"t=", bin_ts::binary>>
  end

  defp dkim_encode_tag(:x, date_time) do
    bin_ts = datetime_to_bin_timestamp(date_time)
    <<"x=", bin_ts::binary>>
  end

  defp dkim_encode_tag(k, v) when is_binary(k) and is_binary(v) do
    <<k::binary, v::binary>>
  end

  @spec dkim_qp_tag_value(binary()) :: binary()
  defp dkim_qp_tag_value(value) do
    [q_p_value] = MIME.encode_quoted_printable(value)
    :binary.replace(q_p_value, ";", "=3B")
  end

  @spec datetime_to_bin_timestamp(:calendar.datetime()) :: binary()
  defp datetime_to_bin_timestamp(date_time) do
    epoch_start = 62_167_219_200
    unix_timestamp = :calendar.datetime_to_gregorian_seconds(date_time) - epoch_start
    :erlang.list_to_binary(:erlang.integer_to_list(unix_timestamp))
  end
end
