defmodule Postbeam.SwooshConfigTest do
  use ExUnit.Case, async: false

  alias Postbeam.SecondTestMailer
  alias Postbeam.TestMailer

  setup do
    original = Application.get_all_env(:postbeam)

    on_exit(fn ->
      for {key, _} <- Application.get_all_env(:postbeam),
          do: Application.delete_env(:postbeam, key)

      for {key, value} <- original, do: Application.put_env(:postbeam, key, value)
      Application.delete_env(:postbeam_test, TestMailer)
      Application.delete_env(:postbeam_test, SecondTestMailer)
    end)

    :ok
  end

  test "library defaults, independent mailers and call overrides have documented precedence" do
    Application.put_env(:postbeam, :hostname, "global.example.com")
    Application.put_env(:postbeam, :resolver, Postbeam.TestDNS)
    Application.put_env(:postbeam, :transport, Postbeam.TestTransport)

    Application.put_env(:postbeam_test, TestMailer,
      postbeam: [hostname: "first.example.com", tls: :always]
    )

    Application.put_env(:postbeam_test, SecondTestMailer,
      postbeam: [hostname: "second.example.com"]
    )

    email = Swoosh.Email.new(from: "sender@example.com", to: "user@example.net", text_body: "")

    assert {:ok, _} = TestMailer.deliver(email)
    assert_receive {:attempt, _, _, first}
    assert first[:hostname] == "first.example.com"
    assert first[:tls] == :always
    assert {:ok, _} = SecondTestMailer.deliver(email)
    assert_receive {:attempt, _, _, second}
    assert second[:hostname] == "second.example.com"
    assert second[:tls] == :if_available
    assert {:ok, _} = TestMailer.deliver(email, postbeam: [port: 2525])
    assert_receive {:attempt, _, _, overridden}
    assert overridden[:hostname] == "global.example.com"
    assert overridden[:tls] == :if_available
    assert overridden[:port] == 2525
    refute Keyword.has_key?(overridden, :adapter)
    refute Keyword.has_key?(overridden, :otp_app)
  end
end
