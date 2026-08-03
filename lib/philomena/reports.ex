defmodule Philomena.Reports do
  @moduledoc """
  The Reports context.
  """

  import Ecto.Query, warn: false

  import Philomena.Authorization,
    only: [authorize: 3, verify_write_access: 1, verify_not_banned: 1]

  alias Philomena.Repo
  alias Philomena.Loader

  alias PhilomenaQuery.Batch
  alias PhilomenaQuery.Search
  alias Philomena.Attribution.Actor
  alias Philomena.Commissions
  alias Philomena.Commissions.Commission
  alias Philomena.Conversations.Conversation
  alias Philomena.Galleries.Gallery
  alias Philomena.Images.Image
  alias Philomena.Images
  alias Philomena.IntegerId
  alias Philomena.Users.User
  alias Philomena.Reports.Report
  alias Philomena.Reports.ReportPage
  alias Philomena.Reports.Query
  alias Philomena.Reports
  alias Philomena.IndexWorker
  alias Philomena.ModNotes
  alias Philomena.ModNotes.ModNote
  alias Philomena.Rules

  alias Philomena.Images.Image
  alias Philomena.Comments.Comment
  alias Philomena.Posts.Post
  alias Philomena.Commissions.Commission
  alias Philomena.Conversations.Conversation
  alias Philomena.Galleries.Gallery

  @max_open_reports 5
  @default_preloads [:admin, :rule, user: :linked_tags]

  @doc """
  The maximum number of simultaneously open reports a regular user (or an
  anonymous visitor's IP) may hold before further submissions are refused.
  """
  @spec max_open_reports() :: pos_integer()
  def max_open_reports, do: @max_open_reports

  @reason_regex ~r/^(Rule|Other|Takedown|Verification|Approval|Review|System)([^:]*): (.*)$/

  @doc """
  Returns the current number of open reports.

  If the user is allowed to view reports, returns the current count.
  If the user is not allowed to view reports, returns `nil`.

  ## Examples

      iex> count_reports(%User{})
      nil

      iex> count_reports(%User{role: "admin"})
      4

  """
  def count_open_reports(user) do
    if Canada.Can.can?(user, :index, Report) do
      Report
      |> where(open: true)
      |> Repo.aggregate(:count)
    else
      nil
    end
  end

  @doc """
  Returns the list of reports.

  ## Examples

      iex> list_reports()
      [%Report{}, ...]

  """
  def list_reports do
    Repo.all(Report)
  end

  @doc """
  Gets a single report.

  Raises `Ecto.NoResultsError` if the Report does not exist.

  ## Examples

      iex> get_report!(123)
      %Report{}

      iex> get_report!(456)
      ** (Ecto.NoResultsError)

  """
  def get_report!(id), do: Repo.get!(Report, id)

  @doc """
  Assembles the admin report listing, on behalf of `actor`, for the given
  `params` and `pagination`.

  Authorizes `:index` against the report model first, so a viewer without report
  access is `{:error, :unauthorized}`. When `params` carries an `"rq"` search
  string it is compiled and drives the searched-report list, and the own-open
  and system-report lists are empty; otherwise the default view lists the
  closed reports plus open reports the actor did not claim, alongside the
  actor's own open reports and the open system reports. A malformed `"rq"`
  raises `MatchError`.

  Returns `{:ok, %Philomena.Reports.ReportPage{}}` or `{:error, :unauthorized}`.

  ## Examples

      iex> load_report_index(admin, %{"rq" => "open:true"}, pagination)
      {:ok, %Philomena.Reports.ReportPage{}}

  """
  @spec load_report_index(Actor.t(), map(), Repo.pagination_params()) ::
          {:ok, ReportPage.t()} | {:error, :unauthorized}
  def load_report_index(%Actor{} = actor, params, pagination) do
    with :ok <- authorize(actor, :index, Report) do
      {:ok, build_report_page(actor, params, pagination)}
    end
  end

  defp build_report_page(_actor, %{"rq" => query_string}, pagination) do
    {:ok, query} = Query.compile(query_string)

    %ReportPage{
      reports: searched_reports(query, pagination),
      my_reports: [],
      system_reports: []
    }
  end

  defp build_report_page(actor, _params, pagination) do
    query = %{
      bool: %{
        should: [
          %{term: %{open: false}},
          %{
            bool: %{
              must: %{term: %{open: true}},
              must_not: [
                %{term: %{admin_id: actor.user.id}},
                %{term: %{system: true}}
              ]
            }
          }
        ]
      }
    }

    %ReportPage{
      reports: searched_reports(query, pagination),
      my_reports: own_open_reports(actor),
      system_reports: open_system_reports()
    }
  end

  defp searched_reports(query, pagination) do
    queryable =
      Report
      |> preload(^@default_preloads)
      |> preload(^Report.target_preloads())

    Report
    |> Search.search_definition(
      %{
        query: query,
        sort: report_sorts()
      },
      pagination
    )
    |> Search.search_records(queryable)
  end

  defp own_open_reports(actor) do
    Report
    |> where(open: true, admin_id: ^actor.user.id)
    |> preload(^@default_preloads)
    |> preload(^Report.target_preloads())
    |> order_by(desc: :created_at)
    |> Repo.all()
  end

  defp open_system_reports do
    Report
    |> where(open: true, system: true)
    |> preload(^@default_preloads)
    |> preload(^Report.target_preloads())
    |> order_by(desc: :created_at)
    |> Repo.all()
  end

  defp report_sorts do
    [
      %{open: :desc},
      %{state: :desc},
      %{created_at: :desc}
    ]
  end

  @doc """
  Loads the report named by `id`, on behalf of `actor`, with the admin, rule,
  and reporting-user associations preloaded and its reportable resolved.

  Authorizes `:show` against the loaded report: a non-castable id is
  `{:error, :not_found}`, and a well-formed id naming no row authorizes `nil`,
  which no ordinary rule permits, so it is `{:error, :unauthorized}`
  (`{:error, :not_found}` for admins, whose grant covers `nil`).

  Returns `{:ok, report}`, `{:error, :unauthorized}`, or `{:error, :not_found}`.

  ## Examples

      iex> load_report(admin, "1")
      {:ok, %Report{}}

  """
  @spec load_report(Actor.t(), Loader.integer_id()) ::
          {:ok, Report.t()} | {:error, :unauthorized | :not_found}
  def load_report(%Actor{} = actor, id) do
    with {:ok, id} <- IntegerId.parse(id),
         report = load_report_with_preloads(id),
         :ok <- authorize(actor, :show, report),
         %Report{} <- report do
      {:ok, report}
    else
      {:error, :unauthorized} -> {:error, :unauthorized}
      _ -> {:error, :not_found}
    end
  end

  defp load_report_with_preloads(id) do
    Report
    |> preload(^@default_preloads)
    |> preload(^Report.target_preloads())
    |> Repo.get(id)
  end

  @doc """
  Returns the mod notes attached to `report` for `viewer`, rendered with
  `collection_renderer`, or `nil` when the viewer may not read mod notes.
  """
  @spec mod_notes(Actor.t(), Report.t(), (list() -> list())) :: list() | nil
  def mod_notes(%Actor{} = viewer, report, collection_renderer) do
    if Canada.Can.can?(viewer.user, :index, ModNote) do
      ModNotes.list_all_mod_notes_for_target(collection_renderer, report_id: report.id)
    end
  end

  @doc """
  Loads the image named by `image_id` for reporting, on behalf of `actor` (a
  `Philomena.Attribution.Actor` whose user may be `nil` for an anonymous
  visitor).

  This is a read that precedes a report: a banned actor is rejected with
  `{:error, :ban}` first, but the fingerprint requirement that the write itself
  enforces does not apply here. The image is then loaded and authorized for
  `:show`.

  Returns `{:ok, {image, changeset}}` - the image and a changeset for reporting
  it - `{:error, :ban}` for a banned actor, `{:error, :unauthorized}` when the
  image is not visible, or `{:error, :not_found}` when the id cannot name a row.

  ## Examples

      iex> load_image_for_report(actor, "1")
      {:ok, {%Image{}, %Ecto.Changeset{}}}

  """
  @spec load_image_for_report(Actor.t(), any()) ::
          {:ok, {Image.t(), Ecto.Changeset.t()}}
          | {:error, :ban | :unauthorized | :not_found}
  def load_image_for_report(%Actor{} = actor, image_id) do
    with :ok <- verify_not_banned(actor),
         {:ok, image} <-
           Images.load_visible_image(actor, image_id, [:sources, tags: :aliases]) do
      changeset = change_report(%Report{image_id: image.id})
      {:ok, {image, changeset}}
    end
  end

  @doc """
  Loads the image named by `image_id` for creating its report, on behalf of
  `actor` (a `Philomena.Attribution.Actor` whose user may be `nil`).

  This is the write path, so `actor`'s write access is verified first: a banned
  actor is `{:error, :ban}` and an actor with no fingerprint is
  `{:error, :unauthorized}`. The image is then loaded and authorized for
  `:show`.

  Returns `{:ok, image}`, `{:error, :ban}` or `{:error, :unauthorized}` from the
  write-access check, `{:error, :unauthorized}` when the image is not visible, or
  `{:error, :not_found}` when the id cannot name a row.

  ## Examples

      iex> load_image_for_report_creation(actor, "1")
      {:ok, %Image{}}

  """
  @spec load_image_for_report_creation(Actor.t(), any()) ::
          {:ok, Image.t()} | {:error, :ban | :unauthorized | :not_found}
  def load_image_for_report_creation(%Actor{} = actor, image_id) do
    with :ok <- verify_write_access(actor) do
      Images.load_visible_image(actor, image_id, [:sources, tags: :aliases])
    end
  end

  @doc """
  Loads the gallery named by `gallery_id` for reporting, on behalf of `actor`
  (a `Philomena.Attribution.Actor` whose user may be `nil`).

  Banned actors are rejected first with `{:error, :ban}`. The gallery is then
  loaded and authorized for `:show`: a non-castable id is
  `{:error, :not_found}`, and a well-formed id that names no row authorizes
  `nil`, which no ordinary rule permits, so it is `{:error, :unauthorized}`
  (`{:error, :not_found}` for viewers whose grants cover `nil`).

  Returns `{:ok, {gallery, changeset}}` with a changeset for reporting it.

  ## Examples

      iex> load_gallery_for_report(actor, "1")
      {:ok, {%Gallery{}, %Ecto.Changeset{}}}

  """
  @spec load_gallery_for_report(Actor.t(), any()) ::
          {:ok, {Gallery.t(), Ecto.Changeset.t()}}
          | {:error, :ban | :unauthorized | :not_found}
  def load_gallery_for_report(%Actor{} = actor, gallery_id) do
    with :ok <- verify_not_banned(actor),
         {:ok, gallery} <- load_reportable_gallery(actor.user, gallery_id) do
      changeset = change_report(%Report{gallery_id: gallery.id})
      {:ok, {gallery, changeset}}
    end
  end

  @doc """
  Loads the gallery named by `gallery_id` for creating its report, on behalf of
  `actor`.

  This is the write path, so the actor's write access is verified first: a banned
  actor is `{:error, :ban}` and an actor with no fingerprint
  `{:error, :unauthorized}`. Lookup and authorization follow
  `load_gallery_for_report/2`.

  ## Examples

      iex> load_gallery_for_report_creation(actor, "1")
      {:ok, %Gallery{}}

  """
  @spec load_gallery_for_report_creation(Actor.t(), any()) ::
          {:ok, Gallery.t()} | {:error, :ban | :unauthorized | :not_found}
  def load_gallery_for_report_creation(%Actor{} = actor, gallery_id) do
    with :ok <- verify_write_access(actor) do
      load_reportable_gallery(actor.user, gallery_id)
    end
  end

  defp load_reportable_gallery(user, gallery_id) do
    Loader.fetch_and_authorize(Gallery, user, :show, gallery_id)
  end

  @doc """
  Loads the user named by the profile `slug` for reporting, on behalf of
  `actor`.

  Banned actors are rejected first with `{:error, :ban}`. The user is then
  loaded by slug and authorized for `:show`; an unknown slug authorizes `nil`,
  which no ordinary rule permits, so it is `{:error, :unauthorized}`
  (`{:error, :not_found}` for viewers whose grants cover `nil`).

  Returns `{:ok, {user, changeset}}` with a changeset for reporting them.

  ## Examples

      iex> load_user_for_report(actor, "administrator")
      {:ok, {%User{}, %Ecto.Changeset{}}}

  """
  @spec load_user_for_report(Actor.t(), String.t()) ::
          {:ok, {User.t(), Ecto.Changeset.t()}}
          | {:error, :ban | :unauthorized | :not_found}
  def load_user_for_report(%Actor{} = actor, slug) do
    with :ok <- verify_not_banned(actor),
         {:ok, user} <- load_reportable_user(actor.user, slug) do
      changeset = change_report(%Report{reported_user_id: user.id})
      {:ok, {user, changeset}}
    end
  end

  @doc """
  Loads the user named by the profile `slug` for creating their report, on
  behalf of `actor`.

  This is the write path, so the actor's write access is verified first: a banned
  actor is `{:error, :ban}` and an actor with no fingerprint
  `{:error, :unauthorized}`. Lookup and authorization follow
  `load_user_for_report/2`.

  ## Examples

      iex> load_user_for_report_creation(actor, "administrator")
      {:ok, %User{}}

  """
  @spec load_user_for_report_creation(Actor.t(), String.t()) ::
          {:ok, User.t()} | {:error, :ban | :unauthorized | :not_found}
  def load_user_for_report_creation(%Actor{} = actor, slug) do
    with :ok <- verify_write_access(actor) do
      load_reportable_user(actor.user, slug)
    end
  end

  defp load_reportable_user(user, slug) do
    reported = Repo.get_by(User, slug: slug)

    with :ok <- authorize(user, :show, reported),
         %User{} <- reported do
      {:ok, reported}
    else
      {:error, :unauthorized} -> {:error, :unauthorized}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Loads the user named by the profile `slug` together with their commission for
  reporting, on behalf of `actor`.

  Banned actors are rejected first with `{:error, :ban}`. Reporting a commission
  needs no permission, so an unknown slug and a user without a commission are
  both `{:error, :not_found}`. The commission carries its sheet image, items,
  and example images preloaded.

  Returns `{:ok, {user, commission, changeset}}` with a changeset for reporting
  it.

  ## Examples

      iex> load_commission_for_report(actor, "artist")
      {:ok, {%User{}, %Commission{}, %Ecto.Changeset{}}}

  """
  @spec load_commission_for_report(Actor.t(), String.t()) ::
          {:ok, {User.t(), Commission.t(), Ecto.Changeset.t()}}
          | {:error, :ban | :not_found}
  def load_commission_for_report(%Actor{} = actor, slug) do
    with :ok <- verify_not_banned(actor),
         {:ok, {user, commission}} <- Commissions.load_commission_for_show(slug) do
      changeset =
        change_report(%Report{commission_id: commission.id})

      {:ok, {user, commission, changeset}}
    end
  end

  @doc """
  Loads the user named by the profile `slug` together with their commission for
  creating its report, on behalf of `actor`.

  This is the write path, so the actor's write access is verified first: a banned
  actor is `{:error, :ban}` and an actor with no fingerprint
  `{:error, :unauthorized}`. Lookup follows `load_commission_for_report/2`.

  ## Examples

      iex> load_commission_for_report_creation(actor, "artist")
      {:ok, {%User{}, %Commission{}}}

  """
  @spec load_commission_for_report_creation(Actor.t(), String.t()) ::
          {:ok, {User.t(), Commission.t()}}
          | {:error, :ban | :unauthorized | :not_found}
  def load_commission_for_report_creation(%Actor{} = actor, slug) do
    with :ok <- verify_write_access(actor) do
      Commissions.load_commission_for_show(slug)
    end
  end

  @doc """
  Loads the conversation named by `slug` for reporting, on behalf of `actor`
  (a `Philomena.Attribution.Actor` whose user may be `nil`).

  Banned actors are rejected first with `{:error, :ban}`. The conversation is
  then loaded by slug and authorized for `:show`: it is visible to its
  participants, moderators, and admins, so a non-participant is
  `{:error, :unauthorized}`, and a slug naming no row authorizes `nil`, which no
  ordinary rule permits, so it is `{:error, :unauthorized}` (`{:error, :not_found}`
  for admins).

  Returns `{:ok, {conversation, changeset}}` with a changeset for reporting it.

  ## Examples

      iex> load_conversation_for_report(actor, "slug")
      {:ok, {%Conversation{}, %Ecto.Changeset{}}}

  """
  @spec load_conversation_for_report(Actor.t(), String.t()) ::
          {:ok, {Conversation.t(), Ecto.Changeset.t()}}
          | {:error, :ban | :unauthorized | :not_found}
  def load_conversation_for_report(%Actor{} = actor, slug) do
    with :ok <- verify_not_banned(actor),
         {:ok, conversation} <- load_reportable_conversation(actor.user, slug) do
      changeset =
        change_report(%Report{conversation_id: conversation.id})

      {:ok, {conversation, changeset}}
    end
  end

  @doc """
  Loads the conversation named by `slug` for creating its report, on behalf of
  `actor`.

  This is the write path, so the actor's write access is verified first: a banned
  actor is `{:error, :ban}` and an actor with no fingerprint
  `{:error, :unauthorized}`. Lookup and authorization follow
  `load_conversation_for_report/2`.

  ## Examples

      iex> load_conversation_for_report_creation(actor, "slug")
      {:ok, %Conversation{}}

  """
  @spec load_conversation_for_report_creation(Actor.t(), String.t()) ::
          {:ok, Conversation.t()} | {:error, :ban | :unauthorized | :not_found}
  def load_conversation_for_report_creation(%Actor{} = actor, slug) do
    with :ok <- verify_write_access(actor) do
      load_reportable_conversation(actor.user, slug)
    end
  end

  defp load_reportable_conversation(user, slug) do
    conversation =
      Conversation
      |> where(slug: ^slug)
      |> preload([:from, :to])
      |> Repo.one()

    with :ok <- authorize(user, :show, conversation),
         %Conversation{} <- conversation do
      {:ok, conversation}
    else
      {:error, :unauthorized} -> {:error, :unauthorized}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Creates a report against the target named by `target`, a one-entry keyword
  list of the target foreign key column and its id (e.g. `image_id: image.id`),
  on behalf of `actor`.

  A regular user or an anonymous IP holding `max_open_reports/0` open reports is
  refused with `{:error, :too_many_reports}`; staff are exempt. Otherwise the
  report is inserted with the IP, fingerprint, and user carried by `actor`, and
  reindexed.

  Returns `{:ok, report}` on success, `{:error, :too_many_reports}` when the open
  report limit is reached, or `{:error, %Ecto.Changeset{}}` when the insert is
  rejected.

  ## Examples

      iex> create_report(actor, %{"reason" => "Spam"}, comment_id: 1)
      {:ok, %Report{}}

      iex> create_report(actor, %{"reason" => ""}, comment_id: 1)
      {:error, %Ecto.Changeset{}}

  """
  @spec create_report(Actor.t(), map() | nil, keyword()) ::
          {:ok, Report.t()} | {:error, :too_many_reports} | {:error, Ecto.Changeset.t()}
  def create_report(%Actor{} = actor, params, target) do
    if too_many_reports?(actor) do
      {:error, :too_many_reports}
    else
      create_report(actor_attributes(actor), params || %{}, target, nil)
    end
  end

  # The IP/fingerprint/user attribution the report changeset records, rebuilt
  # from the actor into the keyword list it expects.
  defp actor_attributes(%Actor{ip: ip, fingerprint: fingerprint, user: user}),
    do: [ip: ip, fingerprint: fingerprint, user: user]

  # Staff are never rate-limited; a regular user or an anonymous IP is refused
  # once it holds the maximum number of open reports.
  defp too_many_reports?(%Actor{user: %{role: role}}) when role != "user", do: false

  defp too_many_reports?(%Actor{user: user, ip: ip}),
    do: open_reports_for_user?(user) or open_reports_for_ip?(ip)

  defp open_reports_for_user?(nil), do: false

  defp open_reports_for_user?(user),
    do: open_report_count(where(Report, user_id: ^user.id)) >= @max_open_reports

  defp open_reports_for_ip?(ip),
    do: open_report_count(where(Report, ip: ^ip)) >= @max_open_reports

  defp open_report_count(query) do
    query
    |> where([r], r.state in ["open", "in_progress"])
    |> Repo.aggregate(:count, :id)
  end

  @doc """
  Creates a report against the target named by `target`, a one-entry keyword
  list of the target foreign key column and its id (e.g. `image_id: image.id`).

  ## Examples

      iex> create_report(attribution, %{"reason" => "..."}, image_id: image.id)
      {:ok, %Report{}}

      iex> create_report(attribution, %{"reason" => ""}, image_id: image.id)
      {:error, %Ecto.Changeset{}}

  """
  def create_report(attribution, attrs, target, _unused) do
    rule = Rules.find_rule(attrs["rule_id"])

    struct(Report, target)
    |> Report.user_creation_changeset(attrs, attribution, rule)
    |> Repo.insert()
    |> reindex_after_update()
  end

  @doc """
  Returns an `m:Ecto.Query` which updates all open reports against the target
  named by `target`, a one-entry keyword list of the target foreign key column
  and its id (e.g. `image_id: image.id`), to close them.

  Because this is only a query due to the limitations of `m:Ecto.Multi`, this must be
  coupled with an associated call to `reindex_reports/1` to operate correctly, e.g.:

      report_query = Reports.close_report_query(user, image_id: image.id)

      Multi.new()
      |> Multi.update_all(:reports, report_query, [])
      |> Repo.transaction()
      |> case do
        {:ok, %{reports: {_count, reports}} = result} ->
          Reports.reindex_reports(reports)

          {:ok, result}

        error ->
          error
      end

  Use `close_reports/2` to close and reindex reports in one step outside an `m:Ecto.Multi`.

  ## Examples

      iex> close_report_query(%User{}, image_id: 1)
      #Ecto.Query<...>

  """
  def close_report_query(closing_user, [{column, id}]) do
    now = DateTime.utc_now(:second)

    from r in Report,
      where: field(r, ^column) == ^id and r.open == true,
      select: r.id,
      update: [
        set: [
          open: false,
          state: "closed",
          admin_id: ^closing_user.id,
          updated_at: ^now
        ]
      ]
  end

  @doc """
  Closes all open reports against the target named by `target` (see
  `close_report_query/2`), marking them as closed by the specified user.
  Also reindexes the affected reports.

  Returns `{:ok, {count, reports}}`.
  """
  def close_reports(closing_user, target) do
    {_count, reports} =
      result = Repo.update_all(close_report_query(closing_user, target), [])

    reindex_reports(reports)
    {:ok, result}
  end

  @doc """
  Automatically create a report with the given rule and reason against the
  target named by `target`, a one-entry keyword list of the target foreign key
  column and its id (e.g. `comment_id: comment.id`).

  ## Examples

      iex> create_system_report("Rule #0", "Custom report reason", comment_id: 1)
      {:ok, %Report{}}

  """
  def create_system_report(rule_name, reason, target) do
    rule = Rules.get_by_name!(rule_name)

    attrs = %{
      reason: reason,
      user_agent: "system"
    }

    attribution = %{
      system: true,
      ip: %Postgrex.INET{address: {127, 0, 0, 1}, netmask: 32},
      fingerprint: "ffff"
    }

    struct(Report, target)
    |> Report.creation_changeset(attrs, attribution, rule)
    |> Repo.insert()
    |> reindex_after_update()
  end

  @doc """
  Updates a report.

  ## Examples

      iex> update_report(report, %{field: new_value})
      {:ok, %Report{}}

      iex> update_report(report, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_report(%Report{} = report, attrs) do
    report
    |> Report.changeset(attrs)
    |> Repo.update()
    |> reindex_after_update()
  end

  @doc """
  Deletes a Report.

  ## Examples

      iex> delete_report(report)
      {:ok, %Report{}}

      iex> delete_report(report)
      {:error, %Ecto.Changeset{}}

  """
  def delete_report(%Report{} = report) do
    Repo.delete(report)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking report changes.

  ## Examples

      iex> change_report(report)
      %Ecto.Changeset{source: %Report{}}

  """
  def change_report(%Report{} = report) do
    # FIXME: this should be private, and the functions that call it (comments/posts) moved to this context
    Report.changeset(report, %{})
  end

  @doc """
  Marks the report named by `id` as claimed by `actor`, on behalf of `actor`
  (the acting staff user), and reindexes it.

  Authorizes `:edit` against the loaded report: a non-castable id is
  `{:error, :not_found}`, and a well-formed id naming no row authorizes `nil`,
  which no ordinary rule permits, so it is `{:error, :unauthorized}`
  (`{:error, :not_found}` for admins).

  Returns `{:ok, report}`, `{:error, :unauthorized}`, `{:error, :not_found}`, or
  `{:error, %Ecto.Changeset{}}`.

  ## Example

      iex> claim_report(moderator, "1")
      {:ok, %Report{}}

  """
  @spec claim_report(Actor.t(), Loader.integer_id()) ::
          {:ok, Report.t()} | {:error, :unauthorized | :not_found | Ecto.Changeset.t()}
  def claim_report(%Actor{} = actor, id) do
    with {:ok, report} <- load_report_for_edit(actor, id) do
      report
      |> Report.claim_changeset(actor.user)
      |> Repo.update()
      |> reindex_after_update()
    end
  end

  @doc """
  Marks the report named by `id` as unclaimed, on behalf of `actor` (the acting
  staff user), and reindexes it.

  Loading and authorization follow `claim_report/2`, authorizing `:edit`.

  Returns `{:ok, report}`, `{:error, :unauthorized}`, `{:error, :not_found}`, or
  `{:error, %Ecto.Changeset{}}`.

  ## Example

      iex> unclaim_report(moderator, "1")
      {:ok, %Report{}}

  """
  @spec unclaim_report(Actor.t(), Loader.integer_id()) ::
          {:ok, Report.t()} | {:error, :unauthorized | :not_found | Ecto.Changeset.t()}
  def unclaim_report(%Actor{} = actor, id) do
    with {:ok, report} <- load_report_for_edit(actor, id) do
      report
      |> Report.unclaim_changeset()
      |> Repo.update()
      |> reindex_after_update()
    end
  end

  @doc """
  Marks the report named by `id` as closed by `actor`, on behalf of `actor`
  (the acting staff user), and reindexes it.

  Loading and authorization follow `claim_report/2`, authorizing `:edit`.

  Returns `{:ok, report}`, `{:error, :unauthorized}`, `{:error, :not_found}`, or
  `{:error, %Ecto.Changeset{}}`.

  ## Example

      iex> close_report(moderator, "1")
      {:ok, %Report{}}

  """
  @spec close_report(Actor.t(), Loader.integer_id()) ::
          {:ok, Report.t()} | {:error, :unauthorized | :not_found | Ecto.Changeset.t()}
  def close_report(%Actor{} = actor, id) do
    with {:ok, report} <- load_report_for_edit(actor, id) do
      report
      |> Report.close_changeset(actor.user)
      |> Repo.update()
      |> reindex_after_update()
    end
  end

  # Loads the report named by `id` and authorizes `:edit` against it, the guard
  # the claim and close actions share.
  defp load_report_for_edit(actor, id) do
    Loader.fetch_and_authorize(Report, actor, :edit, id)
  end

  @doc """
  Reindex all reports where the user or admin has `old_name`.

  ## Example

      iex> user_name_reindex("Administrator", "Administrator2")
      {:ok, %Req.Response{}}

  """
  def user_name_reindex(old_name, new_name) do
    data = Reports.SearchIndex.user_name_update_by_query(old_name, new_name)

    Search.update_by_query(Report, data.query, data.set_replacements, data.replacements)
  end

  defp reindex_after_update({:ok, report}) do
    reindex_report(report)

    {:ok, report}
  end

  defp reindex_after_update(result) do
    result
  end

  @doc """
  Callback for post-transaction update.

  See `close_report_query/2` for more information and example.
  """
  def reindex_reports(report_ids) do
    Exq.enqueue(Exq, "indexing", IndexWorker, ["Reports", "id", report_ids])

    report_ids
  end

  @doc false
  def reindex_report(%Report{} = report) do
    Exq.enqueue(Exq, "indexing", IndexWorker, ["Reports", "id", [report.id]])

    report
  end

  @doc false
  def perform_reindex(column, condition) do
    Report
    |> where([r], field(r, ^column) in ^condition)
    |> preload([:user, :admin])
    |> Repo.all()
    |> preload_targets()
    |> Enum.map(&Search.index_document(&1, Report))
  end

  @doc """
  Preloads the target associations onto the given report(s).
  """
  def preload_targets(%Report{} = report) do
    Repo.preload(report, Report.target_preloads())
  end

  def preload_targets(reports) do
    reports
    |> Enum.to_list()
    |> Repo.preload(Report.target_preloads())
  end

  def indexing_preloads do
    [
      :user,
      :admin,
      :reported_user,
      image: from(i in Image, preload: :user),
      comment: from(c in Comment, preload: :user),
      post: from(p in Post, preload: :user),
      commission: from(x in Commission, preload: :user),
      conversation: from(c in Conversation, preload: [:from, :to]),
      gallery: from(g in Gallery, preload: :user)
    ]
  end

  def convert_reports!() do
    rules =
      Rules.list_reportable_rules()
      |> Enum.map(&{&1.name, &1})
      |> Map.new()

    Report
    |> preload([:rule])
    |> Batch.records(batch_size: 128)
    |> Enum.each(&convert_report(&1, rules))
  end

  defp convert_report(%Report{rule_id: 1, reason: report_reason} = report, rules) do
    match = Regex.run(@reason_regex, report_reason)

    case match do
      [_, prefix, suffix, reason] ->
        rule =
          case Map.get(rules, "#{prefix}#{suffix}") do
            nil -> %{id: 1}
            rule -> rule
          end

        report
        |> Report.conversion_changeset(%{reason: String.trim(reason)}, rule)
        |> Repo.update!()

      _ ->
        {:error, report}
    end
  end

  defp convert_report(report, _rules), do: {:ok, report}
end
