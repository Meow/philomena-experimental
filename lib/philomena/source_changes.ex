defmodule Philomena.SourceChanges do
  @moduledoc """
  The SourceChanges context.
  """

  import Ecto.Query, warn: false

  import Philomena.Authorization, only: [authorize: 3]

  alias Philomena.Repo
  alias Philomena.IntegerId
  alias Philomena.Images.Image
  alias Philomena.Users.User
  alias Philomena.SourceChanges.SourceChange

  @doc """
  Lists the source changes recorded on the image named by `image_id`, newest
  first, on behalf of `actor` (a user, or `nil` for an anonymous visitor).

  The image is loaded by id and authorized for `:show`. A non-castable or
  out-of-range id is `{:error, :not_found}`. A well-formed but unknown id is
  authorized as a `nil` load: an actor who may not `:show` it gets
  `{:error, :unauthorized}`, while an actor permitted to act on the `nil` load
  gets `{:error, :not_found}`. `pagination` is Scrivener pagination data passed
  through to `Repo.paginate/2`.

  Returns `{:ok, {image, source_changes}}` where `source_changes` is a paginated
  set with its user and image associations preloaded for rendering.

  ## Examples

      iex> image_source_changes(user, "42", page: 1, page_size: 25)
      {:ok, {%Image{}, %Scrivener.Page{}}}

      iex> image_source_changes(user, "999999999", page: 1, page_size: 25)
      {:error, :unauthorized}

  """
  @spec image_source_changes(User.t() | nil, String.t() | integer(), keyword() | map()) ::
          {:ok, {Image.t(), Scrivener.Page.t()}}
          | {:error, :unauthorized | :not_found}
  def image_source_changes(actor, image_id, pagination) do
    with {:ok, id} <- IntegerId.parse(image_id),
         image = Repo.get(Image, id),
         :ok <- authorize(actor, :show, image),
         %Image{} <- image do
      source_changes =
        SourceChange
        |> where(image_id: ^image.id)
        |> preload([:user, image: [:user, :sources, tags: :aliases]])
        |> order_by(desc: :id)
        |> Repo.paginate(pagination)

      {:ok, {image, source_changes}}
    else
      # Non-castable id, or a `nil` load the actor was permitted to act on.
      shape when shape in [:error, nil] -> {:error, :not_found}
      {:error, :unauthorized} -> {:error, :unauthorized}
    end
  end

  @doc """
  Gets a single source_change.

  Raises `Ecto.NoResultsError` if the Source change does not exist.

  ## Examples

      iex> get_source_change!(123)
      %SourceChange{}

      iex> get_source_change!(456)
      ** (Ecto.NoResultsError)

  """
  def get_source_change!(id), do: Repo.get!(SourceChange, id)

  @doc """
  Creates a source_change.

  ## Examples

      iex> create_source_change(%{field: value})
      {:ok, %SourceChange{}}

      iex> create_source_change(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_source_change(attrs \\ %{}) do
    %SourceChange{}
    |> SourceChange.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a source_change.

  ## Examples

      iex> update_source_change(source_change, %{field: new_value})
      {:ok, %SourceChange{}}

      iex> update_source_change(source_change, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_source_change(%SourceChange{} = source_change, attrs) do
    source_change
    |> SourceChange.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a SourceChange.

  ## Examples

      iex> delete_source_change(source_change)
      {:ok, %SourceChange{}}

      iex> delete_source_change(source_change)
      {:error, %Ecto.Changeset{}}

  """
  def delete_source_change(%SourceChange{} = source_change) do
    Repo.delete(source_change)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking source_change changes.

  ## Examples

      iex> change_source_change(source_change)
      %Ecto.Changeset{source: %SourceChange{}}

  """
  def change_source_change(%SourceChange{} = source_change) do
    SourceChange.changeset(source_change, %{})
  end
end
