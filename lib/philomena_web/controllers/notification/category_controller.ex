defmodule PhilomenaWeb.Notification.CategoryController do
  use PhilomenaWeb, :controller

  alias Philomena.Notifications

  def show(conn, params) do
    category = Notifications.category_for_param(params["id"])

    notifications =
      Notifications.unread_notifications_for_user_and_category(
        conn.assigns.actor,
        category,
        conn.assigns.scrivener
      )

    render(conn, "show.html",
      title: "Notification Area",
      notifications: notifications,
      category: category
    )
  end
end
