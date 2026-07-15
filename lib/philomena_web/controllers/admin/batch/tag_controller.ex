defmodule PhilomenaWeb.Admin.Batch.TagController do
  use PhilomenaWeb, :controller

  alias Philomena.Images

  action_fallback PhilomenaWeb.FallbackController

  def update(conn, %{"tags" => tag_list, "image_ids" => image_ids})
      when is_binary(tag_list) and is_list(image_ids) do
    case Images.batch_update_tags(conn.assigns.actor, tag_list, image_ids) do
      {:ok, result} ->
        PhilomenaWeb.Endpoint.broadcast!(
          "firehose",
          "image:batch_tag_update",
          %{
            image_ids: result.succeeded,
            added: result.added,
            removed: result.removed
          }
        )

        json(conn, %{succeeded: result.succeeded, failed: result.failed})

      {:error, {:batch_failed, failed}} ->
        json(conn, %{succeeded: [], failed: failed})

      {:error, :unauthorized} = error ->
        error
    end
  end

  def update(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{succeeded: [], failed: []})
  end
end
