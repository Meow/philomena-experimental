defmodule Philomena.Reports do
  @moduledoc """
  The Reports context.
  """

  import Ecto.Query, warn: false

  import Philomena.Authorization,
    only: [authorize: 3, verify_write_access: 1, verify_not_banned: 1]

  alias Philomena.Repo

  alias PhilomenaQuery.Batch
  alias PhilomenaQuery.Search
  alias Philomena.Attribution.Actor
  alias Philomena.Commissions.Commission
  alias Philomena.Conversations.Conversation
  alias Philomena.Galleries.Gallery
  alias Philomena.Images.Image
  alias Philomena.IntegerId
  alias Philomena.Users.User
  alias Philomena.Reports.Report
  alias Philomena.Reports.ReportPage
  alias Philomena.Reports.Query
  alias Philomena.Reports
  alias Philomena.IndexWorker
  alias Philomena.ModNotes
  alias Philomena.ModNotes.ModNote
  alias Philomena.Polymorphic
  alias Philomena.Rules

  @max_open_reports 5

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
  Assembles the admin report listing, on behalf of `actor`, for the given raw
  request `params` and `pagination`.

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
  @spec load_report_index(User.t() | nil, map(), map() | keyword()) ::
          {:ok, ReportPage.t()} | {:error, :unauthorized}
  def load_report_index(actor, params, pagination) do
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
                %{term: %{admin_id: actor.id}},
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
    reports =
      Report
      |> Search.search_definition(
        %{
          query: query,
          sort: report_sorts()
        },
        pagination
      )
      |> Search.search_records(preload(Report, [:admin, :rule, user: :linked_tags]))

    entries = Polymorphic.load_polymorphic(reports, reportable: [reportable_id: :reportable_type])

    %{reports | entries: entries}
  end

  defp own_open_reports(actor) do
    Report
    |> where(open: true, admin_id: ^actor.id)
    |> preload([:admin, :rule, user: :linked_tags])
    |> order_by(desc: :created_at)
    |> Repo.all()
    |> Polymorphic.load_polymorphic(reportable: [reportable_id: :reportable_type])
  end

  defp open_system_reports do
    Report
    |> where(open: true, system: true)
    |> preload([:admin, :rule, user: :linked_tags])
    |> order_by(desc: :created_at)
    |> Repo.all()
    |> Polymorphic.load_polymorphic(reportable: [reportable_id: :reportable_type])
  end

  defp report_sorts do
    [
      %{open: :desc},
      %{state: :desc},
      %{created_at: :desc}
    ]
  end

  @doc """
  Loads the report named by the raw request `id` for display, on behalf of
  `actor`, with the admin, rule, and reporting-user associations preloaded and
  its reportable resolved.

  Authorizes `:show` against the loaded report: a non-castable id is
  `{:error, :not_found}`, and a well-formed id naming no row authorizes `nil`,
  which no ordinary rule permits, so it is `{:error, :unauthorized}`
  (`{:error, :not_found}` for admins, whose grant covers `nil`).

  Returns `{:ok, report}`, `{:error, :unauthorized}`, or `{:error, :not_found}`.

  ## Examples

      iex> load_report(admin, "1")
      {:ok, %Report{}}

  """
  @spec load_report(User.t() | nil, any()) ::
          {:ok, Report.t()} | {:error, :unauthorized | :not_found}
  def load_report(actor, id) do
    with {:ok, id} <- IntegerId.parse(id),
         report = load_report_with_preloads(id),
         :ok <- authorize(actor, :show, report),
         %Report{} <- report do
      [report] =
        Polymorphic.load_polymorphic([report], reportable: [reportable_id: :reportable_type])

      {:ok, report}
    else
      {:error, :unauthorized} -> {:error, :unauthorized}
      _ -> {:error, :not_found}
    end
  end

  defp load_report_with_preloads(id) do
    Report
    |> preload([:admin, :rule, user: [:linked_tags, awards: :badge]])
    |> Repo.get(id)
  end

  @doc """
  Returns the mod notes attached to `report` for `viewer`, rendered with
  `collection_renderer`, or `nil` when the viewer may not read mod notes.
  """
  @spec mod_notes(User.t() | nil, Report.t(), (list() -> list())) :: list() | nil
  def mod_notes(viewer, report, collection_renderer) do
    if Canada.Can.can?(viewer, :index, ModNote) do
      ModNotes.list_all_mod_notes_by_type_and_id("Report", report.id, collection_renderer)
    end
  end

  @doc """
  Loads the image named by the raw request `image_id` for the report form, on
  behalf of `actor` (a `Philomena.Attribution.Actor` whose user may be `nil` for
  an anonymous visitor).

  This backs the report form (`new`), a GET-guarded action, so a banned actor is
  rejected with `{:error, :ban}` first; the fingerprint requirement the write
  path enforces is skipped here. The image is then loaded and authorized for
  `:show`.

  Returns `{:ok, {image, changeset}}` - the image builds the form action and
  reportable link, and the changeset drives the report form - `{:error, :ban}`
  for a banned actor, `{:error, :unauthorized}` when the image is not visible, or
  `{:error, :not_found}` when the id cannot name a row.

  ## Examples

      iex> load_image_for_report(actor, "1")
      {:ok, {%Image{}, %Ecto.Changeset{}}}

  """
  @spec load_image_for_report(Actor.t(), any()) ::
          {:ok, {Image.t(), Ecto.Changeset.t()}}
          | {:error, :ban | :unauthorized | :not_found}
  def load_image_for_report(%Actor{} = actor, image_id) do
    with :ok <- verify_not_banned(actor),
         {:ok, image} <- load_reportable_image(actor.user, image_id) do
      changeset = change_report(%Report{reportable_type: "Image", reportable_id: image.id})
      {:ok, {image, changeset}}
    end
  end

  @doc """
  Loads the image named by the raw request `image_id` for report submission, on
  behalf of `actor` (a `Philomena.Attribution.Actor` whose user may be `nil`).

  This backs the report submission (`create`), a write, so `actor`'s write access
  is verified first: a banned actor is `{:error, :ban}` and an actor with no
  fingerprint is `{:error, :unauthorized}`. The image is then loaded and
  authorized for `:show`.

  Returns `{:ok, image}` - it builds the redirect action and the report -
  `{:error, :ban}` or `{:error, :unauthorized}` from the write-access check,
  `{:error, :unauthorized}` when the image is not visible, or
  `{:error, :not_found}` when the id cannot name a row.

  ## Examples

      iex> load_image_for_report_creation(actor, "1")
      {:ok, %Image{}}

  """
  @spec load_image_for_report_creation(Actor.t(), any()) ::
          {:ok, Image.t()} | {:error, :ban | :unauthorized | :not_found}
  def load_image_for_report_creation(%Actor{} = actor, image_id) do
    with :ok <- verify_write_access(actor) do
      load_reportable_image(actor.user, image_id)
    end
  end

  # Loads the reported image by id and authorizes it for `:show`. A non-castable
  # id is `{:error, :not_found}`; a well-formed id that names no row authorizes
  # `nil`, which no rule permits, so it is `{:error, :unauthorized}`.
  defp load_reportable_image(user, image_id) do
    case IntegerId.parse(image_id) do
      {:ok, id} ->
        image =
          Image
          |> preload([:sources, tags: :aliases])
          |> Repo.get(id)

        with :ok <- authorize(user, :show, image), do: {:ok, image}

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Loads the gallery named by the raw request `gallery_id` for the report form,
  on behalf of `actor` (a `Philomena.Attribution.Actor` whose user may be
  `nil`).

  Banned actors are rejected first with `{:error, :ban}`. The gallery is then
  loaded and authorized for `:show`: a non-castable id is
  `{:error, :not_found}`, and a well-formed id that names no row authorizes
  `nil`, which no ordinary rule permits, so it is `{:error, :unauthorized}`
  (`{:error, :not_found}` for viewers whose grants cover `nil`).

  Returns `{:ok, {gallery, changeset}}` with the changeset backing the report
  form.

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
      changeset = change_report(%Report{reportable_type: "Gallery", reportable_id: gallery.id})
      {:ok, {gallery, changeset}}
    end
  end

  @doc """
  Loads the gallery named by the raw request `gallery_id` for report
  submission, on behalf of `actor`.

  This backs a write, so the actor's write access is verified first: a banned
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
    case IntegerId.parse(gallery_id) do
      {:ok, id} ->
        gallery = Repo.get(Gallery, id)

        with :ok <- authorize(user, :show, gallery),
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

  @doc """
  Loads the user named by the raw request profile `slug` for the report form,
  on behalf of `actor`.

  Banned actors are rejected first with `{:error, :ban}`. The user is then
  loaded by slug and authorized for `:show`; an unknown slug authorizes `nil`,
  which no ordinary rule permits, so it is `{:error, :unauthorized}`
  (`{:error, :not_found}` for viewers whose grants cover `nil`).

  Returns `{:ok, {user, changeset}}` with the changeset backing the report
  form.

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
      changeset = change_report(%Report{reportable_type: "User", reportable_id: user.id})
      {:ok, {user, changeset}}
    end
  end

  @doc """
  Loads the user named by the raw request profile `slug` for report
  submission, on behalf of `actor`.

  This backs a write, so the actor's write access is verified first: a banned
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
  Loads the user named by the raw request profile `slug` together with their
  commission for the report form, on behalf of `actor`.

  Banned actors are rejected first with `{:error, :ban}`. Viewing a commission
  report form needs no permission, so an unknown slug and a user without a
  commission are both `{:error, :not_found}`. The commission carries the
  preloads its report page renders.

  Returns `{:ok, {user, commission, changeset}}` with the changeset backing
  the report form.

  ## Examples

      iex> load_commission_for_report(actor, "artist")
      {:ok, {%User{}, %Commission{}, %Ecto.Changeset{}}}

  """
  @spec load_commission_for_report(Actor.t(), String.t()) ::
          {:ok, {User.t(), Commission.t(), Ecto.Changeset.t()}}
          | {:error, :ban | :not_found}
  def load_commission_for_report(%Actor{} = actor, slug) do
    with :ok <- verify_not_banned(actor),
         {:ok, {user, commission}} <- load_reportable_commission(slug) do
      changeset =
        change_report(%Report{reportable_type: "Commission", reportable_id: commission.id})

      {:ok, {user, commission, changeset}}
    end
  end

  @doc """
  Loads the user named by the raw request profile `slug` together with their
  commission for report submission, on behalf of `actor`.

  This backs a write, so the actor's write access is verified first: a banned
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
      load_reportable_commission(slug)
    end
  end

  defp load_reportable_commission(slug) do
    user =
      User
      |> where(slug: ^slug)
      |> preload([
        :verified_links,
        commission: [
          sheet_image: [:sources, tags: :aliases],
          user: [awards: :badge],
          items: [example_image: [:sources, tags: :aliases]]
        ]
      ])
      |> Repo.one()

    case user do
      nil -> {:error, :not_found}
      %User{commission: nil} -> {:error, :not_found}
      %User{commission: commission} -> {:ok, {user, commission}}
    end
  end

  @doc """
  Loads the conversation named by the raw request `slug` for the report form,
  on behalf of `actor` (a `Philomena.Attribution.Actor` whose user may be
  `nil`).

  Banned actors are rejected first with `{:error, :ban}`. The conversation is
  then loaded by slug and authorized for `:show`: it is visible to its
  participants, moderators, and admins, so a non-participant is
  `{:error, :unauthorized}`, and a slug naming no row authorizes `nil`, which no
  ordinary rule permits, so it is `{:error, :unauthorized}` (`{:error, :not_found}`
  for admins).

  Returns `{:ok, {conversation, changeset}}` with the changeset backing the
  report form.

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
        change_report(%Report{reportable_type: "Conversation", reportable_id: conversation.id})

      {:ok, {conversation, changeset}}
    end
  end

  @doc """
  Loads the conversation named by the raw request `slug` for report submission,
  on behalf of `actor`.

  This backs a write, so the actor's write access is verified first: a banned
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
  Submits a report against the reportable named by `reportable_type` and
  `reportable_id` from `params`, on behalf of `actor` (a
  `Philomena.Attribution.Actor` whose user may be `nil` for an anonymous
  visitor).

  A regular user or an anonymous IP holding `max_open_reports/0` open reports is
  refused with `{:error, :too_many_reports}`; staff are exempt. Otherwise the
  report is inserted with the IP, fingerprint, and user carried by `actor`, and
  reindexed.

  Returns `{:ok, report}` on success, `{:error, :too_many_reports}` when the open
  report limit is reached, or `{:error, %Ecto.Changeset{}}` when the insert is
  rejected.

  ## Examples

      iex> create_report(actor, "Comment", 1, %{"reason" => "Spam"})
      {:ok, %Report{}}

      iex> create_report(actor, "Comment", 1, %{"reason" => ""})
      {:error, %Ecto.Changeset{}}

  """
  @spec create_report(Actor.t(), String.t(), integer(), map() | nil) ::
          {:ok, Report.t()} | {:error, :too_many_reports} | {:error, Ecto.Changeset.t()}
  def create_report(%Actor{} = actor, reportable_type, reportable_id, params) do
    if too_many_reports?(actor) do
      {:error, :too_many_reports}
    else
      create_report({reportable_type, reportable_id}, actor_attributes(actor), params || %{})
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
  Creates a report.

  ## Examples

      iex> create_report(%{field: value})
      {:ok, %Report{}}

      iex> create_report(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_report({reportable_type, reportable_id} = _type_and_id, attribution, attrs \\ %{}) do
    rule = Rules.find_rule(attrs["rule_id"])

    %Report{reportable_type: reportable_type, reportable_id: reportable_id}
    |> Report.user_creation_changeset(attrs, attribution, rule)
    |> Repo.insert()
    |> reindex_after_update()
  end

  @doc """
  Returns an `m:Ecto.Query` which updates all open reports for the given `reportable_type`
  and `reportable_id` to close them.

  Because this is only a query due to the limitations of `m:Ecto.Multi`, this must be
  coupled with an associated call to `reindex_reports/1` to operate correctly, e.g.:

      report_query = Reports.close_report_query({"Image", image.id}, user)

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

      iex> close_report_query({"Image", 1}, %User{})
      #Ecto.Query<...>

  """
  def close_report_query({reportable_type, reportable_id} = _type_and_id, closing_user) do
    now = DateTime.utc_now(:second)

    from r in Report,
      where:
        r.reportable_type == ^reportable_type and r.reportable_id == ^reportable_id and
          r.open == true,
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
  Closes all open reports for the given reportable type and ID, marking them as closed by the specified user.
  Also reindexes the affected reports.

  Returns `{:ok, {count, reports}}`.
  """
  def close_reports(type_and_id, closing_user) do
    {_count, reports} =
      result = Repo.update_all(close_report_query(type_and_id, closing_user), [])

    reindex_reports(reports)
    {:ok, result}
  end

  @doc """
  Automatically create a report with the given rule and reason on the given
  `reportable_id` and `reportable_type`.

  ## Examples

      iex> create_system_report({"Comment", 1}, "Rule #0", "Custom report reason")
      {:ok, %Report{}}

  """
  def create_system_report({reportable_type, reportable_id} = _type_and_id, rule_name, reason) do
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

    %Report{reportable_type: reportable_type, reportable_id: reportable_id}
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
    Report.changeset(report, %{})
  end

  @doc """
  Marks the report named by the raw request `id` as claimed by `actor`, on
  behalf of `actor` (the acting staff user), and reindexes it.

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
  @spec claim_report(User.t() | nil, any()) ::
          {:ok, Report.t()} | {:error, :unauthorized | :not_found | Ecto.Changeset.t()}
  def claim_report(actor, id) do
    with {:ok, report} <- load_report_for_edit(actor, id) do
      report
      |> Report.claim_changeset(actor)
      |> Repo.update()
      |> reindex_after_update()
    end
  end

  @doc """
  Marks the report named by the raw request `id` as unclaimed, on behalf of
  `actor` (the acting staff user), and reindexes it.

  Loading and authorization follow `claim_report/2`, authorizing `:edit`.

  Returns `{:ok, report}`, `{:error, :unauthorized}`, `{:error, :not_found}`, or
  `{:error, %Ecto.Changeset{}}`.

  ## Example

      iex> unclaim_report(moderator, "1")
      {:ok, %Report{}}

  """
  @spec unclaim_report(User.t() | nil, any()) ::
          {:ok, Report.t()} | {:error, :unauthorized | :not_found | Ecto.Changeset.t()}
  def unclaim_report(actor, id) do
    with {:ok, report} <- load_report_for_edit(actor, id) do
      report
      |> Report.unclaim_changeset()
      |> Repo.update()
      |> reindex_after_update()
    end
  end

  @doc """
  Marks the report as closed by the given user.

  ## Example

      iex> close_report(%Report{}, %User{})
      {:ok, %Report{}}

  """
  def close_report(%Report{} = report, user) do
    report
    |> Report.close_changeset(user)
    |> Repo.update()
    |> reindex_after_update()
  end

  # Loads the report named by the raw request `id` and authorizes `:edit`
  # against it, matching the report claim/close controllers' resource guard.
  defp load_report_for_edit(actor, id) do
    with {:ok, id} <- IntegerId.parse(id),
         report = Repo.get(Report, id),
         :ok <- authorize(actor, :edit, report),
         %Report{} <- report do
      {:ok, report}
    else
      {:error, :unauthorized} -> {:error, :unauthorized}
      _ -> {:error, :not_found}
    end
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
    |> Polymorphic.load_polymorphic(reportable: [reportable_id: :reportable_type])
    |> Enum.map(&Search.index_document(&1, Report))
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
