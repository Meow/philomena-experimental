defmodule Philomena.Reports do
  @moduledoc """
  Report forms, submission limits, staff review, and report search indexing.

  Request-facing functions take an attribution actor first. Report forms use a
  tagged target locator so the form and its submission share one safely loaded,
  authorized target. Staff transitions lock the report row and commit their
  moderation log in the same database transaction.
  """

  import Ecto.Query, warn: false
  import Philomena.Authorization, only: [authorize: 3, verify_write_access: 1]

  alias Ecto.Multi
  alias Philomena.Attribution.Actor
  alias Philomena.Comments
  alias Philomena.Comments.Comment
  alias Philomena.Commissions
  alias Philomena.Commissions.Commission
  alias Philomena.Conversations
  alias Philomena.Conversations.Conversation
  alias Philomena.Galleries
  alias Philomena.Galleries.Gallery
  alias Philomena.Images
  alias Philomena.Images.Image
  alias Philomena.IndexWorker
  alias Philomena.IntegerId
  alias Philomena.Loader
  alias Philomena.ModerationLogs
  alias Philomena.ModerationLogs.Paths
  alias Philomena.ModNotes
  alias Philomena.Posts
  alias Philomena.Posts.Post
  alias Philomena.Repo
  alias Philomena.Reports
  alias Philomena.Reports.Query
  alias Philomena.Reports.Report
  alias Philomena.Reports.ReportForm
  alias Philomena.Reports.ReportPage
  alias Philomena.Rules
  alias Philomena.Users
  alias Philomena.Users.User
  alias PhilomenaQuery.Batch
  alias PhilomenaQuery.Search

  @max_open_reports 5
  @default_preloads [:admin, :rule, user: :linked_tags]
  @reason_regex ~r/^(Rule|Other|Takedown|Verification|Approval|Review|System)([^:]*): (.*)$/

  @typedoc "A route-shaped locator for one reportable target."
  @type target_locator ::
          {:image, Loader.integer_id()}
          | {:comment, Loader.integer_id(), Loader.integer_id()}
          | {:post, String.t(), String.t(), Loader.integer_id()}
          | {:user, String.t()}
          | {:commission, String.t()}
          | {:conversation, String.t()}
          | {:gallery, Loader.integer_id()}

  @type request_error :: :ban | :unauthorized | :not_found
  @type transition_error :: :unauthorized | :not_found | Ecto.Changeset.t()

  defp report_query(preloads) do
    Report
    |> preload(^preloads)
    |> preload(^Report.target_preloads())
  end

  defp searched_reports(query, pagination) do
    Report
    |> Search.search_definition(%{query: query, sort: report_sorts()}, pagination)
    |> Search.search_records(report_query(@default_preloads))
  end

  defp own_open_reports(%Actor{user: %User{id: user_id}}) do
    Report
    |> where(open: true, admin_id: ^user_id)
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
    [%{open: :desc}, %{state: :desc}, %{created_at: :desc}]
  end

  defp build_report_page(_actor, %{"rq" => query_string}, pagination)
       when is_binary(query_string) do
    case Query.compile(query_string) do
      {:ok, query} ->
        {:ok,
         %ReportPage{
           reports: searched_reports(query, pagination),
           my_reports: [],
           system_reports: []
         }}

      _error ->
        {:error, :invalid_query}
    end
  end

  defp build_report_page(_actor, %{"rq" => _query_string}, _pagination) do
    {:error, :invalid_query}
  end

  defp build_report_page(%Actor{user: %User{id: user_id}} = actor, _params, pagination) do
    query = %{
      bool: %{
        should: [
          %{term: %{open: false}},
          %{
            bool: %{
              must: %{term: %{open: true}},
              must_not: [%{term: %{admin_id: user_id}}, %{term: %{system: true}}]
            }
          }
        ]
      }
    }

    {:ok,
     %ReportPage{
       reports: searched_reports(query, pagination),
       my_reports: own_open_reports(actor),
       system_reports: open_system_reports()
     }}
  end

  defp load_report_target(actor, {:image, image_id}) do
    Images.load_report_target(actor, image_id)
  end

  defp load_report_target(actor, {:comment, image_id, comment_id}) do
    Comments.load_report_target(actor, image_id, comment_id)
  end

  defp load_report_target(actor, {:post, forum_slug, topic_slug, post_id}) do
    Posts.load_report_target(actor, forum_slug, topic_slug, post_id)
  end

  defp load_report_target(actor, {:user, slug}) do
    Users.load_report_target(actor, slug)
  end

  defp load_report_target(actor, {:commission, slug}) do
    Commissions.load_report_target(actor, slug)
  end

  defp load_report_target(actor, {:conversation, slug}) do
    Conversations.load_report_target(actor, slug)
  end

  defp load_report_target(actor, {:gallery, gallery_id}) do
    Galleries.load_report_target(actor, gallery_id)
  end

  defp report_target(%Image{id: id}), do: [image_id: id]
  defp report_target(%Comment{id: id}), do: [comment_id: id]
  defp report_target(%Post{id: id}), do: [post_id: id]
  defp report_target(%User{id: id}), do: [reported_user_id: id]
  defp report_target(%Commission{id: id}), do: [commission_id: id]
  defp report_target(%Conversation{id: id}), do: [conversation_id: id]
  defp report_target(%Gallery{id: id}), do: [gallery_id: id]

  defp change_report(target) do
    target
    |> report_target()
    |> then(&struct(Report, &1))
    |> Report.changeset(%{})
  end

  defp report_form(target, changeset \\ nil) do
    %ReportForm{target: target, changeset: changeset || change_report(target)}
  end

  defp actor_attributes(%Actor{ip: ip, fingerprint: fingerprint, user: user}) do
    [ip: ip, fingerprint: fingerprint, user: user]
  end

  defp ensure_report_limit(%Actor{} = actor) do
    if exempt_from_report_limit?(actor) or not too_many_reports?(actor) do
      :ok
    else
      {:error, :too_many_reports}
    end
  end

  defp exempt_from_report_limit?(actor) do
    authorize(actor, :bypass_submission_limit, Report) == :ok
  end

  defp too_many_reports?(%Actor{user: user, ip: ip}) do
    open_reports_for_user?(user) or open_reports_for_ip?(ip)
  end

  defp open_reports_for_user?(nil), do: false

  defp open_reports_for_user?(%User{id: user_id}) do
    open_report_count(where(Report, user_id: ^user_id)) >= @max_open_reports
  end

  defp open_reports_for_ip?(ip) do
    open_report_count(where(Report, ip: ^ip)) >= @max_open_reports
  end

  defp open_report_count(query) do
    query
    |> where([report], report.state in ["open", "in_progress"])
    |> Repo.aggregate(:count, :id)
  end

  defp insert_user_report(actor, attrs, target) do
    rule = Rules.find_rule(attrs["rule_id"])

    target
    |> report_target()
    |> then(&struct(Report, &1))
    |> Report.user_creation_changeset(attrs, actor_attributes(actor), rule)
    |> Repo.insert()
  end

  defp create_loaded_report(actor, attrs, target) do
    attrs = if is_map(attrs), do: attrs, else: %{}

    case insert_user_report(actor, attrs, target) do
      {:ok, report} ->
        reindex_report(report)
        {:ok, report}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, report_form(target, changeset)}
    end
  end

  defp close_report_query(%User{id: user_id}, [{column, id}])
       when column in [
              :image_id,
              :comment_id,
              :post_id,
              :reported_user_id,
              :commission_id,
              :conversation_id,
              :gallery_id
            ] do
    now = DateTime.utc_now(:second)

    from report in Report,
      where: field(report, ^column) == ^id and report.open == true,
      select: report.id,
      update: [
        set: [open: false, state: "closed", admin_id: ^user_id, updated_at: ^now]
      ]
  end

  defp locked_report(repo, actor, id, action) do
    report =
      Report
      |> where(id: ^id)
      |> lock("FOR UPDATE")
      |> repo.one()

    with %Report{} <- report,
         :ok <- authorize(actor, action, report) do
      {:ok, report}
    else
      nil -> {:error, :not_found}
      {:error, :unauthorized} = error -> error
    end
  end

  defp invalid_transition(report, field, message) do
    report
    |> Report.changeset(%{})
    |> Ecto.Changeset.add_error(field, message)
  end

  defp claim_transition(%Report{open: false} = report, _user) do
    {:error, invalid_transition(report, :state, "must be open")}
  end

  defp claim_transition(%Report{admin_id: admin_id} = report, _user)
       when not is_nil(admin_id) do
    {:error, invalid_transition(report, :admin_id, "has already been claimed")}
  end

  defp claim_transition(report, user), do: {:ok, Report.claim_changeset(report, user)}

  defp unclaim_transition(%Report{open: false} = report, _user) do
    {:error, invalid_transition(report, :state, "must be open")}
  end

  defp unclaim_transition(%Report{admin_id: nil}, _user), do: {:ok, :noop}
  defp unclaim_transition(report, _user), do: {:ok, Report.unclaim_changeset(report)}

  defp close_transition(%Report{open: false}, _user), do: {:ok, :noop}
  defp close_transition(report, user), do: {:ok, Report.close_changeset(report, user)}

  defp transition_report(actor, id, action, transition, log_type, log_body) do
    case IntegerId.parse(id) do
      {:ok, report_id} ->
        transact_report_transition(
          actor,
          report_id,
          action,
          transition,
          log_type,
          log_body
        )
        |> normalize_transition_result()

      :error ->
        {:error, :not_found}
    end
  end

  defp transact_report_transition(actor, report_id, action, transition, log_type, log_body) do
    Repo.transaction(fn ->
      with {:ok, report} <- locked_report(Repo, actor, report_id, action),
           {:ok, transition_result} <- transition.(report, actor.user) do
        persist_transition(
          actor,
          report_id,
          report,
          transition_result,
          log_type,
          log_body
        )
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp persist_transition(_actor, _report_id, report, :noop, _log_type, _log_body) do
    {report, false}
  end

  defp persist_transition(
         actor,
         report_id,
         _report,
         %Ecto.Changeset{} = changeset,
         log_type,
         log_body
       ) do
    Multi.new()
    |> Multi.update(:report, changeset)
    |> ModerationLogs.put_log(
      :moderation_log,
      actor,
      log_type,
      Paths.admin_report_path(report_id),
      log_body
    )
    |> Repo.transact()
    |> case do
      {:ok, %{report: report}} -> {report, true}
      {:error, _step, reason, _changes} -> Repo.rollback(reason)
    end
  end

  defp normalize_transition_result({:ok, {report, changed?}}) do
    if changed?, do: reindex_report(report)
    {:ok, report}
  end

  defp normalize_transition_result({:error, reason}), do: {:error, reason}

  defp reindex_report(%Report{id: id} = report) do
    Exq.enqueue(Exq, "indexing", IndexWorker, ["Reports", "id", [id]])
    report
  end

  defp preload_targets(reports) do
    reports
    |> List.wrap()
    |> Repo.preload(Report.target_preloads())
  end

  defp convert_report(%Report{rule_id: 1, reason: report_reason} = report, rules) do
    case Regex.run(@reason_regex, report_reason) do
      [_, prefix, suffix, reason] ->
        rule = Map.get(rules, "#{prefix}#{suffix}", %{id: 1})

        report
        |> Report.conversion_changeset(%{reason: String.trim(reason)}, rule)
        |> Repo.update!()

      _other ->
        {:error, report}
    end
  end

  defp convert_report(report, _rules), do: {:ok, report}

  @doc """
  Returns the maximum number of open reports allowed for a regular submitter.

  ## Examples

      iex> max_open_reports()
      5
  """
  @spec max_open_reports() :: pos_integer()
  def max_open_reports, do: @max_open_reports

  @doc """
  Returns the number of open reports visible in the staff counter.

  The count is authorized with `:index` on `Report`; unauthorized actors receive
  `nil`, which lets the shared counter plug omit the value.

  ## Examples

      iex> count_open_reports(moderator)
      4

      iex> count_open_reports(user)
      nil
  """
  @spec count_open_reports(Actor.t()) :: non_neg_integer() | nil
  def count_open_reports(%Actor{} = actor) do
    case authorize(actor, :index, Report) do
      :ok ->
        Report
        |> where(open: true)
        |> Repo.aggregate(:count)

      {:error, :unauthorized} ->
        nil
    end
  end

  @doc """
  Loads the signed-in actor's reports, newest first.

  Results are scoped to `actor.user` before the target associations are
  preloaded. Anonymous actors are unauthorized.

  ## Examples

      iex> load_user_reports(actor, pagination)
      {:ok, %Scrivener.Page{}}

      iex> load_user_reports(anonymous, pagination)
      {:error, :unauthorized}
  """
  @spec load_user_reports(Actor.t(), Repo.pagination_params()) ::
          {:ok, Scrivener.Page.t(Report.t())} | {:error, :unauthorized}
  def load_user_reports(%Actor{user: user} = actor, pagination) do
    with :ok <- authorize(actor, :index_own, Report) do
      reports =
        Report
        |> where(user_id: ^user.id)
        |> order_by(desc: :created_at)
        |> preload(:rule)
        |> Repo.paginate(pagination)

      {:ok, %{reports | entries: preload_targets(reports.entries)}}
    end
  end

  @doc """
  Loads the staff report index described by `params` and `pagination`.

  Access is authorized with `:index` before any report query runs. An `"rq"`
  parameter selects the report search language; malformed search text returns
  `{:error, :invalid_query}` instead of raising.

  ## Examples

      iex> load_report_index(admin, %{"rq" => "open:true"}, pagination)
      {:ok, %ReportPage{}}

      iex> load_report_index(user, %{}, pagination)
      {:error, :unauthorized}
  """
  @spec load_report_index(Actor.t(), map(), Repo.pagination_params()) ::
          {:ok, ReportPage.t()} | {:error, :unauthorized | :invalid_query}
  def load_report_index(%Actor{} = actor, params, pagination) do
    with :ok <- authorize(actor, :index, Report) do
      build_report_page(actor, params, pagination)
    end
  end

  @doc """
  Loads a report for the staff show page with its target associations resolved.

  Malformed and missing IDs are always not-found. A real report the actor may
  not show is unauthorized.

  ## Examples

      iex> load_report(moderator, "1")
      {:ok, %Report{}}

      iex> load_report(moderator, "999999999")
      {:error, :not_found}
  """
  @spec load_report(Actor.t(), Loader.integer_id()) ::
          {:ok, Report.t()} | {:error, :unauthorized | :not_found}
  def load_report(%Actor{} = actor, id) do
    Loader.fetch_and_authorize(report_query(@default_preloads), actor, :show, id)
  end

  @doc """
  Returns rendered moderator notes attached to `report`, or `nil` when the actor
  may not read them.

  The note context separately authorizes the report with `:show_mod_notes`, so
  sensitive note queries do not run before that gate.

  ## Examples

      iex> mod_notes(moderator, report, renderer)
      [{%ModNote{}, "rendered"}]

      iex> mod_notes(user, report, renderer)
      nil
  """
  @spec mod_notes(Actor.t(), Report.t(), (list() -> list())) :: list() | nil
  def mod_notes(%Actor{} = actor, %Report{} = report, collection_renderer) do
    case ModNotes.list_for_target(actor, {:report, report.id}, collection_renderer) do
      {:ok, notes} -> notes
      {:error, _reason} -> nil
    end
  end

  @doc """
  Builds a report form for the target described by `locator`.

  Write access is verified before the owning context safely loads and authorizes
  the target. The returned `ReportForm` retains both the target and its empty
  report changeset. Malformed and missing locators are not-found for every
  actor; hidden or otherwise forbidden real targets are unauthorized.

  ## Examples

      iex> new_report(actor, {:image, "1"})
      {:ok, %ReportForm{target: %Image{}}}

      iex> new_report(banned_actor, {:image, "1"})
      {:error, :ban}
  """
  @spec new_report(Actor.t(), target_locator()) ::
          {:ok, ReportForm.t()} | {:error, request_error()}
  def new_report(%Actor{} = actor, locator) do
    with :ok <- verify_write_access(actor),
         {:ok, target} <- load_report_target(actor, locator) do
      {:ok, report_form(target)}
    end
  end

  @doc """
  Creates a report for the safely loaded target described by `locator`.

  The same write-access, loading, and visibility checks as `new_report/2` run
  before the open-report limit is queried. Staff with the named limit-bypass
  ability are exempt. A rejected insert returns a `ReportForm` carrying the
  loaded target and rejected changeset, while a successful insert queues the
  report for search indexing.

  ## Examples

      iex> create_report(actor, {:image, "1"}, %{"reason" => "Spam"})
      {:ok, %Report{}}

      iex> create_report(actor, {:image, "1"}, %{"reason" => ""})
      {:error, %ReportForm{changeset: %Ecto.Changeset{}}}

      iex> create_report(actor, {:image, "1"}, attrs)
      {:error, :too_many_reports}
  """
  @spec create_report(Actor.t(), target_locator(), map() | nil) ::
          {:ok, Report.t()}
          | {:error, :too_many_reports | request_error()}
          | {:error, ReportForm.t()}
  def create_report(%Actor{} = actor, locator, attrs) do
    with :ok <- verify_write_access(actor),
         {:ok, target} <- load_report_target(actor, locator),
         :ok <- ensure_report_limit(actor) do
      create_loaded_report(actor, attrs, target)
    end
  end

  @doc """
  Claims an open, unclaimed report for the acting staff member.

  The report is loaded under a row lock and authorized with `:claim`. A racing
  or repeated claim returns a changeset error rather than reassigning the
  report. The update and moderation log commit atomically; indexing is queued
  only after they succeed.

  ## Examples

      iex> claim_report(moderator, "1")
      {:ok, %Report{state: "in_progress"}}

      iex> claim_report(user, "1")
      {:error, :unauthorized}
  """
  @spec claim_report(Actor.t(), Loader.integer_id()) ::
          {:ok, Report.t()} | {:error, transition_error()}
  def claim_report(%Actor{} = actor, id) do
    transition_report(
      actor,
      id,
      :claim,
      &claim_transition/2,
      "Report.Claim:create",
      "Claimed report"
    )
  end

  @doc """
  Releases the claim on an open report.

  The report is row-locked and authorized with `:unclaim`. Releasing an already
  unclaimed report is an idempotent success with no write, log, or index job.
  A real update and its moderation log commit atomically.

  ## Examples

      iex> unclaim_report(moderator, "1")
      {:ok, %Report{state: "open"}}
  """
  @spec unclaim_report(Actor.t(), Loader.integer_id()) ::
          {:ok, Report.t()} | {:error, transition_error()}
  def unclaim_report(%Actor{} = actor, id) do
    transition_report(
      actor,
      id,
      :unclaim,
      &unclaim_transition/2,
      "Report.Claim:delete",
      "Released report"
    )
  end

  @doc """
  Closes a report on behalf of the acting staff member.

  The report is row-locked and authorized with `:close`. Closing an already
  closed report is an idempotent success with no write, log, or index job. A
  real close and its moderation log commit atomically.

  ## Examples

      iex> close_report(moderator, "1")
      {:ok, %Report{state: "closed", open: false}}
  """
  @spec close_report(Actor.t(), Loader.integer_id()) ::
          {:ok, Report.t()} | {:error, transition_error()}
  def close_report(%Actor{} = actor, id) do
    transition_report(
      actor,
      id,
      :close,
      &close_transition/2,
      "Report.Close:create",
      "Closed report"
    )
  end

  @doc """
  Adds a bulk close of reports for one already loaded target to `multi`.

  This is the transaction-composition API for owning contexts that delete or
  approve a reportable target. The step returns `{count, report_ids}`; pass the
  IDs to `reindex_closed_reports/1` only after the owning transaction commits.

  ## Examples

      iex> put_close_reports(multi, :reports, moderator, image_id: image.id)
      %Ecto.Multi{}
  """
  @spec put_close_reports(Multi.t(), Multi.name(), User.t(), keyword()) :: Multi.t()
  def put_close_reports(%Multi{} = multi, step, %User{} = closing_user, target) do
    Multi.update_all(multi, step, close_report_query(closing_user, target), [])
  end

  @doc """
  Closes and reindexes reports for one trusted, already loaded target.

  This service is reserved for non-controller erasure workflows that cannot
  compose the close into a larger `Ecto.Multi`.

  ## Examples

      iex> close_reports(moderator, reported_user_id: user.id)
      {:ok, {2, [1, 2]}}
  """
  @spec close_reports(User.t(), keyword()) :: {:ok, {non_neg_integer(), [integer()]}}
  def close_reports(%User{} = closing_user, target) do
    result = Repo.update_all(close_report_query(closing_user, target), [])
    {_count, report_ids} = result
    reindex_closed_reports(report_ids)
    {:ok, result}
  end

  @doc """
  Creates and indexes an internal system report for an already loaded target.

  The rule name must identify a reportable rule. This trusted service is used by
  owning contexts after their target has been created or moderated.

  ## Examples

      iex> create_system_report("Approval", "Needs review", comment_id: comment.id)
      {:ok, %Report{system: true}}

      iex> create_system_report("Missing", "Needs review", comment_id: comment.id)
      {:error, :not_found}
  """
  @spec create_system_report(String.t(), String.t(), keyword()) ::
          {:ok, Report.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def create_system_report(rule_name, reason, target) do
    with {:ok, rule} <- Rules.fetch_rule_by_name(rule_name) do
      attrs = %{reason: reason, user_agent: "system"}

      attribution = %{
        system: true,
        ip: %Postgrex.INET{address: {127, 0, 0, 1}, netmask: 32},
        fingerprint: "ffff"
      }

      result =
        target
        |> then(&struct(Report, &1))
        |> Report.creation_changeset(attrs, attribution, rule)
        |> Repo.insert()

      case result do
        {:ok, report} -> {:ok, reindex_report(report)}
        error -> error
      end
    end
  end

  @doc """
  Queues report IDs returned by `put_close_reports/4` for indexing.

  Call this only after the owning transaction commits, so a rolled-back close
  never publishes stale search state.

  ## Examples

      iex> reindex_closed_reports([1, 2])
      [1, 2]
  """
  @spec reindex_closed_reports([integer()]) :: [integer()]
  def reindex_closed_reports(report_ids) do
    Exq.enqueue(Exq, "indexing", IndexWorker, ["Reports", "id", report_ids])
    report_ids
  end

  @doc """
  Updates indexed user-name fields without rewriting report rows.

  This maintenance callback is invoked after a committed user rename.

  ## Examples

      iex> user_name_reindex("Old Name", "New Name")
      [{:ok, %Req.Response{}}]
  """
  @spec user_name_reindex(String.t(), String.t()) :: [term()]
  def user_name_reindex(old_name, new_name) do
    data = Reports.SearchIndex.user_name_update_by_query(old_name, new_name)
    Search.update_by_query(Report, data.query, data.set_replacements, data.replacements)
  end

  @doc """
  Returns the associations required to serialize reports into OpenSearch.

  This is the batch-indexer contract used by `Philomena.SearchIndexer`.

  ## Examples

      iex> indexing_preloads()
      [:user, :admin, ...]
  """
  @spec indexing_preloads() :: list()
  def indexing_preloads do
    [
      :user,
      :admin,
      :reported_user,
      image: from(image in Image, preload: :user),
      comment: from(comment in Comment, preload: :user),
      post: from(post in Post, preload: :user),
      commission: from(commission in Commission, preload: :user),
      conversation: from(conversation in Conversation, preload: [:from, :to]),
      gallery: from(gallery in Gallery, preload: :user)
    ]
  end

  @doc """
  Reindexes reports matching `column` and `condition` for the index worker.

  `column` is supplied by the trusted worker registry, not request input.

  ## Examples

      iex> perform_reindex(:id, [1, 2])
      [:ok, :ok]
  """
  @spec perform_reindex(atom(), list()) :: list()
  def perform_reindex(column, condition) do
    Report
    |> where([report], field(report, ^column) in ^condition)
    |> preload([:user, :admin])
    |> Repo.all()
    |> preload_targets()
    |> Enum.map(&Search.index_document(&1, Report))
  end

  @doc """
  Converts legacy report reasons to their structured rule and reason fields.

  This release-maintenance operation processes reports in bounded batches and
  raises on a database update failure.

  ## Examples

      iex> convert_reports!()
      :ok
  """
  @spec convert_reports!() :: :ok
  def convert_reports! do
    rules =
      Rules.list_reportable_rules()
      |> Map.new(&{&1.name, &1})

    Report
    |> preload(:rule)
    |> Batch.records(batch_size: 128)
    |> Enum.each(&convert_report(&1, rules))
  end
end
