defmodule Postbeam.SMTP.Session.Envelope do
  @moduledoc false
  defstruct from: :undefined, to: [], data: <<>>, expectedsize: 0, auth: {<<>>, <<>>}, flags: []
  @type t() :: %__MODULE__{}
end
