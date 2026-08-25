defmodule PhilomenaWeb.ImageFilterPlugTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Philomena.Attribution.Actor
  alias Philomena.Filters.Filter
  alias Philomena.Filters.ImageFilter
  alias PhilomenaWeb.ImageFilterPlug

  @actor %Actor{ip: %Postgrex.INET{address: {203, 0, 113, 1}, netmask: 32}}

  test "assigns the compiled domain filter state" do
    conn =
      conn(:get, "/")
      |> assign(:actor, @actor)
      |> assign(:current_filter, %Filter{})
      |> assign(:forced_filter, nil)
      |> ImageFilterPlug.call([])

    assert %ImageFilter{} = conn.assigns.image_filter
    refute conn.halted
  end

  test "halts with an explicit error for an invalid stored filter" do
    conn =
      conn(:get, "/")
      |> assign(:actor, @actor)
      |> assign(:current_filter, %Filter{hidden_complex_str: "("})
      |> assign(:forced_filter, nil)
      |> ImageFilterPlug.call([])

    assert conn.halted
    assert conn.status == 422
    assert conn.resp_body == "Invalid image filter"
  end
end
