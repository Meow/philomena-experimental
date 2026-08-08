defmodule Philomena.DnpEntries do
  @moduledoc """
  Do-Not-Post listings, forms, and staff transitions.
  """

  import Ecto.Query, warn: false
  import Philomena.Authorization, only: [authorize: 3, verify_write_access: 1]

  alias Philomena.Attribution.Actor
  alias Philomena.DnpEntries.{DnpEntry, DnpEntryForm, DnpEntryPage, DnpListing}
  alias Philomena.Loader
  alias Philomena.ModerationLogs
  alias Philomena.ModerationLogs.Paths
  alias Philomena.ModNotes
  alias Philomena.Repo
  alias Philomena.Tags.Tag
  alias Philomena.Users.User

  defp dnp_entry_form(%DnpEntry{} = dnp_entry, selectable_tags, changeset \\ nil) do
    %DnpEntryForm{
      dnp_entry: dnp_entry,
      changeset: changeset || DnpEntry.changeset(dnp_entry),
      selectable_tags: selectable_tags
    }
  end

  defp dnp_entry_page(actor, dnp_entry, collection_renderer) do
    mod_notes =
      case ModNotes.list_for_target(
             actor,
             {:dnp_entry, dnp_entry.id},
             collection_renderer
           ) do
        {:ok, notes} -> notes
        {:error, _reason} -> nil
      end

    %DnpEntryPage{dnp_entry: dnp_entry, mod_notes: mod_notes}
  end

  defp dnp_entry_attrs(%{"dnp_entry" => attrs}) when is_map(attrs), do: attrs
  defp dnp_entry_attrs(_params), do: %{}

  defp insert_dnp_entry(%User{} = user, tags, attrs) do
    tag = Enum.find(tags, &(to_string(&1.id) == attrs["tag_id"]))

    %DnpEntry{}
    |> DnpEntry.creation_changeset(attrs, tag, user)
    |> Repo.insert()
  end

  defp persist_dnp_entry_update(%DnpEntry{} = dnp_entry, tags, attrs) do
    tag = Enum.find(tags, &(to_string(&1.id) == attrs["tag_id"]))

    dnp_entry
    |> DnpEntry.update_changeset(attrs, tag)
    |> Repo.update()
  end

  defp transition_loaded_dnp_entry(%DnpEntry{} = dnp_entry, %User{} = user, new_state) do
    dnp_entry
    |> DnpEntry.transition_changeset(user, new_state)
    |> Repo.update()
  end

  defp linked_tags(%User{} = user) do
    user
    |> Repo.preload(:linked_tags)
    |> Map.fetch!(:linked_tags)
  end

  defp linked_tags(_user), do: []

  defp nonempty_tags([]), do: {:error, :unauthorized}
  defp nonempty_tags(tags), do: {:ok, tags}

  defp present?(value), do: value not in [nil, ""]

  defp may_select_any_tag?(actor) do
    authorize(actor, :select_any_tag, DnpEntry) == :ok
  end

  defp selectable_tags(%Actor{} = actor, params, default_tag \\ nil) do
    requested_tag_id = if is_map(params), do: params["tag_id"]

    cond do
      present?(requested_tag_id) and may_select_any_tag?(actor) ->
        with {:ok, tag} <- Loader.fetch(Tag, requested_tag_id) do
          {:ok, [tag]}
        end

      not is_nil(default_tag) and may_select_any_tag?(actor) ->
        {:ok, [default_tag]}

      true ->
        actor.user
        |> linked_tags()
        |> nonempty_tags()
    end
  end

  defp load_authorized_dnp_entry(actor, id, action) do
    Loader.fetch_and_authorize(DnpEntry, actor, action, id, [:tag])
  end

  defp lock_and_authorize_dnp_entry(actor, id, action) do
    DnpEntry
    |> lock("FOR UPDATE")
    |> Loader.fetch_and_authorize(actor, action, id, [:tag])
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

  defp transition_dnp_entry_transaction(actor, id, new_state) do
    Repo.transact(fn ->
      with {:ok, dnp_entry} <- lock_and_authorize_dnp_entry(actor, id, :transition),
           {:ok, dnp_entry} <-
             transition_loaded_dnp_entry(dnp_entry, actor.user, new_state),
           {:ok, _log} <-
             ModerationLogs.create_moderation_log(
               actor,
               "Admin.DnpEntry.Transition:create",
               Paths.dnp_entry_path(dnp_entry),
               "#{String.capitalize(dnp_entry.aasm_state)} DNP entry #{dnp_entry.id} on #{dnp_entry.tag.name}"
             ) do
        {:ok, dnp_entry}
      end
    end)
  end

  @doc """
  Assembles the public or current-user DNP listing.

  A signed-in actor using the `"mine"` parameter receives their own entries
  ordered by creation time and a visible status column. Every other request
  receives only listed entries ordered by tag name. The viewer's linked tags
  accompany both views.

  ## Examples

      iex> load_dnp_listing(actor, %{"mine" => "1"}, pagination)
      %DnpListing{status_column: true}

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
  Loads the newest admin DNP entries authorized for `actor`.

  A list-valued `"states"` filter takes precedence over the text `"eq"`
  filter. Without either, active requests are listed.

  ## Examples

      iex> load_admin_dnp_entries(moderator, %{}, pagination)
      {:ok, %Scrivener.Page{}}

      iex> load_admin_dnp_entries(user, %{}, pagination)
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

  @doc """
  Loads an authorized DNP page and any moderation notes visible to `actor`.

  IDs are parsed and loaded before instance authorization, so malformed and
  missing IDs are consistently not-found.

  ## Examples

      iex> load_dnp_entry_page(actor, "1", renderer)
      {:ok, %DnpEntryPage{}}

      iex> load_dnp_entry_page(actor, "not-an-id", renderer)
      {:error, :not_found}

  """
  @spec load_dnp_entry_page(Actor.t(), Loader.integer_id(), (list() -> list())) ::
          {:ok, DnpEntryPage.t()} | {:error, :not_found | :unauthorized}
  def load_dnp_entry_page(%Actor{} = actor, id, collection_renderer) do
    with {:ok, dnp_entry} <- load_authorized_dnp_entry(actor, id, :show) do
      {:ok, dnp_entry_page(actor, dnp_entry, collection_renderer)}
    end
  end

  @doc """
  Builds a new DNP request form on behalf of `actor`.

  Write access and the `:new` ability are checked before tag selection. Normal
  users may select from verified linked tags; staff may request one arbitrary
  tag by ID. Malformed or missing privileged tag IDs are not-found.

  ## Examples

      iex> load_new_dnp_entry(actor, %{})
      {:ok, %DnpEntryForm{}}

      iex> load_new_dnp_entry(banned_actor, %{})
      {:error, :ban}

  """
  @spec load_new_dnp_entry(Actor.t(), map()) ::
          {:ok, DnpEntryForm.t()} | {:error, :ban | :unauthorized | :not_found}
  def load_new_dnp_entry(%Actor{} = actor, params) do
    with :ok <- verify_write_access(actor),
         :ok <- authorize(actor, :new, DnpEntry),
         {:ok, tags} <- selectable_tags(actor, params) do
      {:ok, dnp_entry_form(%DnpEntry{}, tags)}
    end
  end

  @doc """
  Creates a DNP request using the same access and tag-selection policy as the
  new form. Validation failures return a `DnpEntryForm`.

  ## Examples

      iex> create_dnp_entry(actor, %{"dnp_entry" => attrs})
      {:ok, %DnpEntry{}}

      iex> create_dnp_entry(actor, %{"dnp_entry" => invalid_attrs})
      {:error, %DnpEntryForm{}}

  """
  @spec create_dnp_entry(Actor.t(), map()) ::
          {:ok, DnpEntry.t()}
          | {:error, DnpEntryForm.t()}
          | {:error, :ban | :unauthorized | :not_found}
  def create_dnp_entry(%Actor{} = actor, params) do
    with :ok <- verify_write_access(actor),
         :ok <- authorize(actor, :create, DnpEntry),
         {:ok, tags} <- selectable_tags(actor, params) do
      attrs = dnp_entry_attrs(params)

      case insert_dnp_entry(actor.user, tags, attrs) do
        {:ok, dnp_entry} -> {:ok, dnp_entry}
        {:error, changeset} -> {:error, dnp_entry_form(changeset.data, tags, changeset)}
      end
    end
  end

  @doc """
  Loads an existing DNP entry edit form.

  The entry is loaded before instance authorization. Its current tag is the
  default moderator selection, so a bare edit URL is sufficient. An explicit
  privileged tag ID, if provided, is loaded safely.

  ## Examples

      iex> load_dnp_entry_for_edit(moderator, "1", %{})
      {:ok, %DnpEntryForm{}}

      iex> load_dnp_entry_for_edit(user, "1", %{})
      {:error, :unauthorized}

  """
  @spec load_dnp_entry_for_edit(Actor.t(), Loader.integer_id(), map()) ::
          {:ok, DnpEntryForm.t()} | {:error, :ban | :unauthorized | :not_found}
  def load_dnp_entry_for_edit(%Actor{} = actor, id, params) do
    with :ok <- verify_write_access(actor),
         {:ok, dnp_entry} <- load_authorized_dnp_entry(actor, id, :edit),
         {:ok, tags} <- selectable_tags(actor, params, dnp_entry.tag) do
      {:ok, dnp_entry_form(dnp_entry, tags)}
    end
  end

  @doc """
  Updates an existing DNP entry using the same access and tag-selection policy
  as the edit form. Validation failures return a `DnpEntryForm`.

  ## Examples

      iex> update_dnp_entry(moderator, "1", %{"dnp_entry" => attrs})
      {:ok, %DnpEntry{}}

      iex> update_dnp_entry(moderator, "1", %{"dnp_entry" => invalid_attrs})
      {:error, %DnpEntryForm{}}

  """
  @spec update_dnp_entry(Actor.t(), Loader.integer_id(), map()) ::
          {:ok, DnpEntry.t()}
          | {:error, DnpEntryForm.t()}
          | {:error, :ban | :unauthorized | :not_found}
  def update_dnp_entry(%Actor{} = actor, id, params) do
    with :ok <- verify_write_access(actor),
         {:ok, dnp_entry} <- load_authorized_dnp_entry(actor, id, :update),
         {:ok, tags} <- selectable_tags(actor, params, dnp_entry.tag) do
      attrs = dnp_entry_attrs(params)

      case persist_dnp_entry_update(dnp_entry, tags, attrs) do
        {:ok, dnp_entry} -> {:ok, dnp_entry}
        {:error, changeset} -> {:error, dnp_entry_form(dnp_entry, tags, changeset)}
      end
    end
  end

  @doc """
  Transitions one DNP entry on behalf of staff.

  The entry is locked, loaded, and authorized with the distinct `:transition`
  ability. The state update and moderation log commit atomically.

  ## Examples

      iex> transition_dnp_entry(moderator, "1", "listed")
      {:ok, %DnpEntry{aasm_state: "listed"}}

      iex> transition_dnp_entry(user, "1", "listed")
      {:error, :unauthorized}

  """
  @spec transition_dnp_entry(Actor.t(), Loader.integer_id(), String.t() | nil) ::
          {:ok, DnpEntry.t()}
          | {:error, :ban | :unauthorized | :not_found | Ecto.Changeset.t()}
  def transition_dnp_entry(%Actor{} = actor, id, new_state) do
    with :ok <- verify_write_access(actor) do
      transition_dnp_entry_transaction(actor, id, new_state)
    end
  end

  @doc """
  Returns the count of active DNP requests when `actor` may view the admin DNP
  index, otherwise `nil`.

  ## Examples

      iex> count_dnp_entries(moderator)
      3

      iex> count_dnp_entries(user)
      nil

  """
  @spec count_dnp_entries(Actor.t()) :: non_neg_integer() | nil
  def count_dnp_entries(%Actor{} = actor) do
    case authorize(actor, :index, DnpEntry) do
      :ok ->
        DnpEntry
        |> where([dnp], dnp.aasm_state in ["requested", "claimed", "acknowledged"])
        |> Repo.aggregate(:count, :id)

      {:error, :unauthorized} ->
        nil
    end
  end
end
