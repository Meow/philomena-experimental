defmodule Philomena.Images.Display.Media do
  @moduledoc """
  Presentation data for an image's media URIs.
  """

  alias Philomena.Images.Thumbnailer
  alias Philomena.Images.Image
  alias Philomena.Tags.Tag

  @enforce_keys [
    :view,
    :download,
    :supplements,
    :thumbnails,
    :rendered?,
    :optimized?,
    :duplication_checked?
  ]
  defstruct @enforce_keys

  @type omitted ::
          :not_rendered | :not_available | :destroyed

  @type version :: %{
          width: pos_integer(),
          height: pos_integer(),
          uri: String.t()
        }

  @type thumbnails :: %{
          full: version(),
          tall: version(),
          large: version(),
          medium: version(),
          small: version(),
          thumb: version(),
          thumb_small: version(),
          thumb_tiny: version()
        }

  @type video_previews :: %{
          thumb: version(),
          thumb_small: version(),
          thumb_tiny: version()
        }

  @type gif_supplements :: %{
          static_preview: version(),
          mp4: version(),
          webm: version()
        }

  @type svg_supplements :: %{
          static_preview: version(),
          svg: version()
        }

  @type webm_supplements :: %{
          gif_previews: video_previews(),
          static_preview: version(),
          mp4: version()
        }

  @type mp4_supplements :: %{
          gif_previews: video_previews(),
          static_preview: version(),
          webm: version()
        }

  @type files :: %{
          short: version(),
          long: version()
        }

  @type t :: %__MODULE__{
          view: omitted() | {:files, files()},
          download: omitted() | {:files, files()},
          supplements:
            omitted()
            | :none
            | {:gif, gif_supplements()}
            | {:svg, svg_supplements()}
            | {:webm, webm_supplements()}
            | {:mp4, mp4_supplements()},
          thumbnails: omitted() | {:thumbnails, thumbnails()},
          rendered?: boolean(),
          optimized?: boolean(),
          duplication_checked?: boolean()
        }

  @doc false
  @spec render(Image.t(), boolean()) :: t()
  def render(%Image{} = image, may_reveal_hidden?) do
    image_format = normalized_format(image)

    %__MODULE__{
      view: guarded_versions(image, may_reveal_hidden?, &files(&1, image_format, false)),
      download: guarded_versions(image, may_reveal_hidden?, &files(&1, image_format, true)),
      supplements:
        guarded_versions(image, may_reveal_hidden?, &supplemental_uris(&1, image_format)),
      thumbnails: guarded_versions(image, may_reveal_hidden?, &thumbnail_uris(&1, image_format)),
      rendered?: image.thumbnails_generated,
      optimized?: image.processed,
      duplication_checked?: image.duplication_checked
    }
  end

  defp guarded_versions(%Image{} = image, may_reveal_hidden?, callback)
       when is_function(callback, 1) do
    cond do
      not image.thumbnails_generated ->
        # File URIs are useless before thumbnails are generated
        :not_rendered

      (image.hidden_from_users or image.destroyed_content) and not may_reveal_hidden? ->
        # Don't return files for images the actor may not see
        :not_available

      image.destroyed_content ->
        # No files available for destroyed images
        :destroyed

      true ->
        callback.(image)
    end
  end

  defp files(%Image{} = image, image_format, download?) do
    image_format = version_format(image_format, download?)

    files =
      %{
        short: file_version(image, image_format, true, download?),
        long: file_version(image, image_format, false, download?)
      }

    {:files, files}
  end

  defp thumbnail_uris(%Image{} = image, image_format) do
    image_format = version_format(image_format, false)

    thumbnails =
      Thumbnailer.thumbnail_versions()
      |> Map.new(fn {version_name, _} = version ->
        {version_name, version_uri(image, image_format, version)}
      end)
      |> Map.put(:full, file_version(image, image_format, true, false))

    {:thumbnails, thumbnails}
  end

  defp video_preview_uris(%Image{} = image) do
    Thumbnailer.thumbnail_versions()
    |> Enum.filter(fn {version_name, _} ->
      version_name in [:thumb, :thumb_small, :thumb_tiny]
    end)
    |> Map.new(fn {version_name, _} = version ->
      {version_name, version_uri(image, "gif", version)}
    end)
  end

  defp version_uri(
         %Image{image_aspect_ratio: aspect_ratio, image_width: width, image_height: height} =
           image,
         image_format,
         {version_name, {max_width, max_height}}
       ) do
    if width > max_width or height > max_height do
      {thumbnail_width, thumbnail_height} =
        constrained_dimensions(aspect_ratio, max_width, max_height)

      %{
        uri: exact_version_uri(image, image_format, version_name),
        width: thumbnail_width,
        height: thumbnail_height
      }
    else
      %{uri: file_uri(image, image_format, true, false), width: width, height: height}
    end
  end

  defp constrained_dimensions(ar, w, h) when ar > w / h,
    do: {w, floor(w / ar)}

  defp constrained_dimensions(ar, _w, h),
    do: {floor(h * ar), h}

  def exact_version_uri(%Image{} = image, image_format, version_name) do
    %{year: year, month: month, day: day} = image.created_at

    id_fragment =
      if image.hidden_from_users do
        "#{image.id}-#{image.hidden_image_key}"
      else
        "#{image.id}"
      end

    "#{image_url_root()}/#{year}/#{month}/#{day}/#{id_fragment}/#{version_name}.#{image_format}"
  end

  defp file_uri(%Image{} = image, image_format, short?, download?) do
    if image.hidden_from_users do
      # Hidden images don't support the view/download routes
      exact_version_uri(image, image_format, :full)
    else
      %{year: year, month: month, day: day} = image.created_at

      view = if download?, do: "download", else: "view"
      filename = if short?, do: image.id, else: "#{image.id}__#{file_name_slug(image)}"

      "#{image_url_root()}/#{view}/#{year}/#{month}/#{day}/#{filename}.#{image_format}"
    end
  end

  defp supplemental_uris(%Image{} = image, image_format) do
    case image_format do
      "svg" ->
        {:svg,
         %{
           static_preview: file_version(image, "png", true, false),
           svg: file_version(image, "svg", true, false)
         }}

      "gif" ->
        {:gif,
         %{
           static_preview: version(image, exact_version_uri(image, "png", :rendered)),
           webm: file_version(image, "webm", true, false),
           mp4: file_version(image, "mp4", true, false)
         }}

      "webm" ->
        {:webm,
         %{
           gif_previews: video_preview_uris(image),
           static_preview: version(image, exact_version_uri(image, "png", :rendered)),
           mp4: file_version(image, "mp4", true, false)
         }}

      _ ->
        :none
    end
  end

  defp file_version(%Image{} = image, image_format, short?, download?) do
    version(image, file_uri(image, image_format, short?, download?))
  end

  defp version(%Image{image_width: width, image_height: height}, uri) do
    %{uri: uri, width: width, height: height}
  end

  defp file_name_slug(%Image{tags: tags}) do
    # Truncate filename to 150 characters, making room for the path + filename on Windows
    # https://stackoverflow.com/a/265769
    tags
    |> Tag.display_order()
    |> Enum.map_join("_", & &1.slug)
    |> String.replace(~r/[^a-z0-9_+\-]/, "")
    |> String.slice(0, 150)
  end

  defp normalized_format(%Image{image_format: image_format}) do
    image_format
    |> to_string()
    |> String.downcase()
  end

  defp version_format(image_format, download?) do
    if image_format == "svg" and not download? do
      # Return PNG by default for SVG images
      "png"
    else
      image_format
    end
  end

  defp image_url_root do
    Application.get_env(:philomena, :image_url_root)
  end
end
