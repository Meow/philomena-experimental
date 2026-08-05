defmodule Philomena.ModNotes do
  @moduledoc """
  Staff notes attached to users, reports, and DNP entries.

  Target selection is represented by a typed `{type, id}` descriptor and every
  target is safely loaded and separately authorized. Note writes are attributed
  to the acting staff member and transactionally coupled to their moderation
  audit record.
  """

  import Ecto.Query, warn: false
  import Philomena.Authorization, only: [authorize: 3, verify_write_access: 1]

  alias Ecto.Multi
  alias Philomena.Attribution.Actor
  alias Philomena.DnpEntries.DnpEntry
  alias Philomena.Loader
  alias Philomena.ModerationLogs
  alias Philomena.ModNotes.ModNote
  alias Philomena.Repo
  alias Philomena.Reports.Report
  alias Philomena.Users.User

  @target_definitions [
    user: {User, :user_id},
    report: {Report, :report_id},
    dnp_entry: {DnpEntry, :dnp_entry_id}
  ]
  @embedded_page_size 250

  @typedoc "A supported note-target type and safely parseable database ID."
  @type target :: {:user | :report | :dnp_entry, Loader.integer_id()}

  defp target_params(params) do
    Enum.flat_map(@target_definitions, fn {type, {_schema, column}} ->
      value = Map.get(params, to_string(column), Map.get(params, column))

      if value in [nil, ""] do
        []
      else
        [{type, value}]
      end
    end)
  end

  defp parse_targets(params) do
    Enum.reduce_while(target_params(params), {:ok, []}, fn {type, value}, {:ok, targets} ->
      case Philomena.IntegerId.parse(value) do
        {:ok, id} -> {:cont, {:ok, [{type, id} | targets]}}
        :error -> {:halt, {:error, :not_found}}
      end
    end)
  end

  defp target_definition(type) do
    Keyword.fetch!(@target_definitions, type)
  end

  defp target_changes(targets) do
    Enum.map(targets, fn {type, id} ->
      {_schema, column} = target_definition(type)
      {column, id}
    end)
  end

  defp load_target(actor, {type, id}, action) do
    {schema, _column} = target_definition(type)
    Loader.fetch_and_authorize(schema, actor, action, id)
  end

  defp authorize_targets(actor, targets, action) do
    Enum.reduce_while(targets, :ok, fn target, :ok ->
      case load_target(actor, target, action) do
        {:ok, _record} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp target_query({type, id}) do
    {_schema, column} = target_definition(type)
    where(ModNote, [note], field(note, ^column) == ^id)
  end

  defp ordered_notes(queryable) do
    queryable
    |> preload(:moderator)
    |> order_by(desc: :id)
  end

  defp render_notes(notes, collection_renderer) do
    preloaded = Repo.preload(notes, ModNote.target_preloads())
    rendered = collection_renderer.(preloaded)
    Enum.zip(preloaded, rendered)
  end

  defp paginate_notes(queryable, collection_renderer, pagination) do
    page = queryable |> ordered_notes() |> Repo.paginate(pagination)
    %{page | entries: render_notes(page.entries, collection_renderer)}
  end

  defp change_mod_note(%ModNote{} = mod_note) do
    ModNote.changeset(mod_note, %{})
  end

  defp creation_changeset(%Actor{user: %User{} = moderator}, attrs, targets) do
    %ModNote{moderator_id: moderator.id}
    |> ModNote.creation_changeset(attrs, target_changes(targets))
  end

  defp update_mod_note_changeset(%ModNote{} = mod_note, attrs) do
    ModNote.changeset(mod_note, attrs)
  end

  defp load_mod_note(actor, id, action) do
    Loader.fetch_and_authorize(ModNote, actor, action, id, ModNote.target_preloads())
  end

  defp target_label([{type, id}]) do
    type
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> then(&"#{&1} #{id}")
  end

  defp target_label(_targets), do: "invalid target"

  defp transact_note(multi, step) do
    case Repo.transact(multi) do
      {:ok, %{^step => note}} -> {:ok, note}
      {:error, ^step, %Ecto.Changeset{} = changeset, _changes} -> {:error, changeset}
      {:error, :moderation_log, %Ecto.Changeset{} = changeset, _changes} -> {:error, changeset}
    end
  end

  defp index_target_status(_actor, []), do: :ok

  defp index_target_status(actor, [_target] = targets) do
    authorize_targets(actor, targets, :show_mod_notes)
  end

  defp index_target_status(_actor, _multiple_targets), do: {:error, :not_found}

  defp new_target_status(_actor, []), do: :ok

  defp new_target_status(actor, [_target] = targets),
    do: authorize_targets(actor, targets, :annotate)

  defp new_target_status(_actor, _multiple_targets), do: {:error, :not_found}

  defp create_target_status(actor, attrs, []) do
    {:error, creation_changeset(actor, attrs, [])}
  end

  defp create_target_status(actor, _attrs, [_target] = targets) do
    authorize_targets(actor, targets, :annotate)
  end

  defp create_target_status(actor, attrs, targets) do
    {:error, creation_changeset(actor, attrs, targets)}
  end

  @doc """
  Returns up to 250 newest notes for `target`, rendered for an embedded page.

  The actor must be allowed to index notes and to view notes for the safely
  loaded target. Malformed and missing target IDs are `{:error, :not_found}`.
  History is retained indefinitely; only this embedded summary is bounded.

  ## Examples

      iex> list_for_target(moderator, {:user, "12"}, renderer)
      {:ok, [{%ModNote{}, "rendered body"}]}

      iex> list_for_target(user, {:user, "12"}, renderer)
      {:error, :unauthorized}

  """
  @spec list_for_target(Actor.t(), target(), (list(ModNote.t()) -> list(term()))) ::
          {:ok, [{ModNote.t(), term()}]} | {:error, :not_found | :unauthorized}
  def list_for_target(%Actor{} = actor, {type, id}, collection_renderer)
      when type in [:user, :report, :dnp_entry] do
    target = {type, id}

    with :ok <- authorize(actor, :index, ModNote),
         {:ok, _record} <- load_target(actor, target, :show_mod_notes) do
      notes =
        target
        |> target_query()
        |> ordered_notes()
        |> limit(@embedded_page_size)
        |> Repo.all()

      {:ok, render_notes(notes, collection_renderer)}
    end
  end

  @doc """
  Loads the paginated staff note index, optionally scoped to one target.

  A target filter is one of `user_id`, `report_id`, or `dnp_entry_id`. It is
  safely parsed, loaded, and authorized; multiple, malformed, or missing targets
  return `{:error, :not_found}`. With no filter, all notes are returned newest
  first.

  ## Examples

      iex> load_mod_note_index(moderator, %{"user_id" => "12"}, renderer, pagination)
      {:ok, %Scrivener.Page{}}

      iex> load_mod_note_index(user, %{}, renderer, pagination)
      {:error, :unauthorized}

  """
  @spec load_mod_note_index(
          Actor.t(),
          map(),
          (list(ModNote.t()) -> list(term())),
          Repo.pagination_params()
        ) :: {:ok, Scrivener.Page.t()} | {:error, :not_found | :unauthorized}
  def load_mod_note_index(%Actor{} = actor, params, collection_renderer, pagination) do
    with :ok <- authorize(actor, :index, ModNote),
         {:ok, targets} <- parse_targets(params),
         :ok <- index_target_status(actor, targets) do
      queryable = if targets == [], do: ModNote, else: target_query(hd(targets))
      {:ok, paginate_notes(queryable, collection_renderer, pagination)}
    end
  end

  @doc """
  Builds a new-note changeset for an optional target selected in `params`.

  When supplied, the target is safely loaded and authorized with `:annotate`.
  A request without a target intentionally returns a blank changeset whose
  create-time validation will require one.

  ## Examples

      iex> new_mod_note(moderator, %{"report_id" => "7"})
      {:ok, %Ecto.Changeset{}}

      iex> new_mod_note(user, %{})
      {:error, :unauthorized}

  """
  @spec new_mod_note(Actor.t(), map()) ::
          {:ok, Ecto.Changeset.t()} | {:error, :ban | :not_found | :unauthorized}
  def new_mod_note(%Actor{} = actor, params) do
    with :ok <- verify_write_access(actor),
         :ok <- authorize(actor, :new, ModNote),
         {:ok, targets} <- parse_targets(params),
         :ok <- new_target_status(actor, targets) do
      {:ok, creation_changeset(actor, %{}, targets)}
    end
  end

  @doc """
  Creates an attributed note and its moderation log in one transaction.

  Exactly one existing, authorized target is required. No target or multiple
  targets produce an invalid changeset; malformed and missing IDs are
  `{:error, :not_found}`.

  ## Examples

      iex> create_mod_note(moderator, %{"user_id" => "12", "body" => "Watching"})
      {:ok, %ModNote{}}

      iex> create_mod_note(user, attrs)
      {:error, :unauthorized}

  """
  @spec create_mod_note(Actor.t(), map()) ::
          {:ok, ModNote.t()}
          | {:error, :ban | :not_found | :unauthorized | Ecto.Changeset.t()}
  def create_mod_note(%Actor{} = actor, attrs \\ %{}) do
    with :ok <- verify_write_access(actor),
         :ok <- authorize(actor, :create, ModNote),
         {:ok, targets} <- parse_targets(attrs),
         :ok <- create_target_status(actor, attrs, targets) do
      changeset = creation_changeset(actor, attrs, targets)

      Multi.new()
      |> Multi.insert(:mod_note, changeset)
      |> ModerationLogs.put_log(
        :moderation_log,
        actor,
        "ModNote:create",
        "/admin/mod_notes",
        "Created mod note for #{target_label(targets)}"
      )
      |> transact_note(:mod_note)
    end
  end

  @doc """
  Loads an authorized note and edit changeset for `actor`.

  ## Examples

      iex> load_mod_note_for_edit(moderator, "1")
      {:ok, {%ModNote{}, %Ecto.Changeset{}}}

      iex> load_mod_note_for_edit(user, "1")
      {:error, :unauthorized}

  """
  @spec load_mod_note_for_edit(Actor.t(), Loader.integer_id()) ::
          {:ok, {ModNote.t(), Ecto.Changeset.t()}}
          | {:error, :ban | :not_found | :unauthorized}
  def load_mod_note_for_edit(%Actor{} = actor, id) do
    with :ok <- verify_write_access(actor),
         {:ok, mod_note} <- load_mod_note(actor, id, :edit) do
      {:ok, {mod_note, change_mod_note(mod_note)}}
    end
  end

  @doc """
  Updates a note and appends its audit record in the same transaction.

  ## Examples

      iex> update_mod_note(moderator, "1", %{"body" => "Updated"})
      {:ok, %ModNote{}}

      iex> update_mod_note(user, "1", attrs)
      {:error, :unauthorized}

  """
  @spec update_mod_note(Actor.t(), Loader.integer_id(), map()) ::
          {:ok, ModNote.t()}
          | {:error, :ban | :not_found | :unauthorized | Ecto.Changeset.t()}
  def update_mod_note(%Actor{} = actor, id, attrs) do
    with :ok <- verify_write_access(actor),
         {:ok, mod_note} <- load_mod_note(actor, id, :update) do
      Multi.new()
      |> Multi.update(:mod_note, update_mod_note_changeset(mod_note, attrs))
      |> ModerationLogs.put_log(
        :moderation_log,
        actor,
        "ModNote:update",
        "/admin/mod_notes/#{mod_note.id}",
        "Updated mod note #{mod_note.id}"
      )
      |> transact_note(:mod_note)
    end
  end

  @doc """
  Deletes a note and appends its audit record in the same transaction.

  ## Examples

      iex> delete_mod_note(moderator, "1")
      {:ok, %ModNote{}}

      iex> delete_mod_note(user, "1")
      {:error, :unauthorized}

  """
  @spec delete_mod_note(Actor.t(), Loader.integer_id()) ::
          {:ok, ModNote.t()}
          | {:error, :ban | :not_found | :unauthorized | Ecto.Changeset.t()}
  def delete_mod_note(%Actor{} = actor, id) do
    with :ok <- verify_write_access(actor),
         {:ok, mod_note} <- load_mod_note(actor, id, :delete) do
      Multi.new()
      |> Multi.delete(:mod_note, mod_note)
      |> ModerationLogs.put_log(
        :moderation_log,
        actor,
        "ModNote:delete",
        "/admin/mod_notes/#{mod_note.id}",
        "Deleted mod note #{mod_note.id}"
      )
      |> transact_note(:mod_note)
    end
  end
end
