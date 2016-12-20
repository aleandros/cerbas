defmodule CerbasTest do
  use ExUnit.Case, async: true
  doctest Cerbas

  test "hellox world" do
    assert(
     Cerbas.Dispatcher.dispatch({"hellox", "foo", "bar"})
     ==
     {:error, "Undefined function"}
    )
  end

  test "hello world" do
    assert(
     Cerbas.Dispatcher.dispatch({"hello", %{}, "tom"})
     ==
     "hello world!"
    )
  end

  test "async func" do
    assert(
     Cerbas.Dispatcher.dispatch({"asyncfunc", %{}, "tom"})
     ==
     ""
    )
  end

  test "function with arguments" do
    assert(
     Cerbas.Dispatcher.dispatch({"withargs", %{"foo" => "bar"}, "tom"})
     ==
     "bar"
    )
  end

  test "function with error" do
    assert(
     Cerbas.Dispatcher.dispatch({"witherror", %{}, "tom"})
     ==
     {:error, "unexpected error"}
    )
  end

  test "halt in 5 seconds" do
    assert(
     Cerbas.Dispatcher.dispatch({"halt", %{"delay" => 5000}, "tom"})
     ==
     ""
    )
  end

  test "wait " do
    :timer.sleep 6
    assert 1 == 1
  end
end