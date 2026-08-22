defmodule PhilomenaWeb.TagChangeController do
  use PhilomenaWeb, :controller

  alias Philomena.TagChanges
  alias Philomena.TagChanges.TagChangePage

  action_fallback PhilomenaWeb.FallbackController

  def index(conn, params) do
    case load_tag_changes(conn, params) do
      {:ok, %TagChangePage{} = page, changeset} ->
        {resource_type, resource_id} = resource_metadata(page)

        render(conn, "index.html",
          title: "Tag Changes",
          tag_changes: page.tag_changes,
          resource_type: resource_type,
          resource_id: resource_id,
          changeset: changeset
        )

      {:error, %Ecto.Changeset{}} ->
        conn
        |> put_flash(:error, "Invalid tag change query.")
        |> redirect(to: "/tag_changes")

      error ->
        error
    end
  end

  def delete(conn, params) do
    case TagChanges.delete_tag_change(conn.assigns.actor, params["id"]) do
      {:ok, _tag_change} ->
        conn
        |> put_flash(:info, "Successfully deleted tag change from history.")
        |> redirect(to: params["redirect"])

      {:error, %Ecto.Changeset{}} ->
        conn
        |> put_flash(:error, "Failed to delete tag change from history.")
        |> redirect(to: params["redirect"])

      {:error, _} = error ->
        error
    end
  end

  defp load_tag_changes(conn, %{"resource_type" => type, "resource_id" => id} = params)
       when is_binary(id) and id != "" do
    case type do
      "image" ->
        TagChanges.image_tag_changes(conn.assigns.actor, id, params, conn.assigns.pagination)

      "tag" ->
        TagChanges.tag_tag_changes(conn.assigns.actor, id, params, conn.assigns.pagination)

      "user" ->
        TagChanges.user_tag_changes(conn.assigns.actor, id, params, conn.assigns.pagination)

      "ip" ->
        TagChanges.ip_tag_changes(conn.assigns.actor, id, params, conn.assigns.pagination)

      "fingerprint" ->
        TagChanges.fingerprint_tag_changes(
          conn.assigns.actor,
          id,
          params,
          conn.assigns.pagination
        )

      _type ->
        {:error, :not_found}
    end
  end

  defp load_tag_changes(conn, params) do
    case {params["resource_type"], params["resource_id"]} do
      {nil, nil} ->
        TagChanges.list_tag_changes(conn.assigns.actor, params, conn.assigns.pagination)

      _incomplete_resource ->
        {:error, :not_found}
    end
  end

  defp resource_metadata(%TagChangePage{resource_type: :all}), do: {nil, nil}

  defp resource_metadata(%TagChangePage{resource_type: :image, target: image}),
    do: {"image", image.id}

  defp resource_metadata(%TagChangePage{resource_type: :tag, target: tag}),
    do: {"tag", tag.name}

  defp resource_metadata(%TagChangePage{resource_type: :user, target: user}),
    do: {"user", user.name}

  defp resource_metadata(%TagChangePage{resource_type: :ip, target: ip}),
    do: {"ip", to_string(ip)}

  defp resource_metadata(%TagChangePage{resource_type: :fingerprint, target: fingerprint}),
    do: {"fingerprint", fingerprint}
end
