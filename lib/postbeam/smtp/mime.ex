# Preserve the imported SMTP callback API and protocol branch structure.
# credo:disable-for-this-file Credo.Check.Readability.PredicateFunctionNames
# credo:disable-for-this-file Credo.Check.Refactor.CyclomaticComplexity
# credo:disable-for-this-file Credo.Check.Refactor.Nesting
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
  def decode(all, options) when is_binary(all) and is_list(options) do
    {headers, body} = parse_headers(all)
    decode(headers, body, options)
  end

  defp decode(orig_headers, body, options) do
    Postbeam.SMTP.Log.debug(~c"headers: ~p", [orig_headers], %{domain: [:postbeam]})
    encoding = :proplists.get_value(:encoding, options, :none)
    headers = decode_headers(orig_headers, [], encoding)

    case parse_with_comments(get_header_value("MIME-Version", headers)) do
      :undefined ->
        allow_missing_version = :proplists.get_value(:allow_missing_version, options, false)

        case parse_content_type(get_header_value("Content-Type", headers)) do
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

      other ->
        decode_component(headers, body, other, options)
    end
  end

  @spec encode(mimetuple()) :: binary()
  def encode(mime_mail) do
    encode(mime_mail, [])
  end

  def encode({type, subtype, headers, content_type_params, parts}, options) do
    {fixed_params, fixed_headers} =
      ensure_content_headers(type, subtype, content_type_params, headers, parts, true)

    checked_headers = check_headers(fixed_headers)

    encoded_body =
      Postbeam.SMTP.Binary.join(
        encode_component(type, subtype, checked_headers, fixed_params, parts),
        ~c"\r\n"
      )

    encoded_headers = encode_headers(checked_headers)

    signed_headers =
      case :proplists.get_value(:dkim, options) do
        :undefined -> encoded_headers
        dkim_options -> Postbeam.SMTP.DKIM.sign(encoded_headers, encoded_body, dkim_options)
      end

    :erlang.list_to_binary([
      Postbeam.SMTP.Binary.join(signed_headers, ~c"\r\n"),
      ~c"\r\n\r\n",
      encoded_body
    ])
  end

  def encode(_, _) do
    Postbeam.SMTP.Log.debug(~c"Not a mime-decoded DATA", %{domain: [:postbeam]})
    :erlang.error(:non_mime)
  end

  defp decode_headers(headers, _, encoding) when encoding in [:none, :raw] do
    headers
  end

  defp decode_headers([], acc, _charset) do
    :lists.reverse(acc)
  end

  defp decode_headers([{key, value} | headers], acc, charset) do
    decode_headers(headers, [{key, decode_header(value, charset)} | acc], charset)
  end

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
        encoding = Postbeam.SMTP.Binary.substr(value, encoding_start + 1, encoding_len)

        type =
          Postbeam.SMTP.Binary.to_lower(Postbeam.SMTP.Binary.substr(value, type_start + 1, 1))

        data = Postbeam.SMTP.Binary.substr(value, data_start + 1, data_len)

        encoded_data =
          case type do
            "q" -> decode_quoted_printable(:binary.replace(data, "_", "=20", [:global]))
            "b" -> decode_base64(:binary.replace(data, "_", " ", [:global]))
          end

        offset =
          case :re.run(
                 Postbeam.SMTP.Binary.substr(value, all_start + all_len + 1),
                 ~c"^([ \t\n\r]+)=\\?[-A-Za-z0-9_]+\\?[^ ]\\?[^ ]+\\?=",
                 [:ungreedy]
               ) do
            :nomatch -> 1
            {:match, [{_, _}, {_, white_space_len}]} -> 1 + white_space_len
          end

        new_acc =
          case Postbeam.SMTP.Binary.substr(value, 1, all_start) do
            <<>> -> [{fix_encoding(encoding), encoded_data} | acc]
            other -> [{fix_encoding(encoding), encoded_data}, other | acc]
          end

        tokenize_header(Postbeam.SMTP.Binary.substr(value, all_start + all_len + offset), new_acc)
    end
  end

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

  defp convert(_to, "x-binaryenc", data) do
    {:ok, data}
  end

  defp convert(to, from, data) do
    result = :iconv.convert(from, to, data)
    {:ok, result}
  end

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
            Postbeam.SMTP.Log.debug(
              ~c"this is a multipart email of type:  ~s and boundary ~s",
              [sub_type, boundary],
              %{domain: [:postbeam]}
            )

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
        Postbeam.SMTP.Log.debug(~c"body is ~s/~s", [type, sub_type], %{domain: [:postbeam]})

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
  def get_header_value(needle, headers, default) do
    Postbeam.SMTP.Log.debug(~c"Headers: ~p", [headers], %{domain: [:postbeam]})
    needle_lower = Postbeam.SMTP.Binary.to_lower(needle)
    f = fn {header, _value} -> Postbeam.SMTP.Binary.to_lower(header) === needle_lower end

    case :lists.search(f, headers) do
      {:value, {_header, value}} -> value
      false -> default
    end
  end

  @spec get_header_value(binary(), list({binary(), binary()})) :: binary() | :undefined
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
    Postbeam.SMTP.Binary.strip(:erlang.list_to_binary(:lists.reverse(acc)))
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
    try do
      parse_content_disposition(string)
    catch
      :throw, :bad_disposition -> throw(:bad_content_type)
    else
      {raw_type, parameters} ->
        case Postbeam.SMTP.Binary.strchr(raw_type, 47) do
          index when index < 2 ->
            throw(:bad_content_type)

          index ->
            type = Postbeam.SMTP.Binary.substr(raw_type, 1, index - 1)
            sub_type = Postbeam.SMTP.Binary.substr(raw_type, index + 1)

            {Postbeam.SMTP.Binary.to_lower(type), Postbeam.SMTP.Binary.to_lower(sub_type),
             parameters}
        end
    end
  end

  @spec parse_content_disposition(:undefined) :: :undefined
  @spec parse_content_disposition(binary()) :: {binary(), list({binary(), binary()})}
  defp parse_content_disposition(:undefined) do
    :undefined
  end

  defp parse_content_disposition(string) do
    [disposition | parameters] = Postbeam.SMTP.Binary.split(parse_with_comments(string), ";")

    f = fn x ->
      y = Postbeam.SMTP.Binary.strip(Postbeam.SMTP.Binary.strip(x), :both, 9)

      case Postbeam.SMTP.Binary.strchr(y, 61) do
        index when index < 2 ->
          throw(:bad_disposition)

        index ->
          key = Postbeam.SMTP.Binary.substr(y, 1, index - 1)
          value = Postbeam.SMTP.Binary.substr(y, index + 1)
          {Postbeam.SMTP.Binary.to_lower(key), value}
      end
    end

    params = :lists.map(f, parameters)
    {Postbeam.SMTP.Binary.to_lower(disposition), params}
  end

  defp split_body_by_boundary(body, boundary, mime_vsn, options) do
    case {Postbeam.SMTP.Binary.strpos(body, boundary),
          Postbeam.SMTP.Binary.strpos(body, :erlang.list_to_binary([boundary, ~c"--"]))} do
      {0, _} ->
        :erlang.error(:missing_boundary)

      {_, 0} ->
        :erlang.error(:missing_last_boundary)

      {start, var_end} ->
        new_body = Postbeam.SMTP.Binary.substr(body, start + byte_size(boundary), var_end - start)

        parts =
          split_body_by_boundary_(
            new_body,
            :erlang.list_to_binary([~c"\r\n", boundary]),
            [],
            options
          )

        for {headers, body2} <-
              for({_, body3} = v <- parts, byte_size(body3) !== 0, into: [], do: v),
            into: [],
            do: decode_component(headers, body2, mime_vsn, options)
    end
  end

  defp split_body_by_boundary_(<<>>, _boundary, acc, _options) do
    :lists.reverse(acc)
  end

  defp split_body_by_boundary_(body, boundary, acc, options) do
    trimmed_body =
      Postbeam.SMTP.Binary.substr(body, Postbeam.SMTP.Binary.strpos(body, ~c"\r\n") + 2)

    case Postbeam.SMTP.Binary.strpos(trimmed_body, boundary) do
      0 ->
        :lists.reverse([{[], trimmed_body} | acc])

      index ->
        {parsed_hdrs, body_rest} =
          parse_headers(Postbeam.SMTP.Binary.substr(trimmed_body, 1, index - 1))

        decoded_hdrs =
          decode_headers(parsed_hdrs, [], :proplists.get_value(:encoding, options, :none))

        split_body_by_boundary_(
          Postbeam.SMTP.Binary.substr(trimmed_body, index + byte_size(boundary)),
          boundary,
          [{decoded_hdrs, body_rest} | acc],
          options
        )
    end
  end

  @spec parse_headers(binary()) :: {list({binary(), binary()}), binary()}
  def parse_headers(body) do
    case Postbeam.SMTP.Binary.strpos(body, ~c"\r\n") do
      0 ->
        {[], body}

      1 ->
        {[], Postbeam.SMTP.Binary.substr(body, 3)}

      index ->
        parse_headers(
          Postbeam.SMTP.Binary.substr(body, index + 2),
          Postbeam.SMTP.Binary.substr(body, 1, index - 1),
          []
        )
    end
  end

  defp parse_headers(body, <<h, tail::binary>>, []) when h === 32 or h === 9 do
    {[], :erlang.list_to_binary([h, tail, ~c"\r\n", body])}
  end

  defp parse_headers(body, <<h, t::binary>>, headers) when h === 32 or h === 9 do
    [{field_name, old_field_value} | other_headers] = headers
    field_value = :erlang.list_to_binary([old_field_value, t])
    Postbeam.SMTP.Log.debug(~c"~p = ~p", [field_name, field_value], %{domain: [:postbeam]})

    case Postbeam.SMTP.Binary.strpos(body, ~c"\r\n") do
      0 ->
        {:lists.reverse([{field_name, field_value} | other_headers]), body}

      1 ->
        {:lists.reverse([{field_name, field_value} | other_headers]),
         Postbeam.SMTP.Binary.substr(body, 3)}

      index2 ->
        parse_headers(
          Postbeam.SMTP.Binary.substr(body, index2 + 2),
          Postbeam.SMTP.Binary.substr(body, 1, index2 - 1),
          [{field_name, field_value} | other_headers]
        )
    end
  end

  defp parse_headers(body, line, headers) do
    Postbeam.SMTP.Log.debug(~c"line: ~p", [line], %{domain: [:postbeam]})

    case Postbeam.SMTP.Binary.strchr(line, 58) do
      0 ->
        {:lists.reverse(headers), :erlang.list_to_binary([line, ~c"\r\n", body])}

      index ->
        field_name = Postbeam.SMTP.Binary.substr(line, 1, index - 1)
        f = fn x -> x > 32 and x < 127 end

        case Postbeam.SMTP.Binary.all(f, field_name) do
          true ->
            f2 = fn x -> (x > 31 and x < 127) or x == 9 end
            f_value = Postbeam.SMTP.Binary.strip(Postbeam.SMTP.Binary.substr(line, index + 1))

            field_value =
              case Postbeam.SMTP.Binary.all(f2, f_value) do
                true ->
                  f_value

                _ ->
                  :erlang.list_to_binary(
                    for <<c::8 <- f_value>>, into: [], do: filter_non_ascii(c)
                  )
              end

            case Postbeam.SMTP.Binary.strpos(body, ~c"\r\n") do
              0 ->
                {:lists.reverse([{field_name, field_value} | headers]), body}

              1 ->
                {:lists.reverse([{field_name, field_value} | headers]),
                 Postbeam.SMTP.Binary.substr(body, 3)}

              index2 ->
                parse_headers(
                  Postbeam.SMTP.Binary.substr(body, index2 + 2),
                  Postbeam.SMTP.Binary.substr(body, 1, index2 - 1),
                  [{field_name, field_value} | headers]
                )
            end

          false ->
            {:lists.reverse(headers), :erlang.list_to_binary([line, ~c"\r\n", body])}
        end
    end
  end

  defp filter_non_ascii(c) when (c > 31 and c < 127) or c == 9 do
    <<c>>
  end

  defp filter_non_ascii(_c) do
    "?"
  end

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
    case Postbeam.SMTP.Binary.to_lower(type) do
      "quoted-printable" -> decode_quoted_printable(body)
      "base64" -> decode_base64(body)
      _other -> body
    end
  end

  defp decode_base64(body) do
    :base64.mime_decode(body)
  end

  def decode_quoted_printable(body) do
    decode_quoted_printable(body, false, <<>>, <<>>)
  end

  defp decode_quoted_printable(<<>>, _has_soft_eol, _w_s_ps, acc) do
    acc
  end

  defp decode_quoted_printable(<<13, 10, more::binary>>, true, _w_s_ps, acc) do
    decode_quoted_printable(more, false, <<>>, acc)
  end

  defp decode_quoted_printable(<<c, more::binary>>, true, _w_s_ps, acc)
       when c === 32 or c === 9 do
    decode_quoted_printable(more, true, <<>>, acc)
  end

  defp decode_quoted_printable(_body, true, _w_s_ps, _acc) do
    throw(:badchar)
  end

  defp decode_quoted_printable(<<13, 10, more::binary>>, false, _w_s_ps, acc) do
    decode_quoted_printable(more, false, <<>>, <<acc::binary, 13, 10>>)
  end

  defp decode_quoted_printable(<<c, more::binary>>, false, w_s_ps, acc)
       when c === 32 or c === 9 do
    decode_quoted_printable(more, false, <<w_s_ps::binary, c>>, acc)
  end

  defp decode_quoted_printable(<<61, c1, c2, more::binary>>, false, w_s_ps, acc)
       when ((c1 >= 48 and c1 <= 57) or ((c1 >= 65 and c1 <= 70) or (c1 >= 97 and c1 <= 102))) and
              ((c2 >= 48 and c2 <= 57) or ((c2 >= 65 and c2 <= 70) or (c2 >= 97 and c2 <= 102))) do
    decode_quoted_printable(
      more,
      false,
      <<>>,
      <<acc::binary, w_s_ps::binary, unhex(c1)::4, unhex(c2)::4>>
    )
  end

  defp decode_quoted_printable(<<61, more::binary>>, false, w_s_ps, acc) do
    decode_quoted_printable(more, true, <<>>, <<acc::binary, w_s_ps::binary>>)
  end

  defp decode_quoted_printable(<<c, more::binary>>, false, w_s_ps, acc) do
    decode_quoted_printable(more, false, <<>>, <<acc::binary, w_s_ps::binary, c>>)
  end

  defp check_headers(headers) do
    checked = ["MIME-Version", "Date", "From", "Message-ID", "References", "Subject"]
    check_headers(checked, :lists.reverse(headers))
  end

  defp check_headers([], headers) do
    :lists.reverse(headers)
  end

  defp check_headers([header | tail], headers) do
    case get_header_value(header, headers) do
      :undefined when header == "MIME-Version" ->
        check_headers(tail, [{"MIME-Version", "1.0"} | headers])

      :undefined when header == "Date" ->
        check_headers(tail, [
          {"Date", :erlang.list_to_binary(Postbeam.SMTP.Util.rfc5322_timestamp())} | headers
        ])

      :undefined when header == "From" ->
        :erlang.error(:missing_from)

      :undefined when header == "Message-ID" ->
        check_headers(tail, [
          {"Message-ID", :erlang.list_to_binary(Postbeam.SMTP.Util.generate_message_id())}
          | headers
        ])

      :undefined when header == "References" ->
        case get_header_value("In-Reply-To", headers) do
          :undefined -> check_headers(tail, headers)
          reply_id -> check_headers(tail, [{"References", reply_id} | headers])
        end

      references when header == "References" ->
        case get_header_value("In-Reply-To", headers) do
          :undefined ->
            check_headers(tail, headers)

          reply_id ->
            case Postbeam.SMTP.Binary.strpos(
                   Postbeam.SMTP.Binary.to_lower(references),
                   Postbeam.SMTP.Binary.to_lower(reply_id)
                 ) do
              0 ->
                check_headers(tail, [
                  {"References", :erlang.list_to_binary([references, ~c" ", reply_id])}
                  | :proplists.delete("References", headers)
                ])

              _index ->
                check_headers(tail, headers)
            end
        end

      _ ->
        check_headers(tail, headers)
    end
  end

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

    c_tp =
      case type do
        "multipart" ->
          boundary =
            case :proplists.get_value("boundary", :maps.get(:content_type_params, parameters, [])) do
              :undefined -> :erlang.list_to_binary(Postbeam.SMTP.Util.generate_message_boundary())
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

    c_th = Postbeam.SMTP.Binary.join([c_t | encode_parameters(c_tp)], ~c";")
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
        c -> Postbeam.SMTP.Binary.to_lower(c)
      end

    case charset do
      "us-ascii" ->
        ensure_content_headers(tail, type, sub_type, parameters, headers, body, toplevel)

      _ ->
        c_tp = [
          {"charset", charset}
          | :proplists.delete("charset", :maps.get(:content_type_params, parameters, []))
        ]

        c_th = Postbeam.SMTP.Binary.join(["text/plain" | encode_parameters(c_tp)], ~c";")
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
    c_dh = Postbeam.SMTP.Binary.join([c_d | encode_parameters(c_dp)], ~c";")

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

  defp guess_charset(body) do
    case Postbeam.SMTP.Binary.all(fn x -> x < 128 end, body) do
      true -> "us-ascii"
      false -> "utf-8"
    end
  end

  defp guess_best_encoding(body) do
    case valid_7bit(body) do
      true -> "7bit"
      false -> choose_transformation(body)
    end
  end

  defp choose_transformation(<<chunk::size(200)-binary, _, _::binary>>) do
    choose_transformation(chunk)
  end

  defp choose_transformation(body) do
    {readable, encoded} =
      partition_count_bytes(fn c -> (c >= 32 and c <= 126) or (c === 13 or c === 10) end, body)

    if readable >= 4 * encoded, do: "quoted-printable", else: "base64"
  end

  defp valid_7bit("\n") do
    false
  end

  defp valid_7bit("\r") do
    false
  end

  defp valid_7bit(<<>>) do
    true
  end

  defp valid_7bit(<<_>>) do
    true
  end

  defp valid_7bit(body) do
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
          :match -> not has_lines_over_998(body)
          :nomatch -> false
        end
    end
  end

  defp has_lines_over_998(body) do
    pattern = :binary.compile_pattern("\r\n")
    has_lines_over_998(body, :binary.match(body, pattern), 0, pattern)
  end

  defp has_lines_over_998(bin, :nomatch, offset, _) do
    byte_size(bin) - offset >= 998
  end

  defp has_lines_over_998(_bin, {found_at, 2}, offset, _patern) when found_at - offset >= 998 do
    true
  end

  defp has_lines_over_998(bin, {found_at, 2}, _, pattern) do
    new_offset = found_at + 2
    len = byte_size(bin) - new_offset

    has_lines_over_998(
      bin,
      :binary.match(bin, pattern, scope: {new_offset, len}),
      new_offset,
      pattern
    )
  end

  @spec encode_parameters(list({binary(), binary()})) :: list(binary())
  defp encode_parameters([[]]) do
    []
  end

  defp encode_parameters(parameters) do
    :lists.foldr(
      fn {name, value}, acc ->
        {method, enc_len} = decide_param_encoding_method(value)
        enc_params = encode_parameter(method, name, value, enc_len)
        enc_params ++ acc
      end,
      [],
      parameters
    )
  end

  @spec encode_parameter(
          :plain | :quote | :encode | :encode_utf8,
          binary(),
          binary(),
          non_neg_integer()
        ) :: list(binary())
  defp encode_parameter(method, name, value, enc_len) do
    encode_parameter(method, name, 0, value, enc_len, [])
  end

  defp encode_parameter(_method, _name, _index, <<>>, _enc_len, acc) do
    :lists.reverse(acc)
  end

  defp encode_parameter(:encode_utf8, name, 0, value, enc_len, _acc)
       when byte_size(name) + 9 + enc_len <= 76 do
    {encoded, <<>>} = encode_param_value(:encode, value, 67 - byte_size(name))
    [<<name::binary, "*=UTF-8''", encoded::binary>>]
  end

  defp encode_parameter(:encode_utf8, name, 0, value, enc_len, acc) do
    {encoded, more} = encode_param_value(:encode, value, 65 - byte_size(name))

    encode_parameter(:encode, name, 1, more, enc_len, [
      <<name::binary, "*0*=UTF-8''", encoded::binary>> | acc
    ])
  end

  defp encode_parameter(:encode, name, 0, value, enc_len, _acc)
       when byte_size(name) + 4 + enc_len <= 76 do
    {encoded, <<>>} = encode_param_value(:encode, value, 72 - byte_size(name))
    [<<name::binary, "*=''", encoded::binary>>]
  end

  defp encode_parameter(:encode, name, 0, value, enc_len, acc) do
    prefix = <<name::binary, 42, 48, 42>>
    {encoded, more} = encode_param_value(:encode, value, 73 - byte_size(prefix))

    encode_parameter(:encode, name, 1, more, enc_len, [
      <<prefix::binary, "=''", encoded::binary>> | acc
    ])
  end

  defp encode_parameter(:encode, name, index, value, enc_len, acc) do
    prefix = <<name::binary, 42, :erlang.integer_to_binary(index)::binary, 42>>
    {encoded, more} = encode_param_value(:encode, value, 75 - byte_size(prefix))

    encode_parameter(:encode, name, index + 1, more, enc_len, [
      <<prefix::binary, "=", encoded::binary>> | acc
    ])
  end

  defp encode_parameter(:quote, name, 0, value, enc_len, _acc)
       when byte_size(name) + 2 + enc_len + 1 <= 76 do
    {quoted, <<>>} = encode_param_value(:quote, value, 73 - byte_size(name))
    [<<name::binary, 61, 34, quoted::binary, 34>>]
  end

  defp encode_parameter(:quote, name, index, value, enc_len, acc) do
    prefix = <<name::binary, 42, :erlang.integer_to_binary(index)::binary>>
    {quoted, more} = encode_param_value(:quote, value, 73 - byte_size(prefix))

    encode_parameter(:quote, name, index + 1, more, enc_len, [
      <<prefix::binary, 61, 34, quoted::binary, 34>> | acc
    ])
  end

  defp encode_parameter(:plain, name, 0, value, enc_len, _acc)
       when byte_size(name) + 1 + enc_len <= 76 do
    {plain, <<>>} = encode_param_value(:plain, value, 75 - byte_size(name))
    [<<name::binary, 61, plain::binary>>]
  end

  defp encode_parameter(:plain, name, index, value, enc_len, acc) do
    prefix = <<name::binary, 42, :erlang.integer_to_binary(index)::binary>>
    {plain, more} = encode_param_value(:plain, value, 75 - byte_size(prefix))

    encode_parameter(:plain, name, index + 1, more, enc_len, [
      <<prefix::binary, 61, plain::binary>> | acc
    ])
  end

  @spec encode_param_value(:plain | :quote | :encode, binary(), integer()) :: {binary(), binary()}
  defp encode_param_value(:plain, value, len) do
    len1 = max(len, 1)

    case value do
      <<part::size(^len1)-bytes, more::binary>> -> {part, more}
      _ -> {value, <<>>}
    end
  end

  defp encode_param_value(:quote, value, len) do
    encode_param_value_quote(value, len, <<>>)
  end

  defp encode_param_value(:encode, value, len) do
    encode_param_value_encode(value, len, <<>>)
  end

  defp encode_param_value_quote(<<>>, _len, acc) do
    {acc, <<>>}
  end

  defp encode_param_value_quote(<<c, more::binary>> = all, len, acc) do
    case c === 34 or c === 92 do
      true when len >= 2 or acc === <<>> ->
        encode_param_value_quote(more, len - 2, <<acc::binary, 92, c>>)

      false when len >= 1 or acc === <<>> ->
        encode_param_value_quote(more, len - 1, <<acc::binary, c>>)

      _ ->
        {acc, all}
    end
  end

  defp encode_param_value_encode(<<>>, _len, acc) do
    {acc, <<>>}
  end

  defp encode_param_value_encode(<<c, more::binary>> = all, len, acc)
       when c <= 31 or c === 127 or c === 40 or c === 41 or c === 60 or c === 62 or c === 64 or
              c === 44 or c === 59 or c === 58 or c === 47 or c === 91 or c === 93 or c === 63 or
              c === 61 or c === 32 or c === 42 or c === 39 or c === 37 do
    case len >= 3 or acc === <<>> do
      true ->
        <<n1::4, n2::4>> = <<c>>
        encode_param_value_encode(more, len - 3, <<acc::binary, 37, hex(n1), hex(n2)>>)

      false ->
        {acc, all}
    end
  end

  defp encode_param_value_encode(<<c, more::binary>> = all, len, acc) do
    case c >= 128 do
      true when len >= 3 or acc === <<>> ->
        <<n1::4, n2::4>> = <<c>>
        encode_param_value_encode(more, len - 3, <<acc::binary, 37, hex(n1), hex(n2)>>)

      false when len >= 1 or acc === <<>> ->
        encode_param_value_encode(more, len - 1, <<acc::binary, c>>)

      _ ->
        {acc, all}
    end
  end

  @spec decide_param_encoding_method(binary()) ::
          {:plain | :quote | :encode | :encode_utf8, non_neg_integer()}
  defp decide_param_encoding_method(value) do
    decide_param_encoding_method(value, :plain, 0, 0, 0)
  end

  defp decide_param_encoding_method(<<>>, method, l_p, l_q, l_e) do
    l =
      case method do
        :plain -> l_p
        :quote -> l_q
        :encode -> l_e
        :encode_utf8 -> l_e
      end

    {method, l}
  end

  defp decide_param_encoding_method(<<c::utf8, rest::binary>>, method, l_p, l_q, l_e)
       when byte_size(<<c::utf8>>) > 1 do
    decide_param_encoding_method(
      rest,
      change_param_encoding_method(method, :encode_utf8),
      l_p,
      l_q,
      l_e + 3 * byte_size(<<c::utf8>>)
    )
  end

  defp decide_param_encoding_method(<<c, rest::binary>>, method, l_p, l_q, l_e)
       when c <= 31 or c >= 127 do
    decide_param_encoding_method(
      rest,
      change_param_encoding_method(method, :encode),
      l_p,
      l_q,
      l_e + 3
    )
  end

  defp decide_param_encoding_method(<<c, rest::binary>>, method, l_p, l_q, l_e)
       when c === 34 or c === 92 do
    decide_param_encoding_method(
      rest,
      change_param_encoding_method(method, :quote),
      l_p,
      l_q + 2,
      l_e + 3
    )
  end

  defp decide_param_encoding_method(<<c, rest::binary>>, method, l_p, l_q, l_e)
       when c === 40 or c === 41 or c === 60 or c === 62 or c === 64 or c === 44 or c === 59 or
              c === 58 or c === 47 or c === 91 or c === 93 or c === 63 or c === 61 or c === 32 do
    decide_param_encoding_method(
      rest,
      change_param_encoding_method(method, :quote),
      l_p,
      l_q + 1,
      l_e + 3
    )
  end

  defp decide_param_encoding_method(<<c, rest::binary>>, method, l_p, l_q, l_e)
       when c === 42 or c === 39 or c === 37 do
    decide_param_encoding_method(rest, method, l_p + 1, l_q + 1, l_e + 3)
  end

  defp decide_param_encoding_method(<<_, rest::binary>>, method, l_p, l_q, l_e) do
    decide_param_encoding_method(rest, method, l_p + 1, l_q + 1, l_e + 1)
  end

  @spec change_param_encoding_method(cur_method, new_method) :: method
        when cur_method: method,
             new_method: method,
             method: :plain | :quote | :encode | :encode_utf8
  defp change_param_encoding_method(method, method) do
    method
  end

  defp change_param_encoding_method(cur_method, new_method) do
    change_param_encoding_method([:encode_utf8, :encode, :quote], cur_method, new_method)
  end

  defp change_param_encoding_method([cur_method | _more], cur_method, _new_method) do
    cur_method
  end

  defp change_param_encoding_method([new_method | _more], _cur_method, new_method) do
    new_method
  end

  defp change_param_encoding_method([_ | more], cur_method, new_method) do
    change_param_encoding_method(more, cur_method, new_method)
  end

  defp change_param_encoding_method([], _cur_method, new_method) do
    new_method
  end

  @doc false
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

  defp maybe_encode_folded_header(h, hdr)
       when h === "To" or h === "Cc" or h === "Bcc" or h === "Reply-To" or h === "From" do
    hdr
  end

  defp maybe_encode_folded_header(_h, hdr) do
    encode_folded_header(hdr, <<>>)
  end

  defp encode_folded_header(rest, acc) do
    case Postbeam.SMTP.Binary.split(rest, <<59>>, 2) do
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

  defp encode_header_value(h, value)
       when h === "To" or h === "Cc" or h === "Bcc" or h === "Reply-To" or h === "From" do
    {:ok, addresses} = Postbeam.SMTP.Util.parse_rfc5322_addresses(value)
    {names, emails} = :lists.unzip(addresses)

    new_names =
      :lists.map(
        fn
          :undefined -> :undefined
          name -> rfc2047_utf8_encode(:unicode.characters_to_binary(name))
        end,
        names
      )

    Postbeam.SMTP.Util.combine_rfc822_addresses(:lists.zip(new_names, emails))
  end

  defp encode_header_value(h, value) when h === "Content-Type" or h === "Content-Disposition" do
    value
  end

  defp encode_header_value(_, value) do
    rfc2047_utf8_encode(value)
  end

  defp encode_component(_type, _sub_type, _headers, params, body) when is_list(body) do
    boundary = :proplists.get_value("boundary", :maps.get(:content_type_params, params))

    [<<>>] ++
      :lists.flatmap(
        fn part -> [:erlang.list_to_binary(["--", boundary])] ++ encode_component_part(part) end,
        body
      ) ++ [:erlang.list_to_binary(["--", boundary, "--"])] ++ [<<>>]
  end

  defp encode_component(_type, _sub_type, headers, _params, body) do
    encode_body(get_header_value("Content-Transfer-Encoding", headers), [body])
  end

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
      encode_body(get_header_value("Content-Transfer-Encoding", fixed_headers), part_data)
  end

  defp encode_component_part(part) do
    Postbeam.SMTP.Log.debug(~c"encode_component_part couldn't match Part to: ~p", [part], %{
      domain: [:postbeam]
    })

    []
  end

  defp encode_body(:undefined, body) do
    body
  end

  defp encode_body(type, body) do
    case Postbeam.SMTP.Binary.to_lower(type) do
      "quoted-printable" ->
        [inner_body] = body
        encode_quoted_printable(inner_body)

      "base64" ->
        [inner_body] = body
        wrap_to_76(:base64.encode(inner_body))

      _ ->
        body
    end
  end

  defp wrap_to_76(string) do
    [wrap_to_76(string, [])]
  end

  defp wrap_to_76(<<>>, acc) do
    :erlang.list_to_binary(:lists.reverse(acc))
  end

  defp wrap_to_76(<<head::size(76)-binary, tail::binary>>, acc) do
    wrap_to_76(tail, ["\r\n", head | acc])
  end

  defp wrap_to_76(head, acc) do
    :erlang.list_to_binary(:lists.reverse(["\r\n", head | acc]))
  end

  def encode_quoted_printable(body) do
    [encode_quoted_printable(body, <<>>, 0, false, <<>>, 0)]
  end

  defp encode_quoted_printable(<<>>, acc, _line_len, _has_wsp, word_acc, _word_len) do
    <<acc::binary, word_acc::binary>>
  end

  defp encode_quoted_printable(
         <<13, 10, more::binary>>,
         acc,
         _line_len,
         _has_wsp,
         word_acc,
         _word_len
       ) do
    encode_quoted_printable(more, <<acc::binary, word_acc::binary, 13, 10>>, 0, false, <<>>, 0)
  end

  defp encode_quoted_printable(<<c>>, acc, line_len, _has_wsp, word_acc, word_len)
       when c === 32 or c === 9 do
    enc = encode_quoted_printable_char(c, true)

    case line_len + word_len + 3 > 76 do
      true -> <<acc::binary, word_acc::binary, 61, 13, 10, enc::binary>>
      false -> <<acc::binary, word_acc::binary, enc::binary>>
    end
  end

  defp encode_quoted_printable(
         <<c, 13, 10, more::binary>>,
         acc,
         line_len,
         _has_wsp,
         word_acc,
         word_len
       )
       when c === 32 or c === 9 do
    enc = encode_quoted_printable_char(c, true)

    case line_len + word_len + 3 > 76 do
      true ->
        encode_quoted_printable(
          more,
          <<acc::binary, word_acc::binary, 61, 13, 10, enc::binary, 13, 10>>,
          0,
          false,
          <<>>,
          0
        )

      false ->
        encode_quoted_printable(
          more,
          <<acc::binary, word_acc::binary, enc::binary, 13, 10>>,
          0,
          false,
          <<>>,
          0
        )
    end
  end

  defp encode_quoted_printable(<<c, more::binary>>, acc, line_len, has_wsp, word_acc, word_len) do
    enc = encode_quoted_printable_char(c, false)
    enc_len = byte_size(enc)

    case line_len + word_len + enc_len > 75 do
      true when c === 32 or c === 9 ->
        encode_quoted_printable(
          more,
          <<acc::binary, word_acc::binary, 61, 13, 10, enc::binary>>,
          enc_len,
          true,
          <<>>,
          0
        )

      true when has_wsp and word_len + enc_len <= 75 ->
        encode_quoted_printable(
          more,
          <<acc::binary, 61, 13, 10, word_acc::binary, enc::binary>>,
          word_len + enc_len,
          false,
          <<>>,
          0
        )

      true ->
        encode_quoted_printable(
          more,
          <<acc::binary, word_acc::binary, 61, 13, 10, enc::binary>>,
          enc_len,
          false,
          <<>>,
          0
        )

      false when c === 32 or c === 9 ->
        encode_quoted_printable(
          more,
          <<acc::binary, word_acc::binary, enc::binary>>,
          line_len + word_len + enc_len,
          true,
          <<>>,
          0
        )

      false ->
        encode_quoted_printable(
          more,
          acc,
          line_len,
          has_wsp,
          <<word_acc::binary, enc::binary>>,
          word_len + enc_len
        )
    end
  end

  defp encode_quoted_printable_char(c, true) do
    <<61, hex(div(c, 16)), hex(rem(c, 16))>>
  end

  defp encode_quoted_printable_char(32, false) do
    <<32>>
  end

  defp encode_quoted_printable_char(9, false) do
    <<9>>
  end

  defp encode_quoted_printable_char(61, _force) do
    <<61, 51, 68>>
  end

  defp encode_quoted_printable_char(c, _force) when c <= 32 or c >= 127 do
    encode_quoted_printable_char(c, true)
  end

  defp encode_quoted_printable_char(c, false) do
    <<c>>
  end

  defp get_default_encoding() do
    if Code.ensure_loaded?(:iconv), do: "utf-8//IGNORE", else: :raw
  end

  defp fix_encoding(encoding) when encoding == "utf8" or encoding == "UTF8" do
    "UTF-8"
  end

  defp fix_encoding(encoding) do
    encoding
  end

  defp rfc2047_utf8_encode(value) do
    rfc2047_utf8_encode(value, 0, " ")
  end

  defp rfc2047_utf8_encode(value, prefix_len, line_indent) when is_binary(value) do
    case is_ascii_printable(value) do
      true ->
        value

      false ->
        {readable, encoded} =
          partition_count_bytes(
            fn c ->
              c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c in ~c" !*+-/"
            end,
            value
          )

        enc = if readable >= encoded, do: :q, else: :b

        rfc2047_utf8_encode(enc, value, <<>>, prefix_len, line_indent)
    end
  end

  defp rfc2047_utf8_encode(value, prefix_len, line_indent) do
    rfc2047_utf8_encode(:erlang.list_to_binary(value), prefix_len, line_indent)
  end

  defp rfc2047_utf8_encode(_enc, <<>>, acc, _prefix_len, _line_indent) do
    acc
  end

  defp rfc2047_utf8_encode(:b, more, acc, prefix_len, line_indent) do
    rfc2047_utf8_encode(:b, more, acc, <<>>, byte_size(line_indent), line_indent, 46 - prefix_len)
  end

  defp rfc2047_utf8_encode(:q, more, acc, prefix_len, line_indent) do
    rfc2047_utf8_encode(:q, more, acc, <<>>, byte_size(line_indent), line_indent, 63 - prefix_len)
  end

  defp rfc2047_utf8_encode(enc, <<>>, acc, word_acc, _prefix_len, line_indent, _left) do
    rfc2047_append_word(acc, word_acc, enc, line_indent)
  end

  defp rfc2047_utf8_encode(
         enc,
         <<c::utf8, more::binary>> = all,
         acc,
         word_acc,
         prefix_len,
         line_indent,
         left
       ) do
    bytes = <<c::utf8>>
    size = byte_size(bytes)

    reqd =
      case enc do
        :q
        when not (c === 32 or
                      ((c >= 97 and c <= 122) or
                         ((c >= 65 and c <= 90) or
                            ((c >= 48 and c <= 57) or
                               (c === 33 or (c === 42 or (c === 43 or (c === 45 or c === 47)))))))) ->
          3 * size

        :q ->
          size

        :b ->
          size
      end

    case left >= reqd do
      true ->
        rfc2047_utf8_encode(
          enc,
          more,
          acc,
          <<word_acc::binary, bytes::binary>>,
          prefix_len,
          line_indent,
          left - reqd
        )

      false ->
        rfc2047_utf8_encode(
          enc,
          all,
          rfc2047_append_word(acc, word_acc, enc, line_indent),
          prefix_len,
          line_indent
        )
    end
  end

  defp rfc2047_append_word(acc, <<>>, _enc, _line_indent) do
    acc
  end

  defp rfc2047_append_word(<<>>, word, enc, _line_indent) do
    rfc2047_encode_word(word, enc)
  end

  defp rfc2047_append_word(acc, word, enc, line_indent) do
    <<acc::binary, 13, 10, line_indent::binary, rfc2047_encode_word(word, enc)::binary>>
  end

  defp rfc2047_encode_word(word, :q) do
    <<"=?UTF-8?Q?", rfc2047_q_encode(word)::binary, "?=">>
  end

  defp rfc2047_encode_word(word, :b) do
    <<"=?UTF-8?B?", :base64.encode(word)::binary, "?=">>
  end

  defp rfc2047_q_encode(<<>>) do
    <<>>
  end

  defp rfc2047_q_encode(<<32, more::binary>>) do
    <<95, rfc2047_q_encode(more)::binary>>
  end

  defp rfc2047_q_encode(<<c, more::binary>>)
       when c === 32 or
              ((c >= 97 and c <= 122) or
                 ((c >= 65 and c <= 90) or
                    ((c >= 48 and c <= 57) or
                       (c === 33 or (c === 42 or (c === 43 or (c === 45 or c === 47))))))) do
    <<c, rfc2047_q_encode(more)::binary>>
  end

  defp rfc2047_q_encode(<<n1::4, n2::4, more::binary>>) do
    <<61, hex(n1), hex(n2), rfc2047_q_encode(more)::binary>>
  end

  defp is_ascii_printable(<<>>) do
    true
  end

  defp is_ascii_printable(<<h, t::binary>>) when h >= 32 and h <= 126 do
    is_ascii_printable(t)
  end

  defp is_ascii_printable(_) do
    false
  end

  defp hex(n) when n >= 10 do
    n + 65 - 10
  end

  defp hex(n) do
    n + 48
  end

  defp unhex(c) when c >= 97 do
    c - 97 + 10
  end

  defp unhex(c) when c >= 65 do
    c - 65 + 10
  end

  defp unhex(c) do
    c - 48
  end

  defp partition_count_bytes(fun, bin) do
    partition_count_bytes(fun, bin, {0, 0})
  end

  defp partition_count_bytes(_fun, <<>>, partition_counts) do
    partition_counts
  end

  defp partition_count_bytes(fun, <<c, more::binary>>, {trues, falses}) do
    new_partition_counts =
      case fun.(c) do
        true -> {trues + 1, falses}
        false -> {trues, falses + 1}
      end

    partition_count_bytes(fun, more, new_partition_counts)
  end
end
