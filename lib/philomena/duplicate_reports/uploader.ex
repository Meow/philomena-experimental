defmodule Philomena.DuplicateReports.Uploader do
  @moduledoc false

  alias Philomena.DuplicateReports.SearchQuery
  alias PhilomenaMedia.Uploader

  @doc false
  def analyze_upload(search_query, params) do
    image = Map.get(params, "image") || Map.get(params, :image)

    Uploader.analyze_upload(
      search_query,
      "image",
      image,
      &SearchQuery.image_changeset/2
    )
  end
end
