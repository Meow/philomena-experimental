defmodule Philomena.ModNotes do
  @moduledoc """
  The ModNotes context.
  """

  import Ecto.Query, warn: false
  import Philomena.Authorization, only: [authorize: 3]

  alias Philomena.Attribution.Actor
  alias Philomena.Repo
  alias Philomena.Loader
  alias Philomena.ModNotes.ModNote

  # Whitelist of the target foreign key columns a note may be filed against.
  @target_columns [:user_id, :report_id, :dnp_entry_id]

  @doc """
  Returns a list of 2-tuples of mod notes and rendered output for the target
  named by `target`, a one-entry keyword list of the target foreign key column
  and its id (e.g. `user_id: 1`).

  See `list_mod_notes/3` for more information about collection rendering.

  ## Examples

      iex> list_all_mod_notes_for_target(& &1.body, user_id: 1)
      [
        {%ModNote{body: "hello *world*"}, "hello *world*"}
      ]

  """
  def list_all_mod_notes_for_target(collection_renderer, [{column, id}]) do
    ModNote
    |> where([m], field(m, ^column) == ^id)
    |> preload(:moderator)
    |> order_by(desc: :id)
    |> Repo.all()
    |> preload_and_render(collection_renderer)
  end

  @doc """
  Returns a `m:Scrivener.Page` of 2-tuples of mod notes and rendered output
  for the query string and current pagination.

  All mod notes containing the substring `query_string` are matched and returned
  case-insensitively.

  See `list_mod_notes/3` for more information.

  ## Examples

      iex> list_mod_notes_by_query_string("quack", & &1.body, page_size: 15)
      %Scrivener.Page{}

  """
  def list_mod_notes_by_query_string(query_string, collection_renderer, pagination) do
    ModNote
    |> where([m], ilike(m.body, ^"%#{query_string}%"))
    |> list_mod_notes(collection_renderer, pagination)
  end

  @doc """
  Returns a `m:Scrivener.Page` of 2-tuples of mod notes and rendered output
  for the target named by `target`, a one-entry keyword list of the target
  foreign key column and its id (e.g. `user_id: 1`), and current pagination.

  See `list_mod_notes/3` for more information.
  """
  def list_mod_notes_for_target(collection_renderer, pagination, [{column, id}]) do
    ModNote
    |> where([m], field(m, ^column) == ^id)
    |> list_mod_notes(collection_renderer, pagination)
  end

  @doc """
  Returns a `m:Scrivener.Page` of 2-tuples of mod notes and rendered output
  for the current pagination.

  When coerced to a list and rendered as Markdown, the result may look like:

      [
        {%ModNote{body: "hello *world*"}, "hello <em>world</em>"}
      ]

  ## Examples

      iex> list_mod_notes(& &1.body, page_size: 15)
      %Scrivener.Page{}

  """
  def list_mod_notes(queryable \\ ModNote, collection_renderer, pagination) do
    mod_notes =
      queryable
      |> preload(:moderator)
      |> order_by(desc: :id)
      |> Repo.paginate(pagination)

    put_in(mod_notes.entries, preload_and_render(mod_notes, collection_renderer))
  end

  defp preload_and_render(mod_notes, collection_renderer) do
    bodies = collection_renderer.(mod_notes)
    preloaded = preload_targets(mod_notes)

    Enum.zip(preloaded, bodies)
  end

  defp preload_targets(mod_notes) do
    mod_notes
    |> Enum.to_list()
    |> Repo.preload(ModNote.target_preloads())
  end

  @doc """
  Assembles the admin mod-note listing, on behalf of `actor`, rendering each
  note's body with `collection_renderer` and paginating with `pagination`.

  Authorizes `:index` against the mod-note model first, so a viewer without
  mod-note access is `{:error, :unauthorized}`. When `params` carries both
  `"notable_type"` and `"notable_id"` the list is filtered to that notable;
  otherwise all notes are listed newest first.

  Returns `{:ok, mod_notes}` as a `m:Scrivener.Page` of `{note, rendered}`
  2-tuples, or `{:error, :unauthorized}`.
  """
  @spec load_mod_note_index(Actor.t(), map(), (list() -> list()), Repo.pagination_params()) ::
          {:ok, Scrivener.Page.t()} | {:error, :unauthorized}
  def load_mod_note_index(%Actor{} = actor, params, collection_renderer, pagination) do
    with :ok <- authorize(actor, :index, ModNote) do
      mod_notes =
        case target(params) do
          [_] = target -> list_mod_notes_for_target(collection_renderer, pagination, target)
          [] -> list_mod_notes(collection_renderer, pagination)
        end

      {:ok, mod_notes}
    end
  end

  # The one target foreign key column named in `params`, as a one-entry keyword
  # list (e.g. `[user_id: 1]`), or an empty list when none is present.
  defp target(params) do
    Enum.find_value(@target_columns, [], fn column ->
      with value when value not in [nil, ""] <- params[to_string(column)],
           {id, ""} <- Integer.parse(to_string(value)) do
        [{column, id}]
      else
        _ -> false
      end
    end)
  end

  @doc """
  Builds a changeset for a new mod note, on behalf of `actor`, seeded with the
  `"notable_type"` and `"notable_id"` from `params`.

  Authorizes `:new` against the mod-note model. Returns `{:ok, changeset}` or
  `{:error, :unauthorized}`.
  """
  @spec new_mod_note(Actor.t(), map()) ::
          {:ok, Ecto.Changeset.t()} | {:error, :unauthorized}
  def new_mod_note(%Actor{} = actor, params) do
    with :ok <- authorize(actor, :new, ModNote) do
      {:ok, change_mod_note(struct(ModNote, target(params)))}
    end
  end

  @doc """
  Gets a single mod_note.

  Raises `Ecto.NoResultsError` if the Mod note does not exist.

  ## Examples

      iex> get_mod_note!(123)
      %ModNote{}

      iex> get_mod_note!(456)
      ** (Ecto.NoResultsError)

  """
  def get_mod_note!(id), do: Repo.get!(ModNote, id)

  @doc """
  Creates a mod note on behalf of `actor`, who becomes its moderator.

  Authorizes `:create` against the mod-note model, then inserts the note.
  Returns `{:ok, mod_note}`, `{:error, :unauthorized}`, or
  `{:error, %Ecto.Changeset{}}`.

  ## Examples

      iex> create_mod_note(moderator, %{field: value})
      {:ok, %ModNote{}}

      iex> create_mod_note(moderator, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  @spec create_mod_note(Actor.t(), map()) ::
          {:ok, ModNote.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def create_mod_note(%Actor{} = actor, attrs \\ %{}) do
    with :ok <- authorize(actor, :create, ModNote) do
      %ModNote{moderator_id: actor.user.id}
      |> ModNote.creation_changeset(attrs, target(attrs))
      |> Repo.insert()
    end
  end

  @doc """
  Loads the mod note named by `id` for editing, on behalf of `actor`, pairing
  it with a change-tracking changeset for it.

  Authorizes `:edit` against the loaded note: a non-castable id is
  `{:error, :not_found}`, and a well-formed id naming no row authorizes `nil`,
  which no ordinary rule permits, so it is `{:error, :unauthorized}`
  (`{:error, :not_found}` for admins). A moderator may only touch their own
  notes.

  Returns `{:ok, {mod_note, changeset}}`, `{:error, :unauthorized}`, or
  `{:error, :not_found}`.
  """
  @spec load_mod_note_for_edit(Actor.t(), Loader.integer_id()) ::
          {:ok, {ModNote.t(), Ecto.Changeset.t()}} | {:error, :unauthorized | :not_found}
  def load_mod_note_for_edit(%Actor{} = actor, id) do
    with {:ok, mod_note} <- load_mod_note(actor, id, :edit) do
      {:ok, {mod_note, change_mod_note(mod_note)}}
    end
  end

  @doc """
  Updates the mod note named by `id`, on behalf of `actor`.

  Loading and authorization follow `load_mod_note_for_edit/2`, authorizing
  `:update`. Returns `{:ok, mod_note}`, `{:error, :unauthorized}`,
  `{:error, :not_found}`, or `{:error, %Ecto.Changeset{}}`.
  """
  @spec update_mod_note(Actor.t(), Loader.integer_id(), map()) ::
          {:ok, ModNote.t()} | {:error, :unauthorized | :not_found | Ecto.Changeset.t()}
  def update_mod_note(%Actor{} = actor, id, attrs) do
    with {:ok, mod_note} <- load_mod_note(actor, id, :update) do
      update_mod_note(mod_note, attrs)
    end
  end

  @doc """
  Updates a mod_note.

  ## Examples

      iex> update_mod_note(mod_note, %{field: new_value})
      {:ok, %ModNote{}}

      iex> update_mod_note(mod_note, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_mod_note(%ModNote{} = mod_note, attrs) do
    mod_note
    |> ModNote.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes the mod note named by `id`, on behalf of `actor`.

  Loading and authorization follow `load_mod_note_for_edit/2`, authorizing
  `:delete`. Returns `{:ok, mod_note}`, `{:error, :unauthorized}`, or
  `{:error, :not_found}`.
  """
  @spec delete_mod_note(Actor.t(), Loader.integer_id()) ::
          {:ok, ModNote.t()} | {:error, :unauthorized | :not_found}
  def delete_mod_note(%Actor{} = actor, id) do
    with {:ok, mod_note} <- load_mod_note(actor, id, :delete) do
      delete_mod_note(mod_note)
    end
  end

  @doc """
  Deletes a ModNote.

  ## Examples

      iex> delete_mod_note(mod_note)
      {:ok, %ModNote{}}

      iex> delete_mod_note(mod_note)
      {:error, %Ecto.Changeset{}}

  """
  def delete_mod_note(%ModNote{} = mod_note) do
    Repo.delete(mod_note)
  end

  # Loads the mod note named by `id` and authorizes `action`
  # against it: a non-castable id or a `nil` load the actor was permitted to act
  # on (an admin) is `{:error, :not_found}`, while a `nil` or real note the
  # actor may not act on is `{:error, :unauthorized}`.
  defp load_mod_note(actor, id, action) do
    Loader.fetch_and_authorize(ModNote, actor, action, id)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking mod_note changes.

  ## Examples

      iex> change_mod_note(mod_note)
      %Ecto.Changeset{source: %ModNote{}}

  """
  def change_mod_note(%ModNote{} = mod_note) do
    ModNote.changeset(mod_note, %{})
  end
end
