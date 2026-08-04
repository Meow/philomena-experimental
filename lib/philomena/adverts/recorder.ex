defmodule Philomena.Adverts.Recorder do
  @moduledoc """
  Flushes recorded click and impression counts for adverts.
  """

  alias Philomena.Adverts.Advert
  alias Philomena.Repo
  import Ecto.Query

  @doc false
  def run(%{impressions: impressions, clicks: clicks}) do
    increment_live(impressions, :impressions)
    increment_live(clicks, :clicks)
  end

  defp increment_live(counters, field) do
    Enum.each(counters, fn {id, count} ->
      Advert
      |> where(id: ^id)
      |> Repo.update_all(inc: [{field, count}])
    end)
  end
end
