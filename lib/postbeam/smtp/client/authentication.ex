defmodule Postbeam.SMTP.Client.Authentication do
  @moduledoc false

  alias Postbeam.SMTP.Binary
  alias Postbeam.SMTP.Client
  alias Postbeam.SMTP.Client.Reply
  alias Postbeam.SMTP.Socket
  alias Postbeam.SMTP.Util

  @preferred_types [~c"CRAM-MD5", ~c"LOGIN", ~c"PLAIN", ~c"XOAUTH2"]

  @doc false
  @spec authenticate(Socket.socket(), Client.options(), iodata() | :undefined) :: boolean()
  def authenticate(socket, options, types) when types in [[], :undefined] do
    unavailable(socket, options, {:missing_requirement, :auth})
  end

  def authenticate(socket, options, types) do
    if credentials_available?(options) do
      username = IO.iodata_to_binary(Keyword.fetch!(options, :username))
      password = IO.iodata_to_binary(Keyword.fetch!(options, :password))

      try_types(socket, username, password, supported_types(types)) or
        unavailable(socket, options, {:permanent_failure, :auth_failed})
    else
      unavailable(socket, options, {:missing_requirement, :auth})
    end
  end

  @spec credentials_available?(Client.options()) :: boolean()
  defp credentials_available?(options) do
    Keyword.get(options, :auth) != :never and Keyword.has_key?(options, :username) and
      Keyword.has_key?(options, :password)
  end

  @spec supported_types(iodata()) :: [charlist()]
  defp supported_types(types) do
    offered = types |> IO.iodata_to_binary() |> String.upcase() |> String.split(" ", trim: true)
    Enum.filter(@preferred_types, &(List.to_string(&1) in offered))
  end

  @spec unavailable(Socket.socket(), Client.options(), Client.failure()) :: false
  defp unavailable(socket, options, failure) do
    if Keyword.get(options, :auth) == :always do
      Reply.quit(socket)
      throw(failure)
    end

    false
  end

  @spec try_types(Socket.socket(), binary(), binary(), [charlist()]) :: boolean()
  defp try_types(socket, username, password, types) do
    Enum.any?(types, &handshake(&1, socket, username, password))
  end

  @spec handshake(charlist(), Socket.socket(), binary(), binary()) :: boolean()
  defp handshake(~c"CRAM-MD5", socket, username, password) do
    case exchange(socket, "AUTH CRAM-MD5") do
      <<"334 ", challenge::binary>> ->
        seed =
          challenge |> Binary.strip(:right, ?\n) |> Binary.strip(:right, ?\r) |> Base.decode64!()

        digest = Util.compute_cram_digest(password, seed)
        accepted?(exchange(socket, Base.encode64(IO.iodata_to_binary([username, " ", digest]))))

      _reply ->
        false
    end
  end

  defp handshake(~c"LOGIN", socket, username, password) do
    with true <- auth_username_prompt?(exchange(socket, "AUTH LOGIN")),
         true <- auth_password_prompt?(exchange(socket, Base.encode64(username))),
         <<"235 ", _::binary>> <- exchange(socket, Base.encode64(password)) do
      true
    else
      _reply -> false
    end
  end

  defp handshake(~c"PLAIN", socket, username, password) do
    payload = Base.encode64(<<0, username::binary, 0, password::binary>>)
    accepted?(exchange(socket, ["AUTH PLAIN ", payload]))
  end

  defp handshake(~c"XOAUTH2", socket, username, password) do
    payload =
      Base.encode64("user=" <> username <> <<1>> <> "auth=Bearer " <> password <> <<1, 1>>)

    accepted?(exchange(socket, ["AUTH XOAUTH2 ", payload]))
  end

  @spec exchange(Socket.socket(), iodata()) :: binary()
  defp exchange(socket, command) do
    Socket.send(socket, [command, "\r\n"])
    {:ok, reply} = Reply.read_possible_multiline_reply(socket)
    reply
  end

  @spec accepted?(binary()) :: boolean()
  defp accepted?(<<"235", _::binary>>), do: true
  defp accepted?(_reply), do: false

  @spec auth_username_prompt?(binary()) :: boolean()
  defp auth_username_prompt?("334 VXNlcm5hbWU6\r\n") do
    true
  end

  defp auth_username_prompt?("334 dXNlcm5hbWU6\r\n") do
    true
  end

  defp auth_username_prompt?(<<"334 VXNlcm5hbWU6 ", _::binary>>) do
    true
  end

  defp auth_username_prompt?(<<"334 dXNlcm5hbWU6 ", _::binary>>) do
    true
  end

  defp auth_username_prompt?(_) do
    false
  end

  @spec auth_password_prompt?(binary()) :: boolean()
  defp auth_password_prompt?("334 UGFzc3dvcmQ6\r\n") do
    true
  end

  defp auth_password_prompt?("334 cGFzc3dvcmQ6\r\n") do
    true
  end

  defp auth_password_prompt?(<<"334 UGFzc3dvcmQ6 ", _::binary>>) do
    true
  end

  defp auth_password_prompt?(<<"334 cGFzc3dvcmQ6 ", _::binary>>) do
    true
  end

  defp auth_password_prompt?(_) do
    false
  end
end
