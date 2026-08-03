defmodule Philomena.Galleries do
  @moduledoc """
  The Galleries context.
  """

  import Ecto.Query, warn: false

  import Philomena.Authorization,
    only: [authorize: 3, verify_write_access: 1, verify_not_banned: 1]

  alias Ecto.Multi
  alias Philomena.Repo
  alias Philomena.Loader

  alias PhilomenaQuery.Search
  alias Philomena.Attribution.Actor
  alias Philomena.Galleries.Gallery
  alias Philomena.Galleries.GalleryPage
  alias Philomena.Galleries.Interaction
  alias Philomena.Galleries
  alias Philomena.IndexWorker
  alias Philomena.GalleryReorderWorker
  alias Philomena.IntegerId
  alias Philomena.Interactions
  alias Philomena.Notifications
  alias Philomena.Images
  alias Philomena.Images.Image
  alias Philomena.Images.Search, as: ImageSearch
  alias Philomena.Images.Search.Scope
  alias Philomena.Users.User
  alias Philomena.Reports

  use Philomena.Subscriptions,
    on_delete: :clear_gallery_notification,
    id_name: :gallery_id

  # Gets a single gallery.
  defp get_gallery!(id), do: Repo.get!(Gallery, id)

  # Creates a gallery. Visible for testing.
  @doc false
  def create_gallery(%User{} = user, attrs, _unused) do
    %Gallery{}
    |> Gallery.creation_changeset(attrs, user)
    |> Repo.insert()
    |> reindex_after_update()
  end

  # Returns an `%Ecto.Changeset{}` for tracking gallery changes.
  defp change_gallery(%Gallery{} = gallery) do
    Gallery.changeset(gallery, %{})
  end

  # Updates a gallery.
  defp update_gallery(%Gallery{} = gallery, attrs) do
    gallery
    |> Gallery.changeset(attrs)
    |> Repo.update()
    |> reindex_after_update()
  end

  # Deletes a gallery.
  @spec delete_gallery(Gallery.t(), User.t(), any()) :: {:ok, Gallery.t()} | Ecto.Multi.failure()
  @doc false
  def delete_gallery(%Gallery{} = gallery, closing_user, _unused) do
    # TODO: Visible for Eraser.erase_permanently!/2
    images =
      Interaction
      |> where(gallery_id: ^gallery.id)
      |> select([i], i.image_id)
      |> Repo.all()

    Multi.new()
    |> Multi.update_all(
      :reports,
      Reports.close_report_query(closing_user, gallery_id: gallery.id),
      []
    )
    |> Multi.delete(:gallery, gallery)
    |> Repo.transaction()
    |> case do
      {:ok, %{gallery: gallery}} ->
        unindex_gallery(gallery)
        Images.reindex_images(images)

        {:ok, gallery}

      error ->
        error
    end
  end

  # Adds the specified image to the gallery, updates image count, triggers
  # notifications, and performs necessary reindexing. The image is added at
  # the last position. Visible for testing.
  @doc false
  def add_image_to_gallery(gallery, image) do
    Multi.new()
    |> Multi.run(:gallery, fn repo, %{} ->
      gallery =
        Gallery
        |> where(id: ^gallery.id)
        |> lock("FOR UPDATE")
        |> repo.one()

      {:ok, gallery}
    end)
    |> Multi.run(:interaction, fn repo, %{} ->
      position = (last_position(gallery.id) || -1) + 1

      %Interaction{gallery_id: gallery.id}
      |> Interaction.changeset(%{"image_id" => image.id, "position" => position})
      |> repo.insert()
    end)
    |> Multi.run(:image_count, fn repo, %{} ->
      now = DateTime.utc_now()

      {count, nil} =
        Gallery
        |> where(id: ^gallery.id)
        |> repo.update_all(inc: [image_count: 1], set: [updated_at: now])

      {:ok, count}
    end)
    |> Multi.run(:notification, &notify_gallery/2)
    |> Repo.transaction()
    |> case do
      {:ok, result} ->
        Images.reindex_image(image)
        reindex_gallery(gallery)

        {:ok, result}

      error ->
        error
    end
  end

  # Removes the specified image from the gallery, updates image count,
  # and performs necessary reindexing. Visible for testing.
  @doc false
  def remove_image_from_gallery(gallery, image) do
    Multi.new()
    |> Multi.run(:gallery, fn repo, %{} ->
      gallery =
        Gallery
        |> where(id: ^gallery.id)
        |> lock("FOR UPDATE")
        |> repo.one()

      {:ok, gallery}
    end)
    |> Multi.run(:interaction, fn repo, %{} ->
      {count, nil} =
        Interaction
        |> where(gallery_id: ^gallery.id, image_id: ^image.id)
        |> repo.delete_all()

      {:ok, count}
    end)
    |> Multi.run(:image_count, fn repo, %{interaction: interaction_count} ->
      now = DateTime.utc_now()

      {count, nil} =
        Gallery
        |> where(id: ^gallery.id)
        |> repo.update_all(inc: [image_count: -interaction_count], set: [updated_at: now])

      {:ok, count}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, result} ->
        Images.reindex_image(image)
        reindex_gallery(gallery)

        {:ok, result}

      error ->
        error
    end
  end

  defp notify_gallery(_repo, %{gallery: gallery}) do
    Notifications.create_gallery_image_notification(gallery)
  end

  defp last_position(gallery_id) do
    Interaction
    |> where(gallery_id: ^gallery_id)
    |> Repo.aggregate(:max, :position)
  end

  @doc """
  Builds a change-tracking changeset for a new gallery, on behalf of `actor`.

  A banned actor gets `{:error, :ban}`; everyone else gets the changeset.

  ## Examples

      iex> new_gallery(actor)
      {:ok, %Ecto.Changeset{}}

      iex> new_gallery(banned_actor)
      {:error, :ban}

  """
  @spec new_gallery(Actor.t()) :: {:ok, Ecto.Changeset.t()} | {:error, :ban}
  def new_gallery(%Actor{} = actor) do
    with :ok <- verify_not_banned(actor) do
      {:ok, change_gallery(%Gallery{})}
    end
  end

  @doc """
  Creates a gallery, on behalf of `actor`.

  ## Examples

      iex> create_gallery(user, gallery_params)
      {:ok, %Gallery{}}

      iex> create_gallery(user, invalid_params)
      {:error, %Ecto.Changeset{}}

      iex> create_gallery(banned_user, invalid_params)
      {:error, :ban}

  """
  @spec create_gallery(Actor.t(), map()) ::
          {:ok, Gallery.t()} | {:error, :ban | :unauthorized | Ecto.Changeset.t()}
  def create_gallery(%Actor{user: user} = actor, attrs) do
    with :ok <- verify_write_access(actor),
         :ok <- authorize(actor, :create, Gallery) do
      create_gallery(user, attrs, nil)
    end
  end

  @doc """
  Updates the gallery named by `gallery_id`, on behalf of `actor`.

  On success the gallery is updated and reindexed.

  ## Examples

      iex> update_gallery(user, "1", gallery_params)
      {:ok, %Gallery{}}

      iex> update_gallery(user, "1", invalid_params)
      {:error, %Ecto.Changeset{}}

      iex> update_gallery(banned_user, "1", gallery_params)
      {:error, :ban}

      iex> update_gallery(other_user, "1", gallery_params)
      {:error, :unauthorized}

      iex> update_gallery(admin, "999999999", gallery_params)
      {:error, :not_found}

  """
  @spec update_gallery(Actor.t(), Loader.integer_id(), map() | nil) ::
          {:ok, Gallery.t()} | {:error, :ban | :unauthorized | :not_found | Ecto.Changeset.t()}
  def update_gallery(%Actor{} = actor, gallery_id, attrs) do
    with :ok <- verify_write_access(actor),
         {:ok, gallery} <- load_authorized_gallery(actor, gallery_id, :update) do
      update_gallery(gallery, attrs)
    end
  end

  @doc """
  Deletes the gallery named by `gallery_id`, on behalf of `actor`.

  Loading and authorization follow `update_gallery/3`.

  ## Examples

      iex> delete_gallery(actor, "1")
      {:ok, %Gallery{}}

  """
  @spec delete_gallery(Actor.t(), Loader.integer_id()) ::
          {:ok, Gallery.t()} | {:error, :ban | :unauthorized | :not_found}
  def delete_gallery(%Actor{} = actor, gallery_id) do
    with :ok <- verify_write_access(actor),
         {:ok, gallery} <- load_authorized_gallery(actor, gallery_id, :delete) do
      delete_gallery(gallery)
    end
  end

  @doc """
  Loads the gallery named by `gallery_id` for editing, on
  behalf of `actor`, pairing it with a change-tracking changeset for it.

  Loading and authorization otherwise follow `update_gallery/3`, authorizing `:edit`.

  ## Examples

      iex> load_gallery_for_edit(user, "1")
      {:ok, {%Gallery{}, %Ecto.Changeset{}}}

      iex> load_gallery_for_edit(banned_user, "1")
      {:error, :ban}

      iex> load_gallery_for_edit(other_user, "1")
      {:error, :unauthorized}

      iex> load_gallery_for_edit(admin, "999999999")
      {:error, :not_found}

  """
  @spec load_gallery_for_edit(Actor.t(), Loader.integer_id()) ::
          {:ok, {Gallery.t(), Ecto.Changeset.t()}}
          | {:error, :ban | :unauthorized | :not_found}
  def load_gallery_for_edit(%Actor{} = actor, gallery_id) do
    with :ok <- verify_not_banned(actor),
         {:ok, gallery} <- load_authorized_gallery(actor, gallery_id, :edit) do
      {:ok, {gallery, change_gallery(gallery)}}
    end
  end

  @doc """
  Runs the gallery listing search `params` describes, returning the
  record page with its thumbnail preloads.

  The title, creator, included-image, and description filters are read from
  `params["gallery"]`; the sort field and direction from its "sf"/"sd" keys.

  ## Examples

      iex> load_gallery_index(%{"gallery" => %{"title" => "sunset"}}, pagination)
      %Scrivener.Page{}

  """
  @spec load_gallery_index(map(), Search.pagination_params()) :: Scrivener.Page.t(Gallery.t())
  def load_gallery_index(params, pagination) do
    Gallery
    |> Search.search_definition(
      %{
        query: %{
          bool: %{
            must: parse_search(params)
          }
        },
        sort: parse_sort(params)
      },
      pagination
    )
    |> Search.search_records(preload(Gallery, thumbnail: [:sources, tags: :aliases]))
  end

  @doc """
  Searches galleries on behalf of `user`, with the query string `query_string`
  and `pagination`, sorted by creation time descending.

  An empty or missing `query_string` compiles to a match-none query, returning
  an empty page. Results are preloaded with their creator. Returns
  `{:ok, galleries}`, or `{:error, msg}` when `query_string` fails to compile.

  ## Examples

      iex> search_galleries(user, "title:sunset", pagination)
      {:ok, %Scrivener.Page{}}

      iex> search_galleries(user, ")", pagination)
      {:error, "Imbalanced parentheses."}

  """
  @spec search_galleries(Actor.t(), String.t() | nil, Repo.pagination_params()) ::
          {:ok, Scrivener.Page.t(Gallery.t())} | {:error, String.t()}
  def search_galleries(%Actor{user: user}, query_string, pagination) do
    case Philomena.Galleries.Query.compile(query_string, user: user) do
      {:ok, query} ->
        galleries =
          Gallery
          |> Search.search_definition(
            %{query: query, sort: %{created_at: :desc}},
            pagination
          )
          |> Search.search_records(preload(Gallery, [:user]))

        {:ok, galleries}

      {:error, msg} ->
        {:error, msg}
    end
  end

  @doc """
  Assembles the `GalleryPage` for the viewer described by `scope`, from
  `gallery_id`.

  The gallery's position order is merged into the scope's parameters so the
  images list, and the previous/next page probes flanking it, run in gallery
  order; interactions and subscription state are computed for the viewer, and
  the viewer's notification for the gallery is cleared as a side effect (so the
  caller must read any notification counts afterwards).

  ## Examples

      iex> load_gallery_page(user_scope, "1")
      {:ok, %GalleryPage{}}

      iex> load_gallery_page(user_scope, "999999999")
      {:error, :unauthorized}

      iex> load_gallery_page(admin_scope, "999999999")
      {:error, :not_found}

  """
  @spec load_gallery_page(Scope.t(), Loader.integer_id()) ::
          {:ok, GalleryPage.t()} | {:error, :unauthorized | :not_found}
  def load_gallery_page(%Scope{} = scope, gallery_id) do
    with {:ok, gallery} <- load_authorized_gallery(scope.user, gallery_id, :show) do
      {:ok, build_gallery_page(scope, gallery)}
    end
  end

  defp build_gallery_page(scope, gallery) do
    query = "gallery_id:#{gallery.id}"

    scope = %{
      scope
      | params:
          Map.merge(scope.params, %{
            "q" => query,
            "sf" => "gallery_id:#{gallery.id}",
            "sd" => image_sort_direction(gallery)
          })
    }

    # The synthesized gallery query is always well-formed, so a compile
    # failure here is a real bug rather than bad user input.
    {:ok, {images, _tags}} = ImageSearch.search_string(scope, query)

    limit = scope.pagination.page_size
    offset = (scope.pagination.page_number - 1) * limit

    gallery_prev = gallery_image_definition(scope, query, offset - 1)
    gallery_next = gallery_image_definition(scope, query, offset + limit)

    [images, gallery_prev, gallery_next] =
      Search.msearch_records_with_hits(
        [images, gallery_prev, gallery_next],
        [
          preload(Image, [:sources, tags: :aliases]),
          preload(Image, [:sources, tags: :aliases]),
          preload(Image, [:sources, tags: :aliases])
        ]
      )

    interactions =
      Interactions.user_interactions([images, gallery_prev, gallery_next], scope.user)

    watching = subscribed?(gallery, scope.user)

    gallery_images =
      Enum.to_list(gallery_prev) ++ Enum.to_list(images) ++ Enum.to_list(gallery_next)

    clear_gallery_notification(gallery, scope.user)

    %GalleryPage{
      gallery: gallery,
      images: images,
      gallery_images: gallery_images,
      gallery_prev: Enum.any?(gallery_prev),
      gallery_next: Enum.any?(gallery_next),
      interactions: interactions,
      watching: watching
    }
  end

  # OpenSearch rejects negative offsets but tolerates offsets past the end of
  # the result set, so the previous-page probe short-circuits to an empty
  # definition while the next-page probe runs normally.
  defp gallery_image_definition(_scope, _query, offset) when offset < 0 do
    Search.search_definition(Image, %{query: %{match_none: %{}}})
  end

  defp gallery_image_definition(scope, query, offset) do
    {:ok, {definition, _tags}} =
      ImageSearch.search_string(scope, query,
        pagination: %{page_number: offset + 1, page_size: 1}
      )

    definition
  end

  defp load_authorized_gallery(actor, gallery_id, action) do
    case IntegerId.parse(gallery_id) do
      {:ok, id} ->
        gallery =
          Gallery
          |> preload([:user, thumbnail: [:sources, tags: :aliases]])
          |> Repo.get(id)

        with :ok <- authorize(actor, action, gallery),
             %Gallery{} <- gallery do
          {:ok, gallery}
        else
          {:error, :unauthorized} -> {:error, :unauthorized}
          nil -> {:error, :not_found}
        end

      :error ->
        {:error, :not_found}
    end
  end

  defp parse_search(%{"gallery" => gallery_params}) do
    parse_title(gallery_params) ++
      parse_creator(gallery_params) ++
      parse_included_image(gallery_params) ++
      parse_description(gallery_params)
  end

  defp parse_search(_params), do: [%{match_all: %{}}]

  defp parse_title(%{"title" => title}) when is_binary(title) and title not in [nil, ""],
    do: [%{wildcard: %{title: "*" <> String.downcase(title) <> "*"}}]

  defp parse_title(_params), do: []

  defp parse_creator(%{"creator" => creator})
       when is_binary(creator) and creator not in [nil, ""],
       do: [%{term: %{creator: String.downcase(creator)}}]

  defp parse_creator(_params), do: []

  defp parse_included_image(%{"include_image" => image_id})
       when is_binary(image_id) and image_id not in [nil, ""] do
    with {image_id, _rest} <- Integer.parse(image_id) do
      [%{term: %{image_ids: image_id}}]
    else
      _ ->
        []
    end
  end

  defp parse_included_image(_params), do: []

  defp parse_description(%{"description" => description})
       when is_binary(description) and description not in [nil, ""],
       do: [%{match_phrase: %{description: description}}]

  defp parse_description(_params), do: []

  defp parse_sort(%{"gallery" => %{"sf" => "created_at", "sd" => sd}}) when sd in ~w(desc asc) do
    [%{created_at: sd}, %{id: sd}]
  end

  defp parse_sort(%{"gallery" => %{"sf" => sf, "sd" => sd}})
       when sf in ~w(updated_at image_count subscriber_count _score) and
              sd in ~w(desc asc) do
    [%{sf => sd}, %{created_at: sd}, %{id: sd}]
  end

  defp parse_sort(_params) do
    [%{created_at: :desc}, %{id: :desc}]
  end

  defp image_sort_direction(%{order_position_asc: true}), do: "asc"
  defp image_sort_direction(_gallery), do: "desc"

  @doc """
  Lists `user`'s galleries, most recently updated first, pairing each with
  whether it already contains `image`.

  Anonymous viewers have no galleries.

  ## Examples

      iex> user_image_galleries(user, image)
      [{%Gallery{}, true}, {%Gallery{}, false}]

      iex> user_image_galleries(nil, image)
      []

  """
  @spec user_image_galleries(User.t() | nil, Image.t()) :: [{Gallery.t(), boolean()}]
  def user_image_galleries(nil, _image), do: []

  def user_image_galleries(user, image) do
    # FIXME: unbounded query.
    Gallery
    |> where(user_id: ^user.id)
    |> join(
      :inner_lateral,
      [g],
      _ in fragment(
        "SELECT EXISTS(SELECT 1 FROM gallery_interactions gi WHERE gi.image_id = ? AND gi.gallery_id = ?)",
        ^image.id,
        g.id
      ),
      on: true
    )
    |> select([g, e], {g, e.exists})
    |> order_by(desc: :updated_at)
    |> Repo.all()
  end

  @doc """
  Updates gallery search indices when a user's name changes.

  ## Examples

      iex> user_name_reindex("old_username", "new_username")
      :ok

  """
  def user_name_reindex(old_name, new_name) do
    data = Galleries.SearchIndex.user_name_update_by_query(old_name, new_name)

    Search.update_by_query(Gallery, data.query, data.set_replacements, data.replacements)
  end

  defp reindex_after_update({:ok, gallery}) do
    reindex_gallery(gallery)

    {:ok, gallery}
  end

  defp reindex_after_update(error) do
    error
  end

  @doc """
  Queues a gallery for reindexing.

  Adds the gallery to the indexing queue to update its search index.

  ## Examples

      iex> reindex_gallery(gallery)
      %Gallery{}

  """
  def reindex_gallery(%Gallery{} = gallery) do
    Exq.enqueue(Exq, "indexing", IndexWorker, ["Galleries", "id", [gallery.id]])

    gallery
  end

  @doc """
  Removes a gallery from the search index.

  Deletes the gallery's document from the search index.

  ## Examples

      iex> unindex_gallery(gallery)
      %Gallery{}

  """
  def unindex_gallery(%Gallery{} = gallery) do
    Search.delete_document(gallery.id, Gallery)

    gallery
  end

  @doc """
  Returns a list of associations to preload when indexing galleries.

  ## Examples

      iex> indexing_preloads()
      [:subscribers, :user, :interactions]

  """
  def indexing_preloads do
    [:subscribers, :user, :interactions]
  end

  @doc """
  Reindexes galleries based on a column condition.

  Updates the search index for all galleries matching the given column condition.
  Used for batch reindexing of galleries.

  ## Examples

      iex> perform_reindex(:id, [1, 2, 3])
      {:ok, [%Gallery{}, ...]}

  """
  def perform_reindex(column, condition) do
    Gallery
    |> preload(^indexing_preloads())
    |> where([g], field(g, ^column) in ^condition)
    |> Search.reindex(Gallery)
  end

  @doc """
  Adds the image named by `image_id` to the gallery named by
  `gallery_id`, on behalf of `actor`.

  On success, the image is added at the last position.

  ## Examples

      iex> add_image_to_gallery(actor, "1", "42")
      {:ok, %{gallery: %Gallery{}, ...}}

      iex> add_image_to_gallery(banned_actor, "1", "42")
      {:error, :ban}

      iex> add_image_to_gallery(other_actor, "1", "42")
      {:error, :unauthorized}

      iex> add_image_to_gallery(admin_actor, "999999999", "42")
      {:error, :not_found}

  """
  @spec add_image_to_gallery(
          actor :: Actor.t(),
          gallery_id :: Loader.integer_id(),
          image_id :: Loader.integer_id()
        ) ::
          {:ok, map()}
          | {:error, :ban | :unauthorized | :not_found}
          | Ecto.Multi.failure()
  def add_image_to_gallery(%Actor{} = actor, gallery_id, image_id) do
    with :ok <- verify_write_access(actor),
         {:ok, gallery} <- load_authorized_gallery(actor, gallery_id, :edit),
         {:ok, image} <- load_authorized_image(actor, image_id) do
      add_image_to_gallery(gallery, image)
    end
  end

  @doc """
  Removes the image named by `image_id` from the gallery named
  by `gallery_id`, on behalf of `actor`.

  Loading and authorization follow `add_image_to_gallery/3`. Removal is
  idempotent: an image not in the gallery is a clean success.

  ## Examples

      iex> remove_image_from_gallery(actor, "1", "42")
      {:ok, %{gallery: %Gallery{}, ...}}

  """
  @spec remove_image_from_gallery(
          actor :: Actor.t(),
          gallery_id :: Loader.integer_id(),
          image_id :: Loader.integer_id()
        ) ::
          {:ok, map()}
          | {:error, :ban | :unauthorized | :not_found}
          | Ecto.Multi.failure()
  def remove_image_from_gallery(%Actor{} = actor, gallery_id, image_id) do
    with :ok <- verify_write_access(actor),
         {:ok, gallery} <- load_authorized_gallery(actor, gallery_id, :edit),
         {:ok, image} <- load_authorized_image(actor, image_id) do
      remove_image_from_gallery(gallery, image)
    end
  end

  @doc """
  Queues a reorder of the gallery named by `gallery_id` to the
  order given by `image_ids`, on behalf of `actor`.

  ## Examples

      iex> reorder_gallery(actor, "1", [3, 1, 2])
      {:ok, %Gallery{}}

  """
  @spec reorder_gallery(Actor.t(), Loader.integer_id(), [integer()]) ::
          {:ok, Gallery.t()} | {:error, :ban | :unauthorized | :not_found}
  def reorder_gallery(%Actor{} = actor, gallery_id, image_ids) do
    with :ok <- verify_write_access(actor),
         {:ok, gallery} <- load_authorized_gallery(actor, gallery_id, :edit) do
      {:ok, reorder_gallery(gallery, image_ids)}
    end
  end

  @doc """
  Queues a gallery reorder operation.
  Returns the gallery struct unchanged, for use in a pipeline.

  ## Examples

      iex> reorder_gallery(gallery, [1, 2, 3])
      %Gallery{}

  """
  def reorder_gallery(gallery, image_ids) do
    Exq.enqueue(Exq, "indexing", GalleryReorderWorker, [gallery.id, image_ids])

    gallery
  end

  @doc """
  Performs the actual reordering of images in a gallery.

  Reorders the gallery's images according to the provided image IDs list, updating
  positions while maintaining relative order for unspecified images. Handles position
  updates efficiently and reindexes only the affected images.

  ## Examples

      iex> perform_reorder(gallery_id, [3, 1, 2])
      :ok

  """
  def perform_reorder(gallery_id, image_ids) do
    gallery = get_gallery!(gallery_id)

    interactions =
      Interaction
      |> where([gi], gi.image_id in ^image_ids and gi.gallery_id == ^gallery.id)
      |> order_by(^position_order(gallery))
      |> Repo.all()

    interaction_positions =
      interactions
      |> Enum.with_index()
      |> Map.new(fn {interaction, index} -> {index, interaction.position} end)

    images_present = Map.new(interactions, &{&1.image_id, true})

    requested =
      image_ids
      |> Enum.filter(&images_present[&1])
      |> Enum.with_index()
      |> Map.new()

    changes =
      interactions
      |> Enum.with_index()
      |> Enum.flat_map(fn {interaction, current_index} ->
        new_index = requested[interaction.image_id]

        if new_index == current_index do
          []
        else
          [
            [
              id: interaction.id,
              position: interaction_positions[new_index]
            ]
          ]
        end
      end)

    changes
    |> Enum.each(fn change ->
      id = Keyword.fetch!(change, :id)
      change = Keyword.delete(change, :id)

      Interaction
      |> where([i], i.id == ^id)
      |> Repo.update_all(set: change)
    end)

    # Do the update in a single statement
    # Repo.insert_all(
    #   Interaction,
    #   changes,
    #   on_conflict: {:replace, [:position]},
    #   conflict_target: [:id]
    # )

    # Now update all the associated images
    Images.reindex_images(Map.keys(requested))

    :ok
  end

  defp position_order(%{order_position_asc: true}), do: [asc: :position]
  defp position_order(_gallery), do: [desc: :position]

  @doc """
  Clears `user`'s unread notifications for the gallery named by
  `gallery_id`.

  The gallery is loaded by id with no authorization: any authenticated user may
  mark any gallery read.

  ## Examples

      iex> mark_gallery_read(user, "1")
      {:ok, %Gallery{}}

      iex> mark_gallery_read(user, "nonexistent")
      {:error, :not_found}

  """
  @spec mark_gallery_read(Actor.t(), Loader.integer_id()) ::
          {:ok, Gallery.t()} | {:error, :not_found}
  def mark_gallery_read(%Actor{user: user}, gallery_id) do
    with {:ok, id} <- IntegerId.parse(gallery_id),
         %Gallery{} = gallery <- Repo.get(Gallery, id) do
      clear_gallery_notification(gallery, user)
      {:ok, gallery}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Subscribes `user` to the gallery named by `gallery_id`.

  ## Examples

      iex> subscribe_gallery(user, "1")
      {:ok, %Gallery{}}

  """
  @spec subscribe_gallery(Actor.t(), Loader.integer_id()) ::
          {:ok, Gallery.t()} | {:error, :unauthorized | :not_found | Ecto.Changeset.t()}
  def subscribe_gallery(%Actor{} = actor, gallery_id) do
    with {:ok, gallery} <- load_authorized_gallery(actor, gallery_id, :show),
         {:ok, _subscription} <- create_subscription(gallery, actor.user) do
      {:ok, gallery}
    end
  end

  @doc """
  Unsubscribes `user` from the gallery named by `gallery_id`.

  ## Examples

      iex> unsubscribe_gallery(user, "1")
      {:ok, %Gallery{}}

  """
  @spec unsubscribe_gallery(Actor.t(), Loader.integer_id()) ::
          {:ok, Gallery.t()} | {:error, :unauthorized | :not_found}
  def unsubscribe_gallery(%Actor{} = actor, gallery_id) do
    with {:ok, gallery} <- load_authorized_gallery(actor, gallery_id, :show) do
      # Deletion is idempotent and cannot fail; the hard match crashes if it does.
      {:ok, _subscription} = delete_subscription(gallery, actor.user)
      {:ok, gallery}
    end
  end

  @doc """
  Removes all gallery notifications for a given gallery and user.

  ## Examples

      iex> clear_gallery_notification(gallery, user)
      :ok

  """
  def clear_gallery_notification(%Gallery{} = gallery, user) do
    Notifications.clear_gallery_image_notification(gallery, user)
    :ok
  end

  defp load_authorized_image(actor, image_id) do
    Loader.fetch_and_authorize(Image, actor, :show, image_id)
  end
end
