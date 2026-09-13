defmodule Postbeam.DocsTest do
  use ExUnit.Case, async: true
  doctest Postbeam
  doctest Postbeam.Config
  doctest Postbeam.Message
end
