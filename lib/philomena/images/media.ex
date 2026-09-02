defmodule Philomena.Images.Media do
  @moduledoc """
  Viewer-safe image media locators.
  """

  alias Philomena.Images.Image
  alias Philomena.Images.Thumbnailer
  alias Philomena.Tags.Tag

  @enforce_keys [:thumb_urls, :view_url, :download_url]
  defstruct [:thumb_urls, :view_url, :view_short_url, :download_url, :download_short_url]

  @type t :: %__MODULE__{
          thumb_urls: %{optional(atom()) => String.t()},
          view_url: String.t() | nil,
          view_short_url: String.t() | nil,
          download_url: String.t() | nil,
          download_short_url: String.t() | nil
        }

  @doc "Builds media locators, omitting every locator for a hidden image the viewer cannot see."
  @spec disclose(Image.t(), boolean()) :: t()
  def disclose(%Image{hidden_from_users: true}, false) do
    %__MODULE__{thumb_urls: %{}, view_url: nil, download_url: nil}
  end

  def disclose(%Image{} = image, show_hidden?) do
    %__MODULE__{
      thumb_urls: thumb_urls(image, show_hidden?),
      view_url: pretty_url(image, false, false),
      view_short_url: pretty_url(image, true, false),
      download_url: pretty_url(image, false, true),
      download_short_url: pretty_url(image, true, true)
    }
  end

  @doc "Returns the thumbnail map for the supplied visibility projection."
  @spec thumb_urls(Image.t(), boolean()) :: %{optional(atom()) => String.t()}
  def thumb_urls(%Image{hidden_from_users: true}, false), do: %{}

  def thumb_urls(%Image{} = image, show_hidden?) do
    Thumbnailer.thumbnail_versions()
    |> Map.new(fn {name, {width, height}} ->
      if image.image_width > width or image.image_height > height do
        {name, thumb_url(image, show_hidden?, name)}
      else
        {name, thumb_url(image, show_hidden?, :full)}
      end
    end)
    |> append_full_url(image, show_hidden?)
    |> append_gif_urls(image, show_hidden?)
  end

  @doc "Returns legacy public thumbnail locators for compatibility with list renderers."
  @spec legacy_thumb_urls(Image.t()) :: %{optional(atom()) => String.t()}
  def legacy_thumb_urls(%Image{} = image) do
    Thumbnailer.thumbnail_versions()
    |> Map.new(fn {name, {width, height}} ->
      if image.image_width > width or image.image_height > height do
        {name, legacy_thumb_url(image, name)}
      else
        {name, legacy_thumb_url(image, :full)}
      end
    end)
    |> then(fn urls ->
      full =
        if image.hidden_from_users,
          do: legacy_thumb_url(image, :full),
          else: pretty_url(image, true, false)

      Map.put(urls, :full, full)
    end)
  end

  defp legacy_thumb_url(%Image{} = image, name) do
    %{year: year, month: month, day: day} = image.created_at
    root = image_url_root()

    format =
      image.image_format
      |> to_string()
      |> String.downcase()
      |> thumb_format(name, false)

    "#{root}/#{year}/#{month}/#{day}/#{image.id}/#{name}.#{format}"
  end

  @doc "Returns one thumbnail locator, or `nil` when media is undisclosed."
  @spec thumb_url(Image.t(), boolean(), atom()) :: String.t() | nil
  def thumb_url(%Image{hidden_from_users: true}, false, _name), do: nil

  def thumb_url(%Image{} = image, show_hidden?, name) do
    %{year: year, month: month, day: day} = image.created_at
    deleted = image.hidden_from_users
    root = image_url_root()

    format =
      image.image_format
      |> to_string()
      |> String.downcase()
      |> thumb_format(name, false)

    id_fragment =
      if deleted and show_hidden? do
        "#{image.id}-#{image.hidden_image_key}"
      else
        "#{image.id}"
      end

    "#{root}/#{year}/#{month}/#{day}/#{id_fragment}/#{name}.#{format}"
  end

  @doc "Returns a canonical view or download URL."
  @spec pretty_url(Image.t(), boolean(), boolean()) :: String.t() | nil
  def pretty_url(%Image{} = image, short, download) do
    %{year: year, month: month, day: day} = image.created_at
    root = image_url_root()
    view = if download, do: "download", else: "view"
    filename = if short, do: image.id, else: verbose_file_name(image)

    format =
      image.image_format
      |> to_string()
      |> String.downcase()
      |> thumb_format(nil, download)

    "#{root}/#{view}/#{year}/#{month}/#{day}/#{filename}.#{format}"
  end

  defp append_full_url(urls, %{hidden_from_users: false} = image, _show_hidden),
    do: Map.put(urls, :full, pretty_url(image, true, false))

  defp append_full_url(urls, %{hidden_from_users: true} = image, true),
    do: Map.put(urls, :full, thumb_url(image, true, :full))

  defp append_full_url(urls, _image, _show_hidden), do: urls

  defp append_gif_urls(urls, %{image_mime_type: "image/gif"} = image, show_hidden?) do
    case thumb_url(image, show_hidden?, :full) do
      nil ->
        urls

      full_url ->
        Map.merge(urls, %{
          webm: String.replace(full_url, ".gif", ".webm"),
          mp4: String.replace(full_url, ".gif", ".mp4")
        })
    end
  end

  defp append_gif_urls(urls, _image, _show_hidden), do: urls

  defp verbose_file_name(image) do
    file_name_slug_fragment =
      image.tags
      |> Tag.display_order()
      |> Enum.map_join("_", & &1.slug)
      |> String.to_charlist()
      |> Enum.filter(&(&1 in ?a..?z or &1 in ~c"0123456789_-+"))
      |> List.to_string()
      |> String.slice(0..150)

    "#{image.id}__#{file_name_slug_fragment}"
  end

  defp image_url_root, do: Application.get_env(:philomena, :image_url_root)

  defp thumb_format("svg", _name, false), do: "png"
  defp thumb_format(_format, :rendered, _download), do: "png"
  defp thumb_format(format, _name, _download), do: format
end
