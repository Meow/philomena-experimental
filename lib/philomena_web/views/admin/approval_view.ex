defmodule PhilomenaWeb.Admin.ApprovalView do
  use PhilomenaWeb, :view

  alias PhilomenaWeb.Admin.ReportView
  alias PhilomenaWeb.UserAttributionView

  def truncated_ip_link(ip), do: ReportView.truncated_ip_link(ip)
  defdelegate anonymous_name(object), to: UserAttributionView
  defdelegate anonymous_name(object, reveal_anon?), to: UserAttributionView

  def image_thumb(conn, image, media) do
    render(PhilomenaWeb.ImageView, "_image_container.html",
      image: image,
      size: :thumb_tiny,
      conn: Plug.Conn.assign(conn, :image_media, media)
    )
  end

  def class_for_image(%{processed: false}), do: "block--warning"
  def class_for_image(%{thumbnails_generated: false}), do: "block--warning"

  def class_for_image(%{image_is_animated: a, image_duration: d, image_format: "png"})
      when a or d > 0.04,
      do: "block--danger"

  def class_for_image(%{image_format: "svg"}), do: "block--warning"
  def class_for_image(%{image_format: f}) when f in ["webm", "gif"], do: "block--danger"
  def class_for_image(_), do: ""

  def warning_text(%{processed: false}), do: "(not processed)"
  def warning_text(%{thumbnails_generated: false}), do: "(not processed)"

  def warning_text(%{image_is_animated: a, image_duration: d, image_format: "png"})
      when a or d > 0.04,
      do: "(animated png)"

  def warning_text(%{image_format: "svg"}), do: "(svg)"
  def warning_text(%{image_format: f}) when f in ["webm", "gif"], do: "(video)"
  def warning_text(_), do: ""
end
