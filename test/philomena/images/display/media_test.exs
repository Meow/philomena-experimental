defmodule Philomena.Images.Display.MediaTest do
  use ExUnit.Case, async: true

  alias Philomena.Images.Display.Media
  alias Philomena.Images.Image
  alias Philomena.Tags.Tag

  @created_at ~U[2024-01-02 03:04:05Z]

  defp image(attrs \\ %{}) do
    struct!(
      %Image{
        id: 42,
        created_at: @created_at,
        image_width: 1000,
        image_height: 500,
        image_aspect_ratio: 2.0,
        image_format: "png",
        thumbnails_generated: true,
        processed: true,
        duplication_checked: true,
        hidden_from_users: false,
        destroyed_content: false,
        tags: [
          %Tag{slug: "zebra", name: "zebra", category: "species"},
          %Tag{slug: "safe", name: "safe", category: "rating"},
          %Tag{slug: "artist:foo+bar", name: "artist:foo bar", category: "origin"}
        ]
      },
      attrs
    )
  end

  defp root, do: Application.get_env(:philomena, :image_url_root) || ""

  defp exact(image, version, format \\ nil) do
    format = format || image.image_format

    id_fragment =
      if image.hidden_from_users,
        do: "#{image.id}-#{image.hidden_image_key}",
        else: "#{image.id}"

    "#{root()}/2024/1/2/#{id_fragment}/#{version}.#{format}"
  end

  describe "render/2" do
    test "returns documented file and thumbnail shapes for a public image" do
      image = image()

      assert %Media{
               view_uris: {:file_uris, view_uris},
               download_uris: {:file_uris, download_uris},
               supplemental_uris: :none,
               thumbnails: {:thumbnails, thumbnails},
               rendered?: true,
               optimized?: true,
               duplication_checked?: true
             } = Media.render(image, false)

      assert view_uris == %{
               short: "#{root()}/view/2024/1/2/42.png",
               long: "#{root()}/view/2024/1/2/42__safe_artistfoo+bar_zebra.png"
             }

      assert download_uris == %{
               short: "#{root()}/download/2024/1/2/42.png",
               long: "#{root()}/download/2024/1/2/42__safe_artistfoo+bar_zebra.png"
             }

      assert Map.keys(thumbnails) |> Enum.sort() ==
               [:full, :large, :medium, :small, :tall, :thumb, :thumb_small, :thumb_tiny]

      assert thumbnails[:thumb] == %{
               uri: exact(image, :thumb),
               width: 250,
               height: 125
             }

      assert thumbnails[:medium] == %{
               uri: exact(image, :medium),
               width: 800,
               height: 400
             }

      assert thumbnails[:large] == %{
               uri: "#{root()}/view/2024/1/2/42.png",
               width: 1000,
               height: 500
             }

      assert thumbnails[:full] == %{
               uri: "#{root()}/view/2024/1/2/42.png",
               width: 1000,
               height: 500
             }
    end

    test "calculates constrained dimensions from a portrait aspect ratio" do
      image = image(image_width: 500, image_height: 1000, image_aspect_ratio: 0.5)
      assert {:thumbnails, %{thumb: thumb}} = Media.render(image, false).thumbnails

      assert thumb == %{uri: exact(image, :thumb), width: 125, height: 250}
    end

    test "omits every media path before thumbnails are generated" do
      result = Media.render(image(thumbnails_generated: false, processed: false), false)

      assert result.view_uris == :not_rendered
      assert result.download_uris == :not_rendered
      assert result.supplemental_uris == :not_rendered
      assert result.thumbnails == :not_rendered
      assert result.rendered? == false
      assert result.optimized? == false
    end

    test "redacts every media path for a hidden image unless explicitly revealed" do
      image = image(hidden_from_users: true, hidden_image_key: "hidden-secret")

      result = Media.render(image, false)

      assert result.view_uris == :not_available
      assert result.download_uris == :not_available
      assert result.supplemental_uris == :not_available
      assert result.thumbnails == :not_available
      refute inspect(result) =~ image.hidden_image_key

      revealed = Media.render(image, true)

      assert {:file_uris, %{short: short}} = revealed.view_uris
      assert short == exact(image, :full)
      assert short =~ image.hidden_image_key
      assert {:thumbnails, %{thumb: %{uri: thumb_path}}} = revealed.thumbnails
      assert thumb_path =~ image.hidden_image_key
    end

    test "omits every media path for destroyed content" do
      result = Media.render(image(destroyed_content: true), false)

      assert result.view_uris == :not_available
      assert result.download_uris == :not_available
      assert result.supplemental_uris == :not_available
      assert result.thumbnails == :not_available

      result = Media.render(image(destroyed_content: true), true)

      assert result.view_uris == :destroyed
      assert result.download_uris == :destroyed
      assert result.supplemental_uris == :destroyed
      assert result.thumbnails == :destroyed
    end
  end

  describe "format-specific supplemental paths" do
    test "provides a rendered PNG path for SVG images" do
      result = Media.render(image(image_format: "SVG"), false)

      assert {:svg, %{static_preview: rendered, svg: svg}} = result.supplemental_uris
      assert rendered == "#{root()}/view/2024/1/2/42.png"
      assert svg == "#{root()}/view/2024/1/2/42.svg"
      assert {:file_uris, %{short: view, long: view_long}} = result.view_uris
      assert view == "#{root()}/view/2024/1/2/42.png"
      assert view_long == "#{root()}/view/2024/1/2/42__safe_artistfoo+bar_zebra.png"
      assert {:file_uris, %{short: download}} = result.download_uris
      assert download == "#{root()}/download/2024/1/2/42.svg"

      assert {:thumbnails, %{full: %{uri: full_path}}} = result.thumbnails
      assert full_path == "#{root()}/view/2024/1/2/42.png"
      assert {:thumbnails, %{thumb: %{uri: thumb_path}}} = result.thumbnails
      assert thumb_path == exact(image(image_format: "SVG"), :thumb, "png")
    end

    test "provides rendered, WebM, and MP4 paths for GIF images" do
      image = image(image_format: "gif")
      assert {:gif, paths} = Media.render(image, false).supplemental_uris

      assert paths == %{
               static_preview: exact(image, :rendered, "png"),
               webm: "#{root()}/view/2024/1/2/42.webm",
               mp4: "#{root()}/view/2024/1/2/42.mp4"
             }
    end

    test "provides rendered, MP4, and GIF preview paths for WebM images" do
      image = image(image_format: "webm")

      assert {:webm, %{static_preview: rendered, mp4: mp4, gif_previews: previews}} =
               Media.render(image, false).supplemental_uris

      assert rendered == exact(image, :rendered, "png")
      assert mp4 == "#{root()}/view/2024/1/2/42.mp4"
      assert Map.keys(previews) |> Enum.sort() == [:thumb, :thumb_small, :thumb_tiny]
      assert previews[:thumb] == %{uri: exact(image, :thumb, "gif"), width: 250, height: 125}
    end
  end
end
