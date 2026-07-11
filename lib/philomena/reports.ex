defmodule Philomena.Reports do
  @moduledoc """
  The Reports context.
  """

  import Ecto.Query, warn: false
  alias Philomena.Repo

  alias PhilomenaQuery.Batch
  alias PhilomenaQuery.Search
  alias Philomena.Attribution.Actor
  alias Philomena.Reports.Report
  alias Philomena.Reports
  alias Philomena.IndexWorker
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
  Marks the report as claimed by the given user.

  ## Example

      iex> claim_report(%Report{}, %User{})
      {:ok, %Report{}}

  """
  def claim_report(%Report{} = report, user) do
    report
    |> Report.claim_changeset(user)
    |> Repo.update()
    |> reindex_after_update()
  end

  @doc """
  Marks the report as unclaimed.

  ## Example

      iex> unclaim_report(%Report{})
      {:ok, %Report{}}

  """
  def unclaim_report(%Report{} = report) do
    report
    |> Report.unclaim_changeset()
    |> Repo.update()
    |> reindex_after_update()
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
