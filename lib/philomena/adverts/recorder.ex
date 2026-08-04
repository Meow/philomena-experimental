defmodule Philomena.Adverts.Recorder do
  @moduledoc """
  Flushes recorded click and impression counts for adverts.
  """

  alias Philomena.Adverts.Advert
  alias Philomena.Repo
  import Ecto.Query

  @doc false
  def run(%{impressions: impressions, clicks: clicks}) do
    now = DateTime.utc_now(:second)

    # Recheck every recorded ID at flush time. An advert may have been disabled,
    # expired, or deleted since its click/impression was originally recorded.
    live_ids = live_advert_ids(Map.keys(impressions) ++ Map.keys(clicks), now)

    # Commit both counters together
    case Repo.transact(fn ->
           increment_live(impressions, live_ids, :impressions)
           increment_live(clicks, live_ids, :clicks)
           {:ok, :ok}
         end) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp live_advert_ids([], _now), do: MapSet.new()

  defp live_advert_ids(ids, now) do
    Advert
    |> where([a], a.id in ^Enum.uniq(ids))
    |> where(live: true)
    |> where([a], a.start_date < ^now and a.finish_date > ^now)
    |> select([a], a.id)
    |> Repo.all()
    |> MapSet.new()
  end

  defp increment_live(counters, live_ids, field) do
    # Each counter becomes a scoped atomic increment
    Enum.each(counters, fn {id, count} ->
      if MapSet.member?(live_ids, id) do
        Advert
        |> where(id: ^id)
        |> Repo.update_all(inc: [{field, count}])
      end
    end)
  end
end
