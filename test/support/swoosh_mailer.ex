defmodule Postbeam.TestMailer do
  @moduledoc false
  use Swoosh.Mailer, otp_app: :postbeam_test, adapter: Postbeam.Swoosh.Adapter
end
