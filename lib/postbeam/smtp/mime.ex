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

defmodule Postbeam.SMTP.MIME do
  # Charset conversion is optional; raw decoding works without the NIF.
  @compile {:no_warn_undefined, {:iconv, :convert, 3}}
  @moduledoc """
  MIME encoding and decoding, including multipart messages and attachments.

  Messages use `{type, subtype, headers, parameters, body}` tuples. Text, header
  names and values are binaries; multipart bodies are lists of MIME tuples.
  Pass `dkim: options` to `encode/2` to sign with `Postbeam.SMTP.DKIM`.
  Charset conversion uses the optional `:eiconv` dependency when available.
  Without it, default decoding preserves header and body encodings. Use
  `encoding: :raw` to request this behavior explicitly.
  """

  alias Postbeam.SMTP.Binary
  alias Postbeam.SMTP.DKIM
  alias Postbeam.SMTP.MIME.EncodedWord
  alias Postbeam.SMTP.MIME.Parameters
  alias Postbeam.SMTP.MIME.TransferEncoding
  alias Postbeam.SMTP.Util

  if Mix.env() == :test do
    @compile [:export_all, :nowarn_export_all]
  end

  @type mime_type() :: binary()
  @type mime_subtype() :: binary()
  @type headers() :: list({binary(), binary()})
  @type parameters() :: %{
          optional(:transfer_encoding) => binary(),
          optional(:content_type_params) => list({binary(), binary()}),
          optional(:disposition) => binary(),
          optional(:disposition_params) => list({binary(), binary()})
        }
  @type mimetuple() ::
          {mime_type(), mime_subtype(), headers(), parameters(),
           binary() | mimetuple() | list(mimetuple())}
  @typep dkim_priv_key() :: {:pem_plain, binary()} | {:pem_encrypted, binary(), charlist()}
  @type dkim_options() ::
          list(
            {:h, list(binary())}
            | {:d, binary()}
            | {:s, binary()}
            | {:t, :now | :calendar.datetime()}
            | {:x, :calendar.datetime()}
            | {:c, {:simple | :relaxed, :simple | :relaxed}}
            | {:a, :"rsa-sha256" | :"ed25519-sha256"}
            | {:private_key, dkim_priv_key()}
          )
  @type options() ::
          list(
            {:encoding, binary() | :none | :raw}
            | {:decode_attachments, boolean()}
            | {:dkim, dkim_options()}
            | {:allow_missing_version, boolean()}
            | {:default_mime_version, binary()}
          )
  @spec decode(binary()) :: mimetuple()
  @doc "Decodes a MIME message into its headers, parameters and body parts."
  def decode(all) do
    {headers, body} = parse_headers(all)

    decode(headers, body,
      encoding: get_default_encoding(),
      decode_attachments: true,
      allow_missing_version: true,
      default_mime_version: "1.0"
    )
  end

  @spec decode(binary(), options()) :: mimetuple()
  @doc "Decodes a MIME message into its headers, parameters and body parts."
  def decode(all, options) when is_binary(all) and is_list(options) do
    {headers, body} = parse_headers(all)
    decode(headers, body, options)
  end

  @spec decode(headers(), binary(), options()) :: mimetuple()
  defp decode(orig_headers, body, options) do
    encoding = :proplists.get_value(:encoding, options, :none)
    headers = decode_headers(orig_headers, [], encoding)

    case parse_with_comments(get_header_value("MIME-Version", headers)) do
      :undefined ->
        decode_unversioned(headers, body, options)

      other ->
        decode_component(headers, body, other, options)
    end
  end

  @spec decode_unversioned(headers(), binary(), options()) :: mimetuple()
  defp decode_unversioned(headers, body, options) do
    encoding = :proplists.get_value(:encoding, options, :none)
    allow_missing_version = :proplists.get_value(:allow_missing_version, options, false)
    content_type = parse_content_type(get_header_value("Content-Type", headers))

    case content_type do
      {"multipart", _sub_type, _parameters} when allow_missing_version ->
        mime_version = :proplists.get_value(:default_mime_version, options, "1.0")
        decode_component(headers, body, mime_version, options)

      {"multipart", _sub_type, _parameters} ->
        :erlang.error(:non_mime_multipart)

      {type, sub_type, content_type_parameters} ->
        new_body =
          decode_body(
            get_header_value("Content-Transfer-Encoding", headers),
            body,
            :proplists.get_value("charset", content_type_parameters),
            encoding
          )

        {disposition, disposition_params} =
          case parse_content_disposition(get_header_value("Content-Disposition", headers)) do
            :undefined -> {"inline", []}
            disp -> disp
          end

        parameters = %{
          content_type_params: content_type_parameters,
          disposition: disposition,
          disposition_params: disposition_params
        }

        {type, sub_type, headers, parameters, new_body}

      :undefined ->
        parameters = %{
          content_type_params: [{"charset", "us-ascii"}],
          disposition: "inline",
          disposition_params: []
        }

        {"text", "plain", headers, parameters,
         decode_body(get_header_value("Content-Transfer-Encoding", headers), body)}
    end
  end

  @spec encode(mimetuple()) :: binary()
  @doc "Encodes a MIME tuple, adding required headers and optional DKIM signatures."
  def encode(mime_mail) do
    encode(mime_mail, [])
  end

  @doc "Encodes a MIME tuple, adding required headers and optional DKIM signatures."
  @spec encode(mimetuple(), options()) :: binary()
  def encode({type, subtype, headers, content_type_params, parts}, options) do
    {fixed_params, fixed_headers} =
      ensure_content_headers(type, subtype, content_type_params, headers, parts, true)

    checked_headers = check_headers(fixed_headers)

    encoded_body =
      Binary.join(
        encode_component(type, subtype, checked_headers, fixed_params, parts),
        ~c"\r\n"
      )

    encoded_headers = encode_headers(checked_headers)

    signed_headers =
      case :proplists.get_value(:dkim, options) do
        :undefined -> encoded_headers
        dkim_options -> DKIM.sign(encoded_headers, encoded_body, dkim_options)
      end

    :erlang.list_to_binary([
      Binary.join(signed_headers, ~c"\r\n"),
      ~c"\r\n\r\n",
      encoded_body
    ])
  end

  def encode(_, _) do
    :erlang.error(:non_mime)
  end

  @spec decode_headers(headers(), headers(), binary() | :none | :raw) :: headers()
  defp decode_headers(headers, _, encoding) when encoding in [:none, :raw] do
    headers
  end

  defp decode_headers([], acc, _charset) do
    :lists.reverse(acc)
  end

  defp decode_headers([{key, value} | headers], acc, charset) do
    decode_headers(headers, [{key, decode_header(value, charset)} | acc], charset)
  end

  @spec decode_header(binary(), binary()) :: binary()
  defp decode_header(value, charset) do
    r_tokens = tokenize_header(value, [])
    tokens = :lists.reverse(r_tokens)

    decoded =
      try do
        decode_header_tokens_strict(tokens, charset)
      catch
        type, reason ->
          stacktrace = __STACKTRACE__

          case decode_header_tokens_permissive(tokens, charset, []) do
            {:ok, dec} -> dec
            :error -> :erlang.raise(type, reason, stacktrace)
          end
      end

    :erlang.iolist_to_binary(decoded)
  end

  @typep hdr_token() :: binary() | {binary(), binary()}
  @spec tokenize_header(binary(), list(hdr_token())) :: list(hdr_token())
  defp tokenize_header(<<>>, acc) do
    acc
  end

  defp tokenize_header(value, acc) do
    case :re.run(value, ~c"=\\?([-A-Za-z0-9_]+)\\?([qQbB])\\?([^ ]+)\\?=", [:ungreedy]) do
      :nomatch ->
        [value | acc]

      {:match,
       [
         {all_start, all_len},
         {encoding_start, encoding_len},
         {type_start, _},
         {data_start, data_len}
       ]} ->
        encoding = Binary.substr(value, encoding_start + 1, encoding_len)

        type =
          Binary.to_lower(Binary.substr(value, type_start + 1, 1))

        data = Binary.substr(value, data_start + 1, data_len)

        encoded_data =
          case type do
            "q" ->
              TransferEncoding.decode_quoted_printable(
                :binary.replace(data, "_", "=20", [:global])
              )

            "b" ->
              TransferEncoding.decode_base64(:binary.replace(data, "_", " ", [:global]))
          end

        offset =
          case :re.run(
                 Binary.substr(value, all_start + all_len + 1),
                 ~c"^([ \t\n\r]+)=\\?[-A-Za-z0-9_]+\\?[^ ]\\?[^ ]+\\?=",
                 [:ungreedy]
               ) do
            :nomatch -> 1
            {:match, [{_, _}, {_, white_space_len}]} -> 1 + white_space_len
          end

        new_acc =
          case Binary.substr(value, 1, all_start) do
            <<>> -> [{fix_encoding(encoding), encoded_data} | acc]
            other -> [{fix_encoding(encoding), encoded_data}, other | acc]
          end

        tokenize_header(Binary.substr(value, all_start + all_len + offset), new_acc)
    end
  end

  @spec decode_header_tokens_strict([hdr_token()], binary()) :: iodata()
  defp decode_header_tokens_strict([], _) do
    []
  end

  defp decode_header_tokens_strict([{encoding, data} | tokens], charset) do
    {:ok, s} = convert(charset, encoding, data)
    [s | decode_header_tokens_strict(tokens, charset)]
  end

  defp decode_header_tokens_strict([data | tokens], charset) do
    [data | decode_header_tokens_strict(tokens, charset)]
  end

  @spec decode_header_tokens_permissive([hdr_token()], binary(), [hdr_token()]) ::
          {:ok, iodata()} | :error
  defp decode_header_tokens_permissive([], _, [result]) when is_binary(result) do
    {:ok, result}
  end

  defp decode_header_tokens_permissive([], _, stack) do
    case :lists.all(&:erlang.is_binary/1, stack) do
      true -> {:ok, :lists.reverse(stack)}
      false -> :error
    end
  end

  defp decode_header_tokens_permissive([{enc, data} | tokens], charset, [{enc, prev_data} | stack]) do
    new_data = :erlang.iolist_to_binary([prev_data, data])
    {:ok, s} = convert(charset, enc, new_data)
    decode_header_tokens_permissive(tokens, charset, [s | stack])
  end

  defp decode_header_tokens_permissive([next_token | _] = tokens, charset, [{_, _} | stack])
       when is_binary(next_token) or is_tuple(next_token) do
    decode_header_tokens_permissive(tokens, charset, stack)
  end

  defp decode_header_tokens_permissive([data | tokens], charset, stack) do
    decode_header_tokens_permissive(tokens, charset, [data | stack])
  end

  @spec convert(binary(), binary() | :undefined, binary()) :: {:ok, binary()}
  defp convert(_to, "x-binaryenc", data) do
    {:ok, data}
  end

  defp convert(to, from, data) do
    result = :iconv.convert(from, to, data)
    {:ok, result}
  end

  @spec decode_component(headers(), binary(), binary() | :undefined, options()) :: mimetuple()
  defp decode_component(headers, body, <<"1.0", _::binary>> = mime_vsn, options) do
    {disposition, disposition_params} =
      case parse_content_disposition(get_header_value("Content-Disposition", headers)) do
        {disposition, disposition_params} -> {disposition, disposition_params}
        _ -> {"inline", []}
      end

    case parse_content_type(get_header_value("Content-Type", headers)) do
      {"multipart", sub_type, parameters} ->
        case :proplists.get_value("boundary", parameters) do
          :undefined ->
            :erlang.error(:no_boundary)

          boundary ->
            parameters2 = %{
              content_type_params: parameters,
              disposition: disposition,
              disposition_params: disposition_params
            }

            {"multipart", sub_type, headers, parameters2,
             split_body_by_boundary(
               body,
               :erlang.list_to_binary([~c"--", boundary]),
               mime_vsn,
               options
             )}
        end

      {"message", "rfc822", parameters} ->
        {new_headers, new_body} = parse_headers(body)

        parameters2 = %{
          content_type_params: parameters,
          disposition: disposition,
          disposition_params: disposition_params
        }

        {"message", "rfc822", headers, parameters2, decode(new_headers, new_body, options)}

      {type, sub_type, parameters} ->
        parameters2 = %{
          content_type_params: parameters,
          disposition: disposition,
          disposition_params: disposition_params
        }

        {type, sub_type, headers, parameters2,
         decode_body(
           get_header_value("Content-Transfer-Encoding", headers),
           body,
           :proplists.get_value("charset", parameters),
           :proplists.get_value(:encoding, options, :none)
         )}

      :undefined ->
        type = "text"
        sub_type = "plain"

        parameters = %{
          content_type_params: [{"charset", "us-ascii"}],
          disposition: disposition,
          disposition_params: disposition_params
        }

        {type, sub_type, headers, parameters,
         decode_body(get_header_value("Content-Transfer-Encoding", headers), body)}
    end
  end

  defp decode_component(_headers, _body, other, _options) do
    :erlang.error({:mime_version, other})
  end

  @spec get_header_value(binary(), list({binary(), binary()}), any()) :: binary() | any()
  @doc "Looks up a header by name, ignoring ASCII case."
  def get_header_value(needle, headers, default) do
    needle_lower = Binary.to_lower(needle)
    f = fn {header, _value} -> Binary.to_lower(header) === needle_lower end

    case :lists.search(f, headers) do
      {:value, {_header, value}} -> value
      false -> default
    end
  end

  @spec get_header_value(binary(), list({binary(), binary()})) :: binary() | :undefined
  @doc "Looks up a header by name, ignoring ASCII case."
  def get_header_value(needle, headers) do
    get_header_value(needle, headers, :undefined)
  end

  @spec parse_with_comments(binary()) :: binary() | no_return()
  @spec parse_with_comments(atom()) :: atom()
  defp parse_with_comments(value) when is_binary(value) do
    parse_with_comments(value, [], 0, false)
  end

  defp parse_with_comments(value) do
    value
  end

  @spec parse_with_comments(binary(), list(), non_neg_integer(), boolean()) ::
          binary() | no_return()
  defp parse_with_comments(<<>>, _acc, _depth, quotes) when quotes do
    :erlang.error(:unterminated_quotes)
  end

  defp parse_with_comments(<<>>, _acc, depth, _quotes) when depth > 0 do
    :erlang.error(:unterminated_comment)
  end

  defp parse_with_comments(<<>>, acc, _depth, _quotes) do
    Binary.strip(:erlang.list_to_binary(:lists.reverse(acc)))
  end

  defp parse_with_comments(<<92, h, tail::binary>>, acc, depth, quotes)
       when depth > 0 and h > 32 and h < 127 do
    parse_with_comments(tail, acc, depth, quotes)
  end

  defp parse_with_comments(<<92, tail::binary>>, acc, depth, quotes) when depth > 0 do
    parse_with_comments(tail, acc, depth, quotes)
  end

  defp parse_with_comments(<<92, h, tail::binary>>, acc, depth, quotes) when h > 32 and h < 127 do
    parse_with_comments(tail, [h | acc], depth, quotes)
  end

  defp parse_with_comments(<<92, tail::binary>>, acc, depth, quotes) do
    parse_with_comments(tail, [92 | acc], depth, quotes)
  end

  defp parse_with_comments(<<40, tail::binary>>, acc, depth, quotes) when not quotes do
    parse_with_comments(tail, acc, depth + 1, quotes)
  end

  defp parse_with_comments(<<41, tail::binary>>, acc, depth, quotes)
       when depth > 0 and not quotes do
    parse_with_comments(tail, acc, depth - 1, quotes)
  end

  defp parse_with_comments(<<_, tail::binary>>, acc, depth, quotes) when depth > 0 do
    parse_with_comments(tail, acc, depth, quotes)
  end

  defp parse_with_comments(<<34, t::binary>>, acc, depth, true) do
    parse_with_comments(t, acc, depth, false)
  end

  defp parse_with_comments(<<34, t::binary>>, acc, depth, false) do
    parse_with_comments(t, acc, depth, true)
  end

  defp parse_with_comments(<<h, tail::binary>>, acc, depth, quotes) do
    parse_with_comments(tail, [h | acc], depth, quotes)
  end

  @spec parse_content_type(:undefined) :: :undefined
  @spec parse_content_type(binary()) :: {binary(), binary(), list({binary(), binary()})}
  defp parse_content_type(:undefined) do
    :undefined
  end

  defp parse_content_type(string) do
    parse_content_disposition(string)
  catch
    :throw, :bad_disposition -> throw(:bad_content_type)
  else
    {raw_type, parameters} ->
      case Binary.strchr(raw_type, 47) do
        index when index < 2 ->
          throw(:bad_content_type)

        index ->
          type = Binary.substr(raw_type, 1, index - 1)
          sub_type = Binary.substr(raw_type, index + 1)

          {Binary.to_lower(type), Binary.to_lower(sub_type), parameters}
      end
  end

  @spec parse_content_disposition(:undefined) :: :undefined
  @spec parse_content_disposition(binary()) :: {binary(), list({binary(), binary()})}
  defp parse_content_disposition(:undefined) do
    :undefined
  end

  defp parse_content_disposition(string) do
    [disposition | parameters] = Binary.split(parse_with_comments(string), ";")

    f = fn x ->
      y = Binary.strip(Binary.strip(x), :both, 9)

      case Binary.strchr(y, 61) do
        index when index < 2 ->
          throw(:bad_disposition)

        index ->
          key = Binary.substr(y, 1, index - 1)
          value = Binary.substr(y, index + 1)
          {Binary.to_lower(key), value}
      end
    end

    params = :lists.map(f, parameters)
    {Binary.to_lower(disposition), params}
  end

  @spec split_body_by_boundary(binary(), binary(), binary(), options()) :: [mimetuple()]
  defp split_body_by_boundary(body, boundary, mime_vsn, options) do
    case {Binary.strpos(body, boundary),
          Binary.strpos(body, :erlang.list_to_binary([boundary, ~c"--"]))} do
      {0, _} ->
        :erlang.error(:missing_boundary)

      {_, 0} ->
        :erlang.error(:missing_last_boundary)

      {start, var_end} ->
        new_body = Binary.substr(body, start + byte_size(boundary), var_end - start)

        parts =
          split_body_by_boundary_(
            new_body,
            :erlang.list_to_binary([~c"\r\n", boundary]),
            [],
            options
          )

        for {headers, body} <- parts,
            body != "",
            do: decode_component(headers, body, mime_vsn, options)
    end
  end

  @spec split_body_by_boundary_(binary(), binary(), [{headers(), binary()}], options()) :: [
          {headers(), binary()}
        ]
  defp split_body_by_boundary_(<<>>, _boundary, acc, _options) do
    :lists.reverse(acc)
  end

  defp split_body_by_boundary_(body, boundary, acc, options) do
    trimmed_body =
      Binary.substr(body, Binary.strpos(body, ~c"\r\n") + 2)

    case Binary.strpos(trimmed_body, boundary) do
      0 ->
        :lists.reverse([{[], trimmed_body} | acc])

      index ->
        {parsed_hdrs, body_rest} =
          parse_headers(Binary.substr(trimmed_body, 1, index - 1))

        decoded_hdrs =
          decode_headers(parsed_hdrs, [], :proplists.get_value(:encoding, options, :none))

        split_body_by_boundary_(
          Binary.substr(trimmed_body, index + byte_size(boundary)),
          boundary,
          [{decoded_hdrs, body_rest} | acc],
          options
        )
    end
  end

  @spec parse_headers(binary()) :: {list({binary(), binary()}), binary()}
  @doc false
  def parse_headers(body) do
    case Binary.strpos(body, ~c"\r\n") do
      0 ->
        {[], body}

      1 ->
        {[], Binary.substr(body, 3)}

      index ->
        parse_headers(
          Binary.substr(body, index + 2),
          Binary.substr(body, 1, index - 1),
          []
        )
    end
  end

  @spec parse_headers(binary(), binary(), headers()) :: {headers(), binary()}
  defp parse_headers(body, <<h, tail::binary>>, []) when h === 32 or h === 9 do
    {[], :erlang.list_to_binary([h, tail, ~c"\r\n", body])}
  end

  defp parse_headers(body, <<h, tail::binary>>, [{name, value} | headers]) when h in [?\s, ?\t] do
    continue_headers(body, [{name, value <> tail} | headers])
  end

  defp parse_headers(body, line, headers) do
    case :binary.split(line, ":") do
      [name, value] ->
        if Binary.all(&(&1 > 32 and &1 < 127), name) do
          continue_headers(body, [{name, clean_header_value(value)} | headers])
        else
          {Enum.reverse(headers), line <> "\r\n" <> body}
        end

      [_line] ->
        {Enum.reverse(headers), line <> "\r\n" <> body}
    end
  end

  @spec continue_headers(binary(), headers()) :: {headers(), binary()}
  defp continue_headers(body, headers) do
    case Binary.strpos(body, "\r\n") do
      0 ->
        {Enum.reverse(headers), body}

      1 ->
        {Enum.reverse(headers), Binary.substr(body, 3)}

      index ->
        parse_headers(Binary.substr(body, index + 2), Binary.substr(body, 1, index - 1), headers)
    end
  end

  @spec clean_header_value(binary()) :: binary()
  defp clean_header_value(value) do
    value = Binary.strip(value)

    if Binary.all(&(&1 in 32..126 or &1 == ?\t), value) do
      value
    else
      for <<c <- value>>, into: <<>>, do: filter_non_ascii(c)
    end
  end

  @spec filter_non_ascii(byte()) :: binary()
  defp filter_non_ascii(c) when (c > 31 and c < 127) or c == 9 do
    <<c>>
  end

  defp filter_non_ascii(_c) do
    "?"
  end

  @spec decode_body(
          binary() | :undefined,
          binary(),
          binary() | :undefined,
          binary() | :raw | :none
        ) :: binary()
  defp decode_body(type, body, _in_encoding, :raw), do: decode_body(type, body)

  defp decode_body(type, body, _in_encoding, :none) do
    decode_body(type, for(<<x <- body>>, x < 128, into: <<>>, do: <<x::integer>>))
  end

  defp decode_body(type, body, :undefined, _out_encoding) do
    decode_body(type, for(<<x <- body>>, x < 128, into: <<>>, do: <<x::integer>>))
  end

  defp decode_body(type, body, "x-binaryenc", _out_encoding) do
    decode_body(type, body)
  end

  defp decode_body(type, body, in_encoding, out_encoding) do
    new_body = decode_body(type, body)
    in_encoding_fixed = fix_encoding(in_encoding)
    {:ok, converted_body} = convert(out_encoding, in_encoding_fixed, new_body)
    converted_body
  end

  @spec decode_body(binary() | :undefined, binary()) :: binary()
  defp decode_body(:undefined, body) do
    body
  end

  defp decode_body(type, body) do
    case Binary.to_lower(type) do
      "quoted-printable" -> TransferEncoding.decode_quoted_printable(body)
      "base64" -> TransferEncoding.decode_base64(body)
      _other -> body
    end
  end

  @spec check_headers(headers()) :: headers()
  defp check_headers(headers) do
    checked = ["MIME-Version", "Date", "From", "Message-ID", "References", "Subject"]
    check_headers(checked, :lists.reverse(headers))
  end

  @spec check_headers([binary()], headers()) :: headers()
  defp check_headers([], headers) do
    :lists.reverse(headers)
  end

  defp check_headers([header | tail], headers) do
    headers = ensure_header(header, get_header_value(header, headers), headers)
    check_headers(tail, headers)
  end

  @spec ensure_header(binary(), binary() | :undefined, headers()) :: headers()
  defp ensure_header("MIME-Version", :undefined, headers), do: [{"MIME-Version", "1.0"} | headers]

  defp ensure_header("Date", :undefined, headers),
    do: [{"Date", IO.iodata_to_binary(Util.rfc5322_timestamp())} | headers]

  defp ensure_header("From", :undefined, _headers), do: :erlang.error(:missing_from)

  defp ensure_header("Message-ID", :undefined, headers),
    do: [{"Message-ID", IO.iodata_to_binary(Util.generate_message_id())} | headers]

  defp ensure_header("References", references, headers) do
    ensure_references(references, get_header_value("In-Reply-To", headers), headers)
  end

  defp ensure_header(_name, _value, headers), do: headers

  @spec ensure_references(binary() | :undefined, binary() | :undefined, headers()) :: headers()
  defp ensure_references(_references, :undefined, headers), do: headers
  defp ensure_references(:undefined, reply_id, headers), do: [{"References", reply_id} | headers]

  defp ensure_references(references, reply_id, headers) do
    if Binary.strpos(Binary.to_lower(references), Binary.to_lower(reply_id)) == 0 do
      [{"References", references <> " " <> reply_id} | :proplists.delete("References", headers)]
    else
      headers
    end
  end

  @spec ensure_content_headers(
          binary(),
          binary(),
          parameters(),
          headers(),
          binary() | mimetuple() | [mimetuple()],
          boolean()
        ) :: {parameters(), headers()}
  defp ensure_content_headers(type, sub_type, parameters, headers, body, toplevel) do
    check_headers = ["Content-Type", "Content-Disposition", "Content-Transfer-Encoding"]

    check_headers_values =
      for name <- check_headers, into: [], do: {name, get_header_value(name, headers)}

    ensure_content_headers(
      check_headers_values,
      type,
      sub_type,
      parameters,
      :lists.reverse(headers),
      body,
      toplevel
    )
  end

  @spec ensure_content_headers(
          [{binary(), binary() | :undefined}],
          binary(),
          binary(),
          parameters(),
          headers(),
          binary() | mimetuple() | [mimetuple()],
          boolean()
        ) :: {parameters(), headers()}
  defp ensure_content_headers([], _, _, parameters, headers, _, _) do
    {parameters, :lists.reverse(headers)}
  end

  defp ensure_content_headers(
         [{"Content-Type", :undefined} | tail],
         type,
         sub_type,
         parameters,
         headers,
         body,
         toplevel
       )
       when (type == "text" and sub_type !== "plain") or type !== "text" do
    c_t = :io_lib.format(~c"~s/~s", [type, sub_type])

    c_tp = content_type_parameters(type, parameters, body)

    c_th =
      Binary.join(
        [c_t | Parameters.encode_parameters(c_tp)],
        ~c";"
      )

    new_parameters = Map.merge(parameters, %{content_type_params: c_tp})

    ensure_content_headers(
      tail,
      type,
      sub_type,
      new_parameters,
      [{"Content-Type", c_th} | headers],
      body,
      toplevel
    )
  end

  defp ensure_content_headers(
         [{"Content-Type", :undefined} | tail],
         "text" = type,
         "plain" = sub_type,
         parameters,
         headers,
         body,
         toplevel
       ) do
    charset =
      case :proplists.get_value("charset", :maps.get(:content_type_params, parameters, [])) do
        :undefined -> guess_charset(body)
        c -> Binary.to_lower(c)
      end

    case charset do
      "us-ascii" ->
        ensure_content_headers(tail, type, sub_type, parameters, headers, body, toplevel)

      _ ->
        c_tp = [
          {"charset", charset}
          | :proplists.delete("charset", :maps.get(:content_type_params, parameters, []))
        ]

        c_th =
          Binary.join(
            ["text/plain" | Parameters.encode_parameters(c_tp)],
            ~c";"
          )

        new_parameters = Map.merge(parameters, %{content_type_params: c_tp})

        ensure_content_headers(
          tail,
          type,
          sub_type,
          new_parameters,
          [{"Content-Type", c_th} | headers],
          body,
          toplevel
        )
    end
  end

  defp ensure_content_headers(
         [{"Content-Transfer-Encoding", :undefined} | tail],
         type,
         sub_type,
         parameters,
         headers,
         body,
         toplevel
       )
       when type !== "multipart" do
    enc =
      case :maps.get(:transfer_encoding, parameters, :undefined) do
        :undefined -> guess_best_encoding(body)
        value -> value
      end

    case enc do
      "7bit" ->
        ensure_content_headers(tail, type, sub_type, parameters, headers, body, toplevel)

      _ ->
        ensure_content_headers(
          tail,
          type,
          sub_type,
          parameters,
          [{"Content-Transfer-Encoding", enc} | headers],
          body,
          toplevel
        )
    end
  end

  defp ensure_content_headers(
         [{"Content-Disposition", :undefined} | tail],
         type,
         sub_type,
         parameters,
         headers,
         body,
         false = toplevel
       ) do
    c_d = :maps.get(:disposition, parameters, "inline")
    c_dp = :maps.get(:disposition_params, parameters, [])

    c_dh =
      Binary.join(
        [c_d | Parameters.encode_parameters(c_dp)],
        ~c";"
      )

    ensure_content_headers(
      tail,
      type,
      sub_type,
      parameters,
      [{"Content-Disposition", c_dh} | headers],
      body,
      toplevel
    )
  end

  defp ensure_content_headers([_ | tail], type, sub_type, parameters, headers, body, toplevel) do
    ensure_content_headers(tail, type, sub_type, parameters, headers, body, toplevel)
  end

  @spec content_type_parameters(binary(), parameters(), binary() | list()) :: headers()
  defp content_type_parameters(type, parameters, body) do
    case type do
      "multipart" ->
        boundary =
          case :proplists.get_value("boundary", :maps.get(:content_type_params, parameters, [])) do
            :undefined -> :erlang.list_to_binary(Util.generate_message_boundary())
            b -> b
          end

        [
          {"boundary", boundary}
          | :proplists.delete("boundary", :maps.get(:content_type_params, parameters, []))
        ]

      "text" ->
        charset =
          case :proplists.get_value("charset", :maps.get(:content_type_params, parameters, [])) do
            :undefined -> guess_charset(body)
            c -> c
          end

        [
          {"charset", charset}
          | :proplists.delete("charset", :maps.get(:content_type_params, parameters, []))
        ]

      _ ->
        :maps.get(:content_type_params, parameters, [])
    end
  end

  @spec guess_charset(binary()) :: binary()
  defp guess_charset(body) do
    case Binary.all(fn x -> x < 128 end, body) do
      true -> "us-ascii"
      false -> "utf-8"
    end
  end

  @spec guess_best_encoding(binary()) :: binary()
  defp guess_best_encoding(body) do
    case valid_7bit?(body) do
      true -> "7bit"
      false -> choose_transformation(body)
    end
  end

  @spec choose_transformation(binary()) :: binary()
  defp choose_transformation(<<chunk::size(200)-binary, _, _::binary>>) do
    choose_transformation(chunk)
  end

  defp choose_transformation(body) do
    {readable, encoded} =
      Binary.partition_count_bytes(
        fn c -> (c >= 32 and c <= 126) or (c === 13 or c === 10) end,
        body
      )

    if readable >= 4 * encoded, do: "quoted-printable", else: "base64"
  end

  @spec valid_7bit?(binary()) :: boolean()
  defp valid_7bit?("\n") do
    false
  end

  defp valid_7bit?("\r") do
    false
  end

  defp valid_7bit?(<<>>) do
    true
  end

  defp valid_7bit?(<<_>>) do
    true
  end

  defp valid_7bit?(body) do
    size = byte_size(body)

    case :binary.at(body, size - 1) === 10 and :binary.at(body, size - 2) !== 13 do
      true ->
        false

      false ->
        case :re.run(
               body,
               [
                 94,
                 40,
                 91,
                 1,
                 45,
                 9,
                 11,
                 45,
                 12,
                 14,
                 45,
                 127,
                 93,
                 124,
                 40,
                 13,
                 10,
                 41,
                 41,
                 42,
                 36
               ],
               capture: :none
             ) do
          :match -> not has_lines_over_998?(body)
          :nomatch -> false
        end
    end
  end

  @spec has_lines_over_998?(binary()) :: boolean()
  defp has_lines_over_998?(body) do
    pattern = :binary.compile_pattern("\r\n")
    has_lines_over_998?(body, :binary.match(body, pattern), 0, pattern)
  end

  @spec has_lines_over_998?(
          binary(),
          :nomatch | {non_neg_integer(), non_neg_integer()},
          non_neg_integer(),
          :binary.cp()
        ) :: boolean()
  defp has_lines_over_998?(bin, :nomatch, offset, _) do
    byte_size(bin) - offset >= 998
  end

  defp has_lines_over_998?(_bin, {found_at, 2}, offset, _patern) when found_at - offset >= 998 do
    true
  end

  defp has_lines_over_998?(bin, {found_at, 2}, _, pattern) do
    new_offset = found_at + 2
    len = byte_size(bin) - new_offset

    has_lines_over_998?(
      bin,
      :binary.match(bin, pattern, scope: {new_offset, len}),
      new_offset,
      pattern
    )
  end

  @doc false
  @spec encode_headers(headers()) :: [binary()]
  def encode_headers([]) do
    []
  end

  def encode_headers([{key, value} | t] = _headers) do
    encoded_header =
      maybe_encode_folded_header(
        key,
        :erlang.list_to_binary([key, ~c": ", encode_header_value(key, value)])
      )

    [encoded_header | encode_headers(t)]
  end

  @spec maybe_encode_folded_header(binary(), binary()) :: binary()
  defp maybe_encode_folded_header(h, hdr)
       when h === "To" or h === "Cc" or h === "Bcc" or h === "Reply-To" or h === "From" do
    hdr
  end

  defp maybe_encode_folded_header(_h, hdr) do
    encode_folded_header(hdr, <<>>)
  end

  @spec encode_folded_header(binary(), binary()) :: binary()
  defp encode_folded_header(rest, acc) do
    case Binary.split(rest, <<59>>, 2) do
      [_] ->
        <<acc::binary, rest::binary>>

      [before, var_after] ->
        new_part =
          case var_after do
            <<9, _rest::binary>> -> <<before::binary, ";\r\n">>
            _ -> <<before::binary, ";\r\n\t">>
          end

        encode_folded_header(var_after, <<acc::binary, new_part::binary>>)
    end
  end

  @spec encode_header_value(binary(), binary()) :: binary()
  defp encode_header_value(h, value)
       when h === "To" or h === "Cc" or h === "Bcc" or h === "Reply-To" or h === "From" do
    {:ok, addresses} = Util.parse_rfc5322_addresses(value)
    {names, emails} = :lists.unzip(addresses)

    new_names =
      :lists.map(
        fn
          :undefined ->
            :undefined

          name ->
            EncodedWord.rfc2047_utf8_encode(:unicode.characters_to_binary(name))
        end,
        names
      )

    Util.combine_rfc822_addresses(:lists.zip(new_names, emails))
  end

  defp encode_header_value(h, value) when h === "Content-Type" or h === "Content-Disposition" do
    value
  end

  defp encode_header_value(_, value) do
    EncodedWord.rfc2047_utf8_encode(value)
  end

  @spec encode_component(
          binary(),
          binary(),
          headers(),
          parameters(),
          binary() | mimetuple() | [mimetuple()]
        ) :: iodata()
  defp encode_component(_type, _sub_type, _headers, params, body) when is_list(body) do
    boundary = :proplists.get_value("boundary", :maps.get(:content_type_params, params))

    [<<>>] ++
      :lists.flatmap(
        fn part -> [:erlang.list_to_binary(["--", boundary])] ++ encode_component_part(part) end,
        body
      ) ++ [:erlang.list_to_binary(["--", boundary, "--"])] ++ [<<>>]
  end

  defp encode_component(_type, _sub_type, headers, _params, body) do
    TransferEncoding.encode_body(
      get_header_value("Content-Transfer-Encoding", headers),
      [body]
    )
  end

  @spec encode_component_part(mimetuple()) :: iodata()
  defp encode_component_part({"multipart", sub_type, headers, part_params, body}) do
    {fixed_params, fixed_headers} =
      ensure_content_headers("multipart", sub_type, part_params, headers, body, false)

    encode_headers(fixed_headers) ++
      encode_component("multipart", sub_type, fixed_headers, fixed_params, body)
  end

  defp encode_component_part({type, sub_type, headers, part_params, body}) do
    part_data =
      case body do
        {_, _, _, _, _} -> encode_component_part(body)
        string -> [string]
      end

    {_fixed_params, fixed_headers} =
      ensure_content_headers(type, sub_type, part_params, headers, body, false)

    encode_headers(fixed_headers) ++
      [<<>>] ++
      TransferEncoding.encode_body(
        get_header_value("Content-Transfer-Encoding", fixed_headers),
        part_data
      )
  end

  defp encode_component_part(_part) do
    []
  end

  @spec get_default_encoding() :: binary() | :raw
  defp get_default_encoding do
    if Code.ensure_loaded?(:iconv), do: "utf-8//IGNORE", else: :raw
  end

  @spec fix_encoding(binary() | :undefined) :: binary() | :undefined
  defp fix_encoding(encoding) when encoding == "utf8" or encoding == "UTF8" do
    "UTF-8"
  end

  defp fix_encoding(encoding) do
    encoding
  end

  @doc "Decodes a quoted-printable body into its original bytes."
  @spec decode_quoted_printable(binary()) :: binary()
  defdelegate decode_quoted_printable(body), to: TransferEncoding

  @doc "Encodes a quoted-printable body with SMTP-compatible line wrapping."
  @spec encode_quoted_printable(binary()) :: [binary()]
  defdelegate encode_quoted_printable(body), to: TransferEncoding
end
