defmodule PhilomenaWeb.LayoutView do
  use PhilomenaWeb, :view

  import PhilomenaWeb.Config
  alias PhilomenaWeb.ImageView
  alias Philomena.Config
  alias Philomena.Users.Settings
  alias Plug.Conn

  @themes Settings.themes()

  def layout_class(conn) do
    conn.assigns[:layout_class] || "layout--narrow"
  end

  def container_class(%{settings: %{use_centered_layout: false}}), do: nil
  def container_class(_user), do: "layout--center-aligned"

  def philomena_version, do: Application.spec(:philomena, :vsn)

  def render_time(conn) do
    (Time.diff(Time.utc_now(), conn.assigns[:start_time], :microsecond) / 1000.0)
    |> Float.round(3)
    |> Float.to_string()
  end

  def hide_version do
    Application.get_env(:philomena, :hide_version) == "true"
  end

  def cdn_host do
    Application.get_env(:philomena, :cdn_host)
  end

  def vite_reload? do
    Application.get_env(:philomena, :vite_reload)
  end

  def generator_name do
    if hide_version() do
      "Philomena"
    else
      "Philomena v#{philomena_version()}"
    end
  end

  defp ignored_tag_list(nil), do: []
  defp ignored_tag_list([]), do: []
  defp ignored_tag_list([{tag, _body, _dnp_entries}]), do: [tag.id]
  defp ignored_tag_list(tags), do: Enum.map(tags, & &1.id)

  def clientside_data(conn) do
    conn = Conn.fetch_cookies(conn)

    extra = Map.get(conn.assigns, :clientside_data, [])
    interactions = Map.get(conn.assigns, :interactions, [])
    user = conn.assigns.current_user
    policy = viewer_policy(conn)
    filter = conn.assigns.current_filter

    data = [
      filter_id: filter.id,
      hidden_tag_list: JSON.encode!(filter.hidden_tag_ids),
      hidden_filter: PhilomenaQuery.Parse.String.normalize(filter.hidden_complex_str || ""),
      spoilered_tag_list: JSON.encode!(filter.spoilered_tag_ids),
      spoilered_filter: PhilomenaQuery.Parse.String.normalize(filter.spoilered_complex_str || ""),
      user_id: if(user, do: user.id, else: nil),
      user_name: if(user, do: user.name, else: nil),
      user_slug: if(user, do: user.slug, else: nil),
      user_role: if(user, do: user.role, else: nil),
      user_is_signed_in: to_string(policy.signed_in?),
      user_can_edit_filter: if(user, do: filter.user_id == user.id, else: "false") |> to_string(),
      spoiler_type: if(user, do: user.settings.spoiler_type, else: "static"),
      watched_tag_list: JSON.encode!(if(user, do: user.watched_tag_ids, else: [])),
      fancy_tag_edit:
        if(user, do: user.settings.fancy_tag_field_on_edit, else: "true") |> to_string(),
      fancy_tag_upload:
        if(user, do: user.settings.fancy_tag_field_on_upload, else: "true") |> to_string(),
      interactions: JSON.encode!(interactions),
      ignored_tag_list: JSON.encode!(ignored_tag_list(conn.assigns[:tags])),
      hide_staff_tools: conn.cookies["hide_staff_tools"] |> to_string()
    ]

    data = Keyword.merge(data, extra)

    content_tag(:div, "", class: "js-datastore", data: data)
  end

  def footer_data do
    Config.get(:footer)
  end

  def stylesheet_path(conn, %{settings: %{theme: theme}})
      when theme in @themes,
      do: static_path(conn, "/css/#{theme}.css")

  def stylesheet_path(_conn, _user),
    do: ~p"/css/dark-blue.css"

  def light_stylesheet_path(_conn),
    do: ~p"/css/light-blue.css"

  def theme_name(%{settings: %{theme: theme}}), do: theme
  def theme_name(_user), do: "dark-blue"

  def hide_staff_tools_attribute(conn),
    do: if(conn.cookies["hide_staff_tools"] == "true", do: "true", else: "false")

  def artist_tags(tags),
    do: Enum.filter(tags, &(&1.namespace == "artist"))

  def opengraph?(conn),
    do:
      !is_nil(conn.assigns[:image]) and conn.assigns.image.__meta__.state == :loaded and
        is_list(conn.assigns.image.tags)

  @doc "Returns the application-owned navigation result for this request."
  def admin_navigation(conn) do
    conn.assigns.admin_navigation
  end

  # Compatibility adapters for callers outside the phase-2 shell. They read
  # application results only; policy is assembled by the owning contexts.
  def staff?(conn), do: admin_navigation(conn).show_admin_menu?
  def hides_images?(conn), do: viewer_policy(conn).can_hide_images?
  def manages_site_notices?(conn), do: admin_navigation(conn).can_manage_site_notices?
  def manages_tags?(conn), do: admin_navigation(conn).can_manage_tags?
  def manages_users?(conn), do: admin_navigation(conn).can_manage_users?
  def manages_forums?(conn), do: admin_navigation(conn).can_manage_forums?
  def manages_ads?(conn), do: admin_navigation(conn).can_manage_adverts?
  def manages_badges?(conn), do: admin_navigation(conn).can_manage_badges?
  def manages_static_pages?(conn), do: admin_navigation(conn).can_manage_static_pages?
  def manages_mod_notes?(conn), do: admin_navigation(conn).can_manage_mod_notes?
  def manages_bans?(conn), do: admin_navigation(conn).can_manage_bans?
  def can_see_moderation_log?(conn), do: admin_navigation(conn).can_view_moderation_log?

  def viewport_meta_tag(conn) do
    ua = get_user_agent(conn)

    if String.contains?(ua, ["Mobile", "webOS"]) do
      tag(:meta, name: "viewport", content: "width=device-width, initial-scale=1")
    else
      tag(:meta, name: "viewport", content: "width=1024, initial-scale=1")
    end
  end

  defp get_user_agent(conn) do
    case Plug.Conn.get_req_header(conn, "user-agent") do
      [ua] -> ua
      _ -> ""
    end
  end
end
