defmodule PhilomenaWeb.ProfileController do
  use PhilomenaWeb, :controller

  alias PhilomenaWeb.ImageScope
  alias PhilomenaWeb.MarkdownRenderer
  alias Philomena.Profiles

  action_fallback PhilomenaWeb.FallbackController

  def show(conn, %{"id" => slug}) do
    with {:ok, page} <-
           Profiles.load_profile_page(
             ImageScope.search_scope(conn),
             conn.assigns.current_filter,
             slug
           ) do
      user = page.user

      rendered_comments = MarkdownRenderer.render_collection(page.recent_comments, conn)
      recent_comments = Enum.zip(rendered_comments, page.recent_comments)

      about_me = MarkdownRenderer.render_one(%{body: user.description || ""}, conn)
      scratchpad = MarkdownRenderer.render_one(%{body: user.scratchpad || ""}, conn)
      commission_information = commission_info(user.commission, conn)

      assigns =
        [
          user: user,
          interactions: page.interactions,
          commission_information: commission_information,
          recent_artwork: page.recent_artwork,
          recent_uploads: page.recent_uploads,
          recent_faves: page.recent_faves,
          recent_comments: recent_comments,
          recent_posts: page.recent_posts,
          recent_galleries: page.recent_galleries,
          statistics: page.statistics,
          watcher_counts: page.watcher_counts,
          about_me: about_me,
          scratchpad: scratchpad,
          tags: page.tags,
          forced: user.forced_filter,
          bans: page.bans,
          layout_class: "layout--medium",
          title: "#{user.name}'s profile"
        ] ++ admin_assigns(conn, user)

      render(conn, "show.html", assigns)
    end
  end

  # Admin-only strips assemble their data behind the same permission checks the
  # view uses to show them, so the assigns are present exactly when the view
  # reads them.
  defp admin_assigns(conn, user) do
    viewer = conn.assigns.current_user
    renderer = &MarkdownRenderer.render_collection(&1, conn)

    []
    |> put_admin_metadata(viewer, user)
    |> put_mod_notes(viewer, user, renderer)
    |> put_name_changes(viewer, user)
  end

  defp put_admin_metadata(assigns, viewer, user) do
    case Profiles.admin_metadata(viewer, user) do
      nil ->
        assigns

      %{filter: filter, last_ip: last_ip, last_fp: last_fp} ->
        [filter: filter, last_ip: last_ip, last_fp: last_fp] ++ assigns
    end
  end

  defp put_mod_notes(assigns, viewer, user, renderer) do
    case Profiles.mod_notes(viewer, user, renderer) do
      nil -> assigns
      mod_notes -> [{:mod_notes, mod_notes} | assigns]
    end
  end

  defp put_name_changes(assigns, viewer, user) do
    case Profiles.name_changes(viewer, user) do
      nil -> assigns
      name_changes -> [{:name_changes, name_changes} | assigns]
    end
  end

  defp commission_info(%{information: info}, conn)
       when info not in [nil, ""],
       do: MarkdownRenderer.render_one(%{body: info}, conn)

  defp commission_info(_commission, _conn), do: ""
end
