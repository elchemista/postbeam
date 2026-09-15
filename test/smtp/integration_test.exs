defmodule Postbeam.SMTP.IntegrationTest do
  use ExUnit.Case, async: true

  test "the SMTP engine and supervisors belong to the postbeam application" do
    for module <- [
          Postbeam.SMTP.Client,
          Postbeam.SMTP.Server,
          Postbeam.SMTP.MIME,
          Postbeam.SMTP.DKIM,
          :postbeam_smtp_rfc822_parse,
          :postbeam_smtp_rfc5322_parse,
          :postbeam_smtp_rfc5322_scan
        ] do
      assert Application.get_application(module) == :postbeam
    end

    for name <- [Postbeam.SMTP.ClientSupervisor, Postbeam.SMTP.DataSupervisor] do
      assert is_pid(Process.whereis(name))
    end

    {:ok, applications} = :application.get_key(:postbeam, :applications)
    refute :gen_smtp in applications
    refute List.keymember?(Application.started_applications(), :gen_smtp, 0)
  end
end
