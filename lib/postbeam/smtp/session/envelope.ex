defmodule Postbeam.SMTP.Session.Envelope do
  @moduledoc false
  defstruct from: :undefined,
            to: [],
            recipient_count: 0,
            data: <<>>,
            expectedsize: 0,
            auth: {<<>>, <<>>},
            flags: []

  @type t() :: %__MODULE__{}
end
