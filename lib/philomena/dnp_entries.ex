defmodule Philomena.DnpEntries do
  @moduledoc """
  The DnpEntries context.
  """

  import Ecto.Query, warn: false
  alias Philomena.Repo

  alias Philomena.Attribution.Actor
  alias Philomena.DnpEntries.{DnpEntry, DnpListing}
  alias Philomena.ModNotes
  alias Philomena.ModNotes.ModNote
  alias Philomena.Tags.Tag
  alias Philomena.Users.User

  import Philomena.Authorization,
    only: [authorize: 3, verify_not_banned: 1, verify_write_access: 1]

  @doc """
  Returns the list of dnp_entries.

  ## Examples

      iex> list_dnp_entries()
      [%DnpEntry{}, ...]

  """
  def list_dnp_entries do
    Repo.all(DnpEntry)
  end

  @doc """
  Gets a single dnp_entry.

  Raises `Ecto.NoResultsError` if the Dnp entry does not exist.

  ## Examples

      iex> get_dnp_entry!(123)
      %DnpEntry{}

      iex> get_dnp_entry!(456)
      ** (Ecto.NoResultsError)

  """
  def get_dnp_entry!(id), do: Repo.get!(DnpEntry, id)

  @doc """
  Assembles the Do-Not-Post index page for `user` (the current viewer, possibly
  `nil`).

  With `"mine"` in `params` and a signed-in `user`, returns that user's own
  entries ordered by creation. Otherwise returns the publicly listed entries
  ordered by tag name. The viewer's linked tags travel along for the sidebar.
  The `status_column` flag records which of the two listings was produced.

  This page is public; no authorization is performed.
  """
  @spec load_dnp_listing(User.t() | nil, map(), map() | keyword()) :: DnpListing.t()
  def load_dnp_listing(%User{} = user, %{"mine" => _mine}, pagination) do
    entries =
      DnpEntry
      |> where(requesting_user_id: ^user.id)
      |> preload(:tag)
      |> order_by(asc: :created_at)
      |> Repo.paginate(pagination)

    %DnpListing{dnp_entries: entries, linked_tags: linked_tags(user), status_column: true}
  end

  def load_dnp_listing(user, _params, pagination) do
    entries =
      DnpEntry
      |> where(aasm_state: "listed")
      |> join(:inner, [d], t in Tag, on: d.tag_id == t.id)
      |> preload(:tag)
      |> order_by([_d, t], asc: t.name_in_namespace)
      |> Repo.paginate(pagination)

    %DnpListing{dnp_entries: entries, linked_tags: linked_tags(user), status_column: false}
  end

  @doc """
  Assembles the admin Do-Not-Post listing, on behalf of `actor`, for the given
  raw request `params` and `pagination`, newest update first.

  Authorizes `:index` against the DNP entry model first, so a viewer without DNP
  access is `{:error, :unauthorized}`. A list `"states"` param restricts to
  those states; a string `"eq"` param filters by requesting user, tag, reason,
  conditions, or instructions; otherwise the active states (requested, claimed,
  rescinded, acknowledged) are listed.

  Returns `{:ok, dnp_entries}` as a `m:Scrivener.Page` of entries with their
  tag, requesting user, and modifying user preloaded, or
  `{:error, :unauthorized}`.
  """
  @spec load_admin_dnp_entries(User.t() | nil, map(), map() | keyword()) ::
          {:ok, Scrivener.Page.t()} | {:error, :unauthorized}
  def load_admin_dnp_entries(actor, params, pagination) do
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
  Loads a single DNP entry for `user` (the current viewer, possibly `nil`) to be
  shown.

  The tag is preloaded. Returns `{:error, :not_found}` for an id no row could
  have, `{:error, :unauthorized}` when the viewer may not see the entry, and
  otherwise `{:ok, dnp_entry}`.
  """
  @spec load_dnp_entry(User.t() | nil, any()) ::
          {:ok, DnpEntry.t()} | {:error, :not_found} | {:error, :unauthorized}
  def load_dnp_entry(user, id) do
    load_authorized_dnp_entry(user, id, :show)
  end

  @doc """
  Returns the mod notes on `dnp_entry` for `viewer`, rendered with
  `collection_renderer`, or `nil` when the viewer may not read mod notes.
  """
  @spec mod_notes(User.t() | nil, DnpEntry.t(), (list() -> list())) :: list() | nil
  def mod_notes(viewer, %DnpEntry{} = dnp_entry, collection_renderer) do
    if Canada.Can.can?(viewer, :index, ModNote) do
      ModNotes.list_all_mod_notes_by_type_and_id("DnpEntry", dnp_entry.id, collection_renderer)
    end
  end

  @doc """
  Prepares a new DNP request form on behalf of `actor`.

  Returns `{:error, :ban}` for a banned actor and `{:error, :unauthorized}` when
  the actor has no tag to file a request against. Otherwise returns
  `{:ok, %{changeset: changeset, selectable_tags: tags}}` with the tags the form
  offers.
  """
  @spec load_new_dnp_entry(Actor.t(), map()) ::
          {:ok, %{changeset: Ecto.Changeset.t(), selectable_tags: [Tag.t()]}}
          | {:error, :ban}
          | {:error, :unauthorized}
  def load_new_dnp_entry(%Actor{} = actor, params) do
    with :ok <- verify_not_banned(actor),
         {:ok, tags} <- selectable_tags(actor.user, params) do
      {:ok, %{changeset: change_dnp_entry(%DnpEntry{}), selectable_tags: tags}}
    end
  end

  @doc """
  Creates a DNP entry on behalf of `actor` from the controller `params`.

  Reads the offered tag set from `params` (the top-level `"tag_id"` for staff,
  otherwise the actor's linked tags) and files the request against the tag named
  by the nested `"dnp_entry"` attrs.

  Returns `{:error, :ban}` for a banned actor, `{:error, :unauthorized}` when the
  actor has no selectable tag, `{:error, %{changeset: changeset, selectable_tags:
  tags}}` when the request is invalid, and `{:ok, dnp_entry}` on success.
  """
  @spec create_dnp_entry(Actor.t(), map()) ::
          {:ok, DnpEntry.t()}
          | {:error, %{changeset: Ecto.Changeset.t(), selectable_tags: [Tag.t()]}}
          | {:error, :ban}
          | {:error, :unauthorized}
  def create_dnp_entry(%Actor{} = actor, params) do
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
  Prepares the moderator edit form for the DNP entry named by `id`, on behalf of
  `user`.

  Returns `{:error, :unauthorized}` when the viewer has no selectable tag or may
  not edit the entry, `{:error, :not_found}` for an id no row could have, and
  otherwise `{:ok, %{dnp_entry: dnp_entry, changeset: changeset, selectable_tags:
  tags}}`.
  """
  @spec load_dnp_entry_for_edit(User.t() | nil, any(), map()) ::
          {:ok,
           %{dnp_entry: DnpEntry.t(), changeset: Ecto.Changeset.t(), selectable_tags: [Tag.t()]}}
          | {:error, :not_found}
          | {:error, :unauthorized}
  def load_dnp_entry_for_edit(user, id, params) do
    with {:ok, tags} <- selectable_tags(user, params),
         {:ok, dnp_entry} <- load_authorized_dnp_entry(user, id, :edit) do
      {:ok,
       %{dnp_entry: dnp_entry, changeset: change_dnp_entry(dnp_entry), selectable_tags: tags}}
    end
  end

  @doc """
  Updates the DNP entry named by `id` on behalf of `user` from the controller
  `params`.

  Returns `{:error, :unauthorized}` when the viewer has no selectable tag or may
  not edit the entry, `{:error, :not_found}` for an id no row could have,
  `{:error, %{dnp_entry: dnp_entry, changeset: changeset, selectable_tags: tags}}`
  when the update is invalid, and `{:ok, dnp_entry}` on success.
  """
  @spec update_dnp_entry(User.t() | nil, any(), map()) ::
          {:ok, DnpEntry.t()}
          | {:error,
             %{
               dnp_entry: DnpEntry.t(),
               changeset: Ecto.Changeset.t(),
               selectable_tags: [Tag.t()]
             }}
          | {:error, :not_found}
          | {:error, :unauthorized}
  def update_dnp_entry(user, id, params) do
    with {:ok, tags} <- selectable_tags(user, params),
         {:ok, dnp_entry} <- load_authorized_dnp_entry(user, id, :update) do
      attrs = params["dnp_entry"] || %{}
      tag = Enum.find(tags, &(to_string(&1.id) == attrs["tag_id"]))

      case dnp_entry |> DnpEntry.update_changeset(attrs, tag) |> Repo.update() do
        {:ok, dnp_entry} ->
          {:ok, dnp_entry}

        {:error, changeset} ->
          {:error, %{dnp_entry: dnp_entry, changeset: changeset, selectable_tags: tags}}
      end
    end
  end

  @doc """
  Transitions a DNP entry to a new state.

  ## Examples

      iex> transition_dnp_entry(dnp_entry, user, "acknowledged")
      {:ok, %DnpEntry{}}

      iex> transition_dnp_entry(dnp_entry, user, "invalid_state")
      {:error, %Ecto.Changeset{}}

  """
  def transition_dnp_entry(%DnpEntry{} = dnp_entry, user, new_state) do
    dnp_entry
    |> DnpEntry.transition_changeset(user, new_state)
    |> Repo.update()
  end

  @doc """
  Deletes a DnpEntry.

  ## Examples

      iex> delete_dnp_entry(dnp_entry)
      {:ok, %DnpEntry{}}

      iex> delete_dnp_entry(dnp_entry)
      {:error, %Ecto.Changeset{}}

  """
  def delete_dnp_entry(%DnpEntry{} = dnp_entry) do
    Repo.delete(dnp_entry)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking dnp_entry changes.

  ## Examples

      iex> change_dnp_entry(dnp_entry)
      %Ecto.Changeset{source: %DnpEntry{}}

  """
  def change_dnp_entry(%DnpEntry{} = dnp_entry) do
    DnpEntry.changeset(dnp_entry, %{})
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

  @doc """
  Inserts a DNP entry for `user`, filed against whichever of `tags` matches the
  `"tag_id"` in `attrs`. A blank match records the "must be one of your linked
  tags" error.

  This is the raw insert used by fixtures and by `create_dnp_entry/2` after it
  has resolved the actor's selectable tags; it performs no authorization.
  """
  @spec insert_dnp_entry(User.t(), [Tag.t()], map()) ::
          {:ok, DnpEntry.t()} | {:error, Ecto.Changeset.t()}
  def insert_dnp_entry(user, tags, attrs \\ %{}) do
    tag = Enum.find(tags, &(to_string(&1.id) == attrs["tag_id"]))

    %DnpEntry{}
    |> DnpEntry.creation_changeset(attrs, tag, user)
    |> Repo.insert()
  end

  # The tags the DNP form offers: for a viewer who may see the DNP list, the
  # single tag named by the top-level `tag_id` param; otherwise the viewer's own
  # linked artist tags. An empty set means the viewer has nothing to file
  # against and may not use the form.
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
  defp load_authorized_dnp_entry(user, id, action) do
    with {:ok, id} <- Philomena.IntegerId.parse(id),
         dnp_entry = DnpEntry |> preload(:tag) |> Repo.get(id),
         :ok <- authorize(user, action, dnp_entry),
         %DnpEntry{} <- dnp_entry do
      {:ok, dnp_entry}
    else
      :error -> {:error, :not_found}
      nil -> {:error, :not_found}
      {:error, :unauthorized} -> {:error, :unauthorized}
    end
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
