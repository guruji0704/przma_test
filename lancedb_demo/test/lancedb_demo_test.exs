defmodule LancedbDemoTest do
  use ExUnit.Case
  doctest LancedbDemo

  test "greets the world" do
    assert LancedbDemo.hello() == :world
  end
end
