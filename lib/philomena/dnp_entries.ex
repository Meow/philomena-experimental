defmodule Philomena.DnpEntries do
  @moduledoc """
  The DnpEntries context.
  """

  import Ecto.Query, warn: false
  alias Philomena.Repo
  alias Philomena.Loader

  alias Philomena.Attribution.Actor
  alias Philomena.DnpEntries.{DnpEntry, DnpListing}
  alias Philomena.ModerationLogs
  alias Philomena.ModerationLogs.Paths
  alias Philomena.ModNotes
  alias Philomena.ModNotes.ModNote
  alias Philomena.Tags.Tag
  alias Philomena.Users.User

  import Philomena.Authorization,
    only: [authorize: 3, verify_not_banned: 1, verify_write_access: 1]

  # Inserts a DNP entry for `user`, filed against whichever of `tags` matches the
  # `"tag_id"` in `attrs`. Visible for testing.
  @doc false
  @spec insert_dnp_entry(User.t(), [Tag.t()], map()) ::
          {:ok, DnpEntry.t()} | {:error, Ecto.Changeset.t()}
  def insert_dnp_entry(user, tags, attrs \\ %{}) do
    tag = Enum.find(tags, &(to_string(&1.id) == attrs["tag_id"]))

    %DnpEntry{}
    |> DnpEntry.creation_changeset(attrs, tag, user)
    |> Repo.insert()
  end

  # Transitions a DNP entry to a new state. Visible for testing.
  @doc false
  def transition_loaded_dnp_entry(%DnpEntry{} = dnp_entry, user, new_state) do
    dnp_entry
    |> DnpEntry.transition_changeset(user, new_state)
    |> Repo.update()
  end

  # Returns an `%Ecto.Changeset{}` for tracking DNP entry changes.
  defp change_dnp_entry(%DnpEntry{} = dnp_entry) do
    DnpEntry.changeset(dnp_entry, %{})
  end

  @doc """
  Assembles the Do-Not-Post listing for `actor` (the current viewer, whose user
  may be `nil`).

  With `"mine"` in `params` and a signed-in user, returns that user's own
  entries ordered by creation. Otherwise returns the publicly listed entries
  ordered by tag name. The viewer's linked tags travel along.
  The `status_column` flag records which of the two listings was produced.

  This listing is public; no authorization is performed.

  ## Examples

      iex> load_dnp_listing(user, %{"mine" => "1"}, pagination)
      %DnpListing{
        entries: %Scrivener.Page{},
        linked_tags: [%Tag{}, ...],
        status_column: true
      }

      iex> load_dnp_listing(user, params, pagination)
      %DnpListing{
        entries: %Scrivener.Page{},
        linked_tags: [%Tag{}, ...],
        status_column: false
      }

  """
  @spec load_dnp_listing(Actor.t(), map(), Repo.pagination_params()) :: DnpListing.t()
  def load_dnp_listing(actor, params, pagination)

  def load_dnp_listing(%Actor{user: %User{} = user}, %{"mine" => _mine}, pagination) do
    entries =
      DnpEntry
      |> where(requesting_user_id: ^user.id)
      |> preload(:tag)
      |> order_by(asc: :created_at)
      |> Repo.paginate(pagination)

    %DnpListing{dnp_entries: entries, linked_tags: linked_tags(user), status_column: true}
  end

  def load_dnp_listing(%Actor{} = actor, _params, pagination) do
    entries =
      DnpEntry
      |> where(aasm_state: "listed")
      |> join(:inner, [d], t in Tag, on: d.tag_id == t.id)
      |> preload(:tag)
      |> order_by([_d, t], asc: t.name_in_namespace)
      |> Repo.paginate(pagination)

    %DnpListing{dnp_entries: entries, linked_tags: linked_tags(actor.user), status_column: false}
  end

  @doc """
  Assembles the admin Do-Not-Post listing, on behalf of `actor`, for the given
  `params` and `pagination`, newest update first.

  A viewer without DNP access is `{:error, :unauthorized}`. A list `"states"`
  param restricts to those states; a string `"eq"` param filters by requesting
  user, tag, reason, conditions, or instructions; otherwise the active states
  (requested, claimed, rescinded, acknowledged) are listed.

  ## Examples

      iex> load_admin_dnp_entries(admin, params, pagination)
      {:ok, %Scrivener.Page{}}

      iex> load_admin_dnp_entries(user, params, pagination)
      {:error, :unauthorized}

  """
  @spec load_admin_dnp_entries(Actor.t(), map(), Repo.pagination_params()) ::
          {:ok, Scrivener.Page.t(DnpEntry.t())} | {:error, :unauthorized}
  def load_admin_dnp_entries(%Actor{} = actor, params, pagination) do
    with :ok <- authorize(actor, :index, DnpEntry) do
      entries =
        params
        |> admin_dnp_entries_query()
        |> preload([:tag, :requesting_user, :modifying_user])
        |> order_by(desc: :updated_at)
        |> Repo.paginate(pagination)

      {:ok, entries}
    end
  end

  defp admin_dnp_entries_query(%{"states" => states}) when is_list(states) do
    where(DnpEntry, [d], d.aasm_state in ^states)
  end

  defp admin_dnp_entries_query(%{"eq" => q}) when is_binary(q) do
    q = "%" <> q <> "%"

    DnpEntry
    |> join(:inner, [d], _ in assoc(d, :tag))
    |> join(:inner, [d, _t], _ in assoc(d, :requesting_user))
    |> where(
      [d, t, u],
      ilike(u.name, ^q) or ilike(t.name, ^q) or ilike(d.reason, ^q) or ilike(d.conditions, ^q) or
        ilike(d.instructions, ^q)
    )
  end

  defp admin_dnp_entries_query(_params) do
    where(DnpEntry, [d], d.aasm_state in ["requested", "claimed", "rescinded", "acknowledged"])
  end

  @doc """
  Loads a single DNP entry for `actor` (the current viewer, whose user may be
  `nil`) to be shown.

  The tag is preloaded. Returns `{:error, :not_found}` for an id no row could
  have, `{:error, :unauthorized}` when the viewer may not see the entry, and
  otherwise `{:ok, dnp_entry}`.

  ## Examples

      iex> load_dnp_entry(admin, dnp_entry_id)
      {:ok, %DnpEntry{}}

      iex> load_dnp_entry(admin, invalid_id)
      {:error, :not_found}

      iex> load_dnp_entry(user, unlisted_dnp_entry_id)
      {:error, :unauthorized}

  """
  @spec load_dnp_entry(Actor.t(), Loader.integer_id()) ::
          {:ok, DnpEntry.t()} | {:error, :not_found} | {:error, :unauthorized}
  def load_dnp_entry(%Actor{} = actor, id) do
    load_authorized_dnp_entry(actor, id, :show)
  end

  @doc """
  Returns the mod notes on `dnp_entry` for `viewer`, rendered with
  `collection_renderer`, or `nil` when the viewer may not read mod notes.

  ## Examples

      iex> mod_notes(admin, dnp_entry, &(&1))
      [%ModNote{}, ...]

      iex> mod_notes(user, dnp_entry, &(&1))
      nil

  """
  @spec mod_notes(Actor.t(), DnpEntry.t(), (list() -> list())) :: list() | nil
  def mod_notes(%Actor{} = viewer, %DnpEntry{} = dnp_entry, collection_renderer) do
    if Canada.Can.can?(viewer.user, :index, ModNote) do
      ModNotes.list_all_mod_notes_by_type_and_id("DnpEntry", dnp_entry.id, collection_renderer)
    end
  end

  @doc """
  Prepares a new DNP request on behalf of `actor`.

  Returns `{:error, :unauthorized}` when `actor` has no selectable tag.

  ## Examples

      iex> load_new_dnp_entry(user, params)
      {:ok,
        %{
          changeset: %Ecto.Changeset{},
          selectable_tags: [%Tag{}, ...]
        }}

      iex> load_new_dnp_entry(user_with_no_selectable_tags, params)
      {:error, :unauthorized}

      iex> load_new_dnp_entry(banned_user, params)
      {:error, :ban}

  """
  @spec load_new_dnp_entry(Actor.t(), map()) ::
          {:ok, %{changeset: Ecto.Changeset.t(), selectable_tags: [Tag.t()]}}
          | {:error, :ban}
          | {:error, :unauthorized}
  def load_new_dnp_entry(%Actor{} = actor, params) do
    # TODO: weird success shape?
    with :ok <- verify_not_banned(actor),
         {:ok, tags} <- selectable_tags(actor.user, params) do
      {:ok, %{changeset: change_dnp_entry(%DnpEntry{}), selectable_tags: tags}}
    end
  end

  @doc """
  Creates a DNP entry on behalf of `actor` from `params`.

  Reads the offered tag set from `params` (the top-level `"tag_id"` for staff,
  otherwise the actor's linked tags) and files the request against the tag named
  by the nested `"dnp_entry"` attrs.

  Returns `{:error, :unauthorized}` when `actor` has no selectable tag.

  ## Examples

      iex> create_dnp_entry(user, params)
      {:ok, %DnpEntry{}}

      iex> create_dnp_entry(user, invalid_params)
      {:error,
        %{
          changeset: %Ecto.Changeset{},
          selectable_tags: [%Tag{}, ...]
        }}

      iex> create_dnp_entry(user_with_no_selectable_tags, params)
      {:error, :unauthorized}

      iex> create_dnp_entry(banned_user, params)
      {:error, :ban}

  """
  @spec create_dnp_entry(Actor.t(), map()) ::
          {:ok, DnpEntry.t()}
          | {:error, %{changeset: Ecto.Changeset.t(), selectable_tags: [Tag.t()]}}
          | {:error, :ban}
          | {:error, :unauthorized}
  def create_dnp_entry(%Actor{} = actor, params) do
    # TODO: weird success shape?
    with :ok <- verify_write_access(actor),
         {:ok, tags} <- selectable_tags(actor.user, params) do
      attrs = params["dnp_entry"] || %{}

      case insert_dnp_entry(actor.user, tags, attrs) do
        {:ok, dnp_entry} -> {:ok, dnp_entry}
        {:error, changeset} -> {:error, %{changeset: changeset, selectable_tags: tags}}
      end
    end
  end

  @doc """
  Prepares the moderator edit of the DNP entry named by `id`, on behalf of
  `actor`.

  Returns `{:error, :unauthorized}` when `actor` has no selectable tag or may
  not edit the entry.

  ## Examples

      iex> load_dnp_entry_for_edit(admin, dnp_entry_id, params)
      {:ok,
        %{
          dnp_entry: %DnpEntry{},
          changeset: %Ecto.Changeset{},
          selectable_tags: [%Tag{}, ...]
        }}

      iex> load_dnp_entry_for_edit(admin, invalid_id, params)
      {:error, :not_found}

      iex> load_dnp_entry_for_edit(user, dnp_entry_id, params)
      {:error, :unauthorized}

  """
  @spec load_dnp_entry_for_edit(Actor.t(), Loader.integer_id(), map()) ::
          {:ok,
           %{dnp_entry: DnpEntry.t(), changeset: Ecto.Changeset.t(), selectable_tags: [Tag.t()]}}
          | {:error, :not_found}
          | {:error, :unauthorized}
  def load_dnp_entry_for_edit(%Actor{} = actor, id, params) do
    # TODO: weird success shape?
    with {:ok, tags} <- selectable_tags(actor.user, params),
         {:ok, dnp_entry} <- load_authorized_dnp_entry(actor, id, :edit) do
      {:ok,
       %{dnp_entry: dnp_entry, changeset: change_dnp_entry(dnp_entry), selectable_tags: tags}}
    end
  end

  @doc """
  Updates the DNP entry named by `id` on behalf of `actor` from
  `params`.

  Returns `{:error, :unauthorized}` when `actor` has no selectable tag or may
  not edit the entry.

  ## Examples

      iex> update_dnp_entry(admin, dnp_entry_id, params)
      {:ok, %DnpEntry{}}

      iex> update_dnp_entry(admin, dnp_entry_id, invalid_params)
      {:error,
        %{
          dnp_entry: %DnpEntry{},
          changeset: %Ecto.Changeset{},
          selectable_tags: [%Tag{}, ...]
        }}

      iex> update_dnp_entry(admin, invalid_id, params)
      {:error, :not_found}

      iex> update_dnp_entry(user, dnp_entry_id, params)
      {:error, :unauthorized}

  """
  @spec update_dnp_entry(Actor.t(), Loader.integer_id(), map()) ::
          {:ok, DnpEntry.t()}
          | {:error,
             %{
               dnp_entry: DnpEntry.t(),
               changeset: Ecto.Changeset.t(),
               selectable_tags: [Tag.t()]
             }}
          | {:error, :not_found}
          | {:error, :unauthorized}
  def update_dnp_entry(%Actor{} = actor, id, params) do
    with {:ok, tags} <- selectable_tags(actor.user, params),
         {:ok, dnp_entry} <- load_authorized_dnp_entry(actor, id, :update) do
      attrs = params["dnp_entry"] || %{}
      tag = Enum.find(tags, &(to_string(&1.id) == attrs["tag_id"]))

      case dnp_entry |> DnpEntry.update_changeset(attrs, tag) |> Repo.update() do
        {:ok, dnp_entry} ->
          {:ok, dnp_entry}

        {:error, changeset} ->
          # TODO: weird shape?
          {:error, %{dnp_entry: dnp_entry, changeset: changeset, selectable_tags: tags}}
      end
    end
  end

  @doc """
  Transitions the DNP entry named by the `id` to `new_state`, on
  behalf of `actor` (the acting staff user), and writes a moderation log on
  success.

  ## Examples

      iex> transition_dnp_entry(moderator, "1", "acknowledged")
      {:ok, %DnpEntry{}}

      iex> transition_dnp_entry(moderator, "1", "invalid state name")
      {:error, %Ecto.Changeset{}}

      iex> transition_dnp_entry(admin, invalid_id, "acknowledged")
      {:error, :not_found}

      iex> transition_dnp_entry(user, "1", "acknowledged")
      {:error, :unauthorized}

  """
  @spec transition_dnp_entry(Actor.t(), Loader.integer_id(), String.t()) ::
          {:ok, DnpEntry.t()} | {:error, :unauthorized | :not_found | Ecto.Changeset.t()}
  def transition_dnp_entry(%Actor{} = actor, id, new_state) do
    with :ok <- authorize(actor, :index, DnpEntry),
         {:ok, dnp_entry} <- load_required_dnp_entry(id),
         {:ok, dnp_entry} <- transition_loaded_dnp_entry(dnp_entry, actor.user, new_state) do
      ModerationLogs.create_moderation_log(
        actor,
        "Admin.DnpEntry.Transition:create",
        Paths.dnp_entry_path(dnp_entry),
        "#{String.capitalize(dnp_entry.aasm_state)} DNP entry #{dnp_entry.id} on #{dnp_entry.tag.name}"
      )

      {:ok, dnp_entry}
    end
  end

  # Loads the DNP entry named by `id` with its tag preloaded, answering
  # `{:error, :not_found}` for a non-castable id or an id naming no row.
  defp load_required_dnp_entry(id) do
    Loader.fetch(DnpEntry, id, [:tag])
  end

  @doc """
  Returns the count of active DNP entries in requested, claimed,
  or acknowledged state, if the user has permission to view them.

  ## Examples

      iex> count_dnp_entries(admin)
      42

      iex> count_dnp_entries(user)
      nil

  """
  def count_dnp_entries(user) do
    if Canada.Can.can?(user, :index, DnpEntry) do
      DnpEntry
      |> where([dnp], dnp.aasm_state in ["requested", "claimed", "acknowledged"])
      |> Repo.aggregate(:count, :id)
    else
      nil
    end
  end

  # The tags a DNP request may be filed against: for a viewer who may see the DNP
  # list, the single tag named by the top-level `tag_id` param; otherwise the
  # viewer's own linked artist tags. An empty set means the viewer has nothing to
  # file against.
  defp selectable_tags(user, params) do
    tags =
      if present?(params["tag_id"]) and Canada.Can.can?(user, :index, DnpEntry) do
        [Repo.get!(Tag, params["tag_id"])]
      else
        linked_tags(user)
      end

    case tags do
      [] -> {:error, :unauthorized}
      tags -> {:ok, tags}
    end
  end

  # Loads and authorizes the entry named by `id` for `action`. Authorization runs
  # against the loaded record, nil included, before the not-found decision: an
  # unknown well-formed id an actor may not act on comes back unauthorized, and
  # one it may act on comes back not-found.
  defp load_authorized_dnp_entry(actor, id, action) do
    Loader.fetch_and_authorize(DnpEntry, actor, action, id, [:tag])
  end

  defp linked_tags(%User{} = user) do
    user
    |> Repo.preload(:linked_tags)
    |> Map.get(:linked_tags)
  end

  defp linked_tags(_user), do: []

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_), do: true
end
