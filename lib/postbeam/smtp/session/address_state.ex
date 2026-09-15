defmodule Postbeam.SMTP.Session.AddressState do
  @moduledoc false
  defstruct quotes: false, ab: true, utf8: false
  @type t() :: %__MODULE__{}
end
