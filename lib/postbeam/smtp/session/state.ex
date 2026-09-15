defmodule Postbeam.SMTP.Session.State do
  @moduledoc "Internal state of a `Postbeam.SMTP.Session`, including its monitored DATA task."
  defstruct socket: :undefined,
            reader: nil,
            module: :undefined,
            transport: :undefined,
            ranch_ref: :undefined,
            envelope: :undefined,
            extensions: [],
            maxsize: 10_485_760,
            waitingauth: false,
            authenticated: false,
            authdata: :undefined,
            readmessage: false,
            tls: false,
            callbackstate: :undefined,
            protocol: :smtp,
            options: []

  @type t() :: %__MODULE__{}
end
