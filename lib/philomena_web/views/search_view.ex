defmodule PhilomenaWeb.SearchView do
  use PhilomenaWeb, :view

  def scope(conn), do: PhilomenaWeb.ImageScope.scope(conn)
  def hides_images?(conn), do: viewer_policy(conn).can_hide_images?
end
