# Run with: mix run examples/swoosh.exs
# Uses Swoosh's local mailbox; change the mailer's application configuration
# to Postbeam.Swoosh.Adapter and set :postbeam options for real MX delivery.
defmodule Postbeam.Examples.Mailer do
  @moduledoc false
  use Swoosh.Mailer, otp_app: :postbeam_example, adapter: Swoosh.Adapters.Local
end

import Swoosh.Email

{:ok, %{id: id}} =
  new()
  |> from({"Example team", "hello@example.com"})
  |> to({"Mario", "mario@example.net"})
  |> subject("Welcome")
  |> text_body("Welcome to Example!")
  |> html_body("<h1>Welcome to Example!</h1>")
  |> Postbeam.Examples.Mailer.deliver()

IO.puts("Email stored in local mailbox: #{id}")
