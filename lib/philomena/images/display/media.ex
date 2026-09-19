defmodule Philomena.Images.Display.Media do
  @moduledoc """
  Presentation data for an image's media URIs.
  """

  alias Philomena.Images.Thumbnailer
  alias Philomena.Images.Image
  alias Philomena.Tags.Tag

  @enforce_keys [
    :representations,
    :rendered?,
    :optimized?,
    :duplication_checked?
  ]

  defstruct @enforce_keys

  @type version :: %{
          width: pos_integer(),
          height: pos_integer(),
          mime_type: String.t(),
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
          mp4: version(),
          mp4_thumbnails: thumbnails()
        }

  @type mp4_supplements :: %{
          gif_previews: video_previews(),
          static_preview: version(),
          webm: version(),
          webm_thumbnails: thumbnails()
        }

  @type files :: %{
          short: version(),
          long: version()
        }

  @type image_representations :: %{
          view: files(),
          download: files(),
          thumbnails: thumbnails(),
          supplements:
            :none
            | {:gif, gif_supplements()}
            | {:svg, svg_supplements()}
            | {:webm, webm_supplements()}
            | {:mp4, mp4_supplements()}
        }

  @type representations ::
          :destroyed
          | :not_available
          | :not_rendered
          | {:image, image_representations()}

  @type t :: %__MODULE__{
          representations: representations(),
          rendered?: boolean(),
          optimized?: boolean(),
          duplication_checked?: boolean()
        }

  @doc false
  @spec render(Image.t(), boolean()) :: t()
  def render(%Image{} = image, may_reveal_hidden?) do
    image_format = normalized_format(image)

    representations =
      cond do
        image.destroyed_content ->
          # No files available for destroyed images
          :destroyed

        image.hidden_from_users and not may_reveal_hidden? ->
          # Don't return files for images the actor may not see
          :not_available

        not image.thumbnails_generated ->
          # File URIs are useless before thumbnails are generated
          :not_rendered

        true ->
          {:image,
           %{
             view: files(image, image_format, false),
             download: files(image, image_format, true),
             supplements: supplemental_versions(image, image_format),
             thumbnails: thumbnail_versions(image, image_format)
           }}
      end

    %__MODULE__{
      representations: representations,
      rendered?: image.thumbnails_generated,
      optimized?: image.processed,
      duplication_checked?: image.duplication_checked
    }
  end

  defp files(%Image{} = image, image_format, download?) do
    image_format = version_format(image_format, download?)

    %{
      short: full_version(image, image_format, short?: true, download?: download?),
      long: full_version(image, image_format, short?: false, download?: download?)
    }
  end

  defp thumbnail_versions(%Image{} = image, image_format) do
    image_format = version_format(image_format, false)

    Thumbnailer.thumbnail_versions()
    |> Map.new(fn {version_name, _} = version ->
      {version_name, constrained_version(image, image_format, version)}
    end)
    |> Map.put(:full, full_version(image, image_format))
  end

  defp video_preview_versions(%Image{} = image) do
    Thumbnailer.thumbnail_versions()
    |> Enum.filter(fn {version_name, _} ->
      version_name in [:thumb, :thumb_small, :thumb_tiny]
    end)
    |> Map.new(fn {version_name, _} = version ->
      # There is no full GIF representation to fall back on; the scaled
      # URI must always be chosen, even if the image dimensions are smaller.
      preview = constrained_version(image, "gif", version)
      preview = %{preview | uri: scaled_version_uri(image, "gif", version_name)}

      {version_name, preview}
    end)
  end

  defp constrained_version(
         %Image{image_aspect_ratio: aspect_ratio, image_width: width, image_height: height} =
           image,
         image_format,
         {version_name, {max_width, max_height}}
       ) do
    if width > max_width or height > max_height do
      {thumbnail_width, thumbnail_height} =
        constrained_dimensions(aspect_ratio, max_width, max_height)

      scaled_version(image, image_format, version_name,
        width: thumbnail_width,
        height: thumbnail_height
      )
    else
      full_version(image, image_format)
    end
  end

  defp constrained_dimensions(ar, w, h) when ar > w / h,
    do: {w, floor(w / ar)}

  defp constrained_dimensions(ar, _w, h),
    do: {floor(h * ar), h}

  defp supplemental_versions(%Image{} = image, image_format) do
    case image_format do
      "svg" ->
        {:svg,
         %{
           static_preview: full_version(image, "png"),
           svg: full_version(image, "svg")
         }}

      "gif" ->
        {:gif,
         %{
           static_preview: scaled_version(image, "png", :rendered),
           webm: full_version(image, "webm"),
           mp4: full_version(image, "mp4")
         }}

      "webm" ->
        mp4_thumbnails = thumbnail_versions(image, "mp4")

        {:webm,
         %{
           gif_previews: video_preview_versions(image),
           static_preview: scaled_version(image, "png", :rendered),
           mp4: full_version(image, "mp4"),
           mp4_thumbnails: mp4_thumbnails
         }}

      _ ->
        :none
    end
  end

  defp scaled_version_uri(%Image{} = image, image_format, version_name) do
    %{year: year, month: month, day: day} = image.created_at

    id_fragment =
      if image.hidden_from_users do
        "#{image.id}-#{image.hidden_image_key}"
      else
        "#{image.id}"
      end

    "#{image_url_root()}/#{year}/#{month}/#{day}/#{id_fragment}/#{version_name}.#{image_format}"
  end

  defp full_version_uri(%Image{} = image, image_format, short?, download?) do
    if image.hidden_from_users do
      # Hidden images don't support the view/download routes
      scaled_version_uri(image, image_format, :full)
    else
      %{year: year, month: month, day: day} = image.created_at

      view = if download?, do: "download", else: "view"
      filename = if short?, do: image.id, else: "#{image.id}__#{file_name_slug(image)}"

      "#{image_url_root()}/#{view}/#{year}/#{month}/#{day}/#{filename}.#{image_format}"
    end
  end

  defp scaled_version(%Image{} = image, image_format, version_name, options \\ []) do
    width = Keyword.get(options, :width, image.image_width)
    height = Keyword.get(options, :height, image.image_height)
    uri = scaled_version_uri(image, image_format, version_name)

    render_version(width, height, mime_type(image_format), uri)
  end

  defp full_version(%Image{} = image, image_format, options \\ []) do
    short? = Keyword.get(options, :short?, true)
    download? = Keyword.get(options, :download?, false)
    uri = full_version_uri(image, image_format, short?, download?)

    render_version(image.image_width, image.image_height, mime_type(image_format), uri)
  end

  defp render_version(width, height, mime_type, uri) do
    %{
      width: width,
      height: height,
      mime_type: mime_type,
      uri: uri
    }
  end

  defp mime_type("png"), do: "image/png"
  defp mime_type("jpg"), do: "image/jpeg"
  defp mime_type("gif"), do: "image/gif"
  defp mime_type("svg"), do: "image/svg+xml"
  defp mime_type("webm"), do: "video/webm"
  defp mime_type("mp4"), do: "video/mp4"

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
