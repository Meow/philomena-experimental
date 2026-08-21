defmodule Philomena.DuplicateReports do
  @moduledoc """
  Duplicate-report submission, staff review, perceptual matching, and reverse
  image search.
  """

  import Ecto.Query, warn: false
  import Philomena.DuplicateReports.Power

  import Philomena.Authorization,
    only: [authorize: 3, verify_write_access: 1]

  alias Philomena.Attribution.Actor
  alias Philomena.DuplicateReports.DuplicateReport
  alias Philomena.DuplicateReports.SearchQuery
  alias Philomena.DuplicateReports.SearchResult
  alias Philomena.DuplicateReports.Uploader
  alias Philomena.ImageIntensities.ImageIntensity
  alias Philomena.Images
  alias Philomena.Images.Image
  alias Philomena.Loader
  alias Philomena.ModerationLogs
  alias Philomena.ModerationLogs.Paths
  alias Philomena.Multi
  alias Philomena.Repo

  @valid_states ~w(open rejected accepted claimed)
  @report_preloads [
    :user,
    :modifier,
    image: [:user, :sources, tags: :aliases],
    duplicate_of_image: [:user, :sources, tags: :aliases]
  ]
  @merge_image_preloads [:user, :intensity, :sources, tags: :aliases]

  defp load_report(%Actor{} = actor, action, report_id) do
    with {:ok, report} <-
           Loader.fetch_and_authorize(
             DuplicateReport,
             actor,
             action,
             report_id,
             @report_preloads
           ),
         :ok <- authorize_report_images(actor, report) do
      {:ok, report}
    end
  end

  defp authorize_report_images(%Actor{} = actor, %DuplicateReport{} = report) do
    with :ok <- authorize(actor, :show, report.image) do
      authorize(actor, :show, report.duplicate_of_image)
    end
  end

  defp reports_for_image(%Actor{} = actor, %Image{} = image) do
    DuplicateReport
    |> where([report], report.image_id == ^image.id or report.duplicate_of_image_id == ^image.id)
    |> preload(^@report_preloads)
    |> order_by(desc: :created_at, desc: :id)
    |> Repo.all()
    |> Enum.filter(&(authorize_report_images(actor, &1) == :ok))
  end

  defp report_states(params) do
    params
    |> Map.get("states")
    |> presence()
    |> Kernel.||(~w(open claimed))
    |> wrap()
    |> Enum.filter(&(&1 in @valid_states))
  end

  defp presence(""), do: nil
  defp presence(value), do: value

  defp wrap(values) when is_list(values), do: values
  defp wrap(value), do: [value]

  defp create_report(source, target, user, attrs) do
    %DuplicateReport{
      image_id: source.id,
      image: source,
      duplicate_of_image_id: target.id,
      duplicate_of_image: target
    }
    |> DuplicateReport.creation_changeset(attrs, user)
    |> Repo.insert()
  end

  defp duplicate_query({intensities, aspect_ratio}, opts) do
    aspect_dist = Keyword.get(opts, :aspect_dist, 0.05)
    limit = Keyword.get(opts, :limit, 10)
    dist = Keyword.get(opts, :dist, 0.25) * 3

    from image in Image,
      inner_join: intensity in ImageIntensity,
      on: intensity.image_id == image.id,
      where:
        intensity.nw >= ^(intensities.nw - dist) and
          intensity.nw <= ^(intensities.nw + dist),
      where:
        intensity.ne >= ^(intensities.ne - dist) and
          intensity.ne <= ^(intensities.ne + dist),
      where:
        intensity.sw >= ^(intensities.sw - dist) and
          intensity.sw <= ^(intensities.sw + dist),
      where:
        intensity.se >= ^(intensities.se - dist) and
          intensity.se <= ^(intensities.se + dist),
      where:
        image.image_aspect_ratio >= ^(aspect_ratio - aspect_dist) and
          image.image_aspect_ratio <= ^(aspect_ratio + aspect_dist),
      order_by: [
        asc:
          power(intensity.nw - ^intensities.nw, 2) +
            power(intensity.ne - ^intensities.ne, 2) +
            power(intensity.sw - ^intensities.sw, 2) +
            power(intensity.se - ^intensities.se, 2) +
            power(image.image_aspect_ratio - ^aspect_ratio, 2),
        asc: image.id
      ],
      limit: ^limit
  end

  defp apply_search_visibility(query, %Actor{} = actor) do
    hidden_image = %Image{hidden_from_users: true}

    case authorize(actor, :show, hidden_image) do
      :ok -> query
      {:error, :unauthorized} -> where(query, [image], image.hidden_from_users == false)
    end
  end

  defp generate_intensities(%SearchQuery{} = search_query) do
    analysis = SearchQuery.to_analysis(search_query)
    PhilomenaMedia.Processors.intensities(analysis, search_query.uploaded_image)
  end

  defp put_lock_report_pair(
         %Multi{} = multi,
         %Actor{} = actor,
         action,
         %DuplicateReport{} = loaded_report
       ) do
    source_id = loaded_report.image_id
    target_id = loaded_report.duplicate_of_image_id

    multi
    |> Multi.run(:locked_reports, fn repo, _changes ->
      lock_report_pair(repo, actor, action, loaded_report, source_id, target_id)
    end)
    |> Multi.run(:locked_images, fn repo, %{locked_reports: locked_reports} ->
      lock_report_images(repo, actor, locked_reports.report)
    end)
  end

  defp lock_report_pair(repo, actor, action, loaded_report, source_id, target_id) do
    reports =
      DuplicateReport
      |> where(
        [report],
        (report.image_id == ^source_id and report.duplicate_of_image_id == ^target_id) or
          (report.image_id == ^target_id and report.duplicate_of_image_id == ^source_id)
      )
      |> order_by(asc: :id)
      |> lock("FOR UPDATE")
      |> repo.all()

    with %DuplicateReport{image_id: ^source_id, duplicate_of_image_id: ^target_id} = report <-
           Enum.find(reports, &(&1.id == loaded_report.id)),
         :ok <- authorize(actor, action, report) do
      {:ok, %{report: report, reports: reports}}
    else
      {:error, :unauthorized} -> {:error, :unauthorized}
      _other -> {:error, :not_found}
    end
  end

  defp lock_report_images(repo, actor, report) do
    images =
      Image
      |> where([image], image.id in [^report.image_id, ^report.duplicate_of_image_id])
      |> order_by(asc: :id)
      |> preload(^@merge_image_preloads)
      |> lock("FOR UPDATE")
      |> repo.all()

    source = Enum.find(images, &(&1.id == report.image_id))
    target = Enum.find(images, &(&1.id == report.duplicate_of_image_id))

    with %Image{} <- source,
         %Image{} <- target,
         true <- source.id != target.id,
         :ok <- authorize(actor, :show, source),
         :ok <- authorize(actor, :show, target) do
      {:ok, %{source: source, target: target}}
    else
      {:error, :unauthorized} -> {:error, :unauthorized}
      _other -> {:error, :not_found}
    end
  end

  defp active_other_reports(%{report: report, reports: reports}, excluded_ids \\ []) do
    ids =
      reports
      |> Enum.reject(&(&1.id in [report.id | excluded_ids]))
      |> Enum.filter(&(&1.state in ["open", "claimed"]))
      |> Enum.map(& &1.id)

    DuplicateReport
    |> where([other], other.id in ^ids)
    |> update(set: [state: "rejected"])
  end

  defp map_transition_result(result) do
    case result do
      {:ok, changes} ->
        {:ok, changes}

      {:error, _step, %Ecto.Changeset{} = changeset, _changes} ->
        {:error, changeset}

      {:error, _step, reason, _changes} when reason in [:not_found, :unauthorized] ->
        {:error, reason}

      _error ->
        {:error, :report_failed}
    end
  end

  defp persist_accept(%Actor{user: user} = actor, report) do
    Multi.new()
    |> put_lock_report_pair(actor, :accept, report)
    |> Multi.merge(fn %{
                        locked_reports: locked_reports,
                        locked_images: %{source: source, target: target}
                      } ->
      Multi.new()
      |> Multi.update(
        :duplicate_report,
        DuplicateReport.accept_changeset(locked_reports.report, user)
      )
      |> Multi.update_all(:other_reports, active_other_reports(locked_reports), [])
      |> ModerationLogs.put_log(
        :moderation_log,
        actor,
        fn _changes ->
          {
            "DuplicateReport.Accept:create",
            Paths.image_path(source),
            "Accepted duplicate report, merged #{source.id} into #{target.id}"
          }
        end
      )
      |> Images.put_merge_image(source, target, user)
    end)
    |> Multi.transact()
    |> map_transition_result()
  end

  defp reverse_report_changeset(nil, report, user) do
    %DuplicateReport{
      image_id: report.duplicate_of_image_id,
      duplicate_of_image_id: report.image_id,
      state: "accepted",
      modifier_id: user.id
    }
    |> DuplicateReport.creation_changeset(
      %{"reason" => Enum.join([report.reason, "(Reverse accepted)"], "\n")},
      user
    )
  end

  defp reverse_report_changeset(report, _original_report, user) do
    DuplicateReport.accept_changeset(report, user)
  end

  defp persist_reverse_accept(%Actor{user: user} = actor, report) do
    Multi.new()
    |> put_lock_report_pair(actor, :accept_reverse, report)
    |> Multi.merge(fn %{
                        locked_reports:
                          %{report: original_report, reports: reports} = locked_reports,
                        locked_images: %{source: original_source, target: original_target}
                      } ->
      reverse_report =
        Enum.find(reports, fn candidate ->
          candidate.id != original_report.id and
            candidate.image_id == original_report.duplicate_of_image_id and
            candidate.duplicate_of_image_id == original_report.image_id
        end)

      excluded_ids = if reverse_report, do: [reverse_report.id], else: []

      Multi.new()
      |> Multi.update(
        :original_report,
        DuplicateReport.reject_changeset(original_report, user)
      )
      |> Multi.insert_or_update(
        :duplicate_report,
        reverse_report_changeset(reverse_report, original_report, user)
      )
      |> Multi.update_all(
        :other_reports,
        active_other_reports(locked_reports, excluded_ids),
        []
      )
      |> ModerationLogs.put_log(
        :moderation_log,
        actor,
        fn _changes ->
          {
            "DuplicateReport.AcceptReverse:create",
            Paths.image_path(original_target),
            "Reverse-accepted duplicate report, merged #{original_target.id} into #{original_source.id}"
          }
        end
      )
      |> Images.put_merge_image(original_target, original_source, user)
    end)
    |> Multi.transact()
    |> map_transition_result()
  end

  defp persist_report_transition(%Actor{user: user} = actor, report, action, changeset, log) do
    Multi.new()
    |> Multi.lock_one(:locked_report, where(DuplicateReport, id: ^report.id))
    |> Multi.run(:authorize, fn _repo, %{locked_report: locked_report} ->
      case authorize(actor, action, locked_report) do
        :ok -> {:ok, nil}
        {:error, reason} -> {:error, reason}
      end
    end)
    |> Multi.update(:duplicate_report, fn %{locked_report: locked_report} ->
      changeset.(locked_report, user)
    end)
    |> ModerationLogs.put_log(:moderation_log, actor, log)
    |> Multi.transact()
    |> map_transition_result()
    |> case do
      {:ok, %{duplicate_report: duplicate_report}} -> {:ok, duplicate_report}
      error -> error
    end
  end

  @doc """
  Loads the staff duplicate-report index described by `params`.

  Access is authorized with `:index` before the state-filtered query runs.
  Blank or omitted states select open and claimed reports; unknown states are
  discarded, so a wholly invalid selection returns an empty page.

  ## Examples

      iex> load_duplicate_report_index(moderator, %{"states" => ["rejected"]}, pagination)
      {:ok, %Scrivener.Page{}}

      iex> load_duplicate_report_index(user, %{}, pagination)
      {:error, :unauthorized}

  """
  @spec load_duplicate_report_index(Actor.t(), map(), Repo.pagination_params()) ::
          {:ok, Scrivener.Page.t(DuplicateReport.t())} | {:error, :unauthorized}
  def load_duplicate_report_index(%Actor{} = actor, params, pagination) do
    with :ok <- authorize(actor, :index, DuplicateReport) do
      reports =
        DuplicateReport
        |> where([report], report.state in ^report_states(params))
        |> preload(^@report_preloads)
        |> order_by(desc: :created_at, desc: :id)
        |> Repo.paginate(pagination)

      {:ok, reports}
    end
  end

  @doc """
  Loads one duplicate report for display.

  The report is authorized with `:show`, then both associated images must also
  be visible to the actor. Missing and malformed IDs are always not-found.

  ## Examples

      iex> load_duplicate_report(actor, "42")
      {:ok, %DuplicateReport{}}

      iex> load_duplicate_report(actor, "not-an-id")
      {:error, :not_found}

  """
  @spec load_duplicate_report(Actor.t(), Loader.integer_id()) ::
          {:ok, DuplicateReport.t()} | {:error, :not_found | :unauthorized}
  def load_duplicate_report(%Actor{} = actor, report_id) do
    load_report(actor, :show, report_id)
  end

  @doc """
  Prepares the duplicate-report form for one visible image.

  The form uses the same write-access and `:create` prerequisites as submission.
  Existing reports are included only when both of their images are visible to
  the actor.

  ## Examples

      iex> new_duplicate_report(actor, "42")
      {:ok, {%Image{}, [%DuplicateReport{}], %Ecto.Changeset{}}}

      iex> new_duplicate_report(banned_actor, "42")
      {:error, :ban}

  """
  @spec new_duplicate_report(Actor.t(), Loader.integer_id()) ::
          {:ok, {Image.t(), [DuplicateReport.t()], Ecto.Changeset.t()}}
          | {:error, :ban | :not_found | :unauthorized}
  def new_duplicate_report(%Actor{} = actor, image_id) do
    with :ok <- verify_write_access(actor),
         :ok <- authorize(actor, :create, DuplicateReport),
         {:ok, image} <- Images.load_report_target(actor, image_id) do
      changeset =
        %DuplicateReport{image_id: image.id, image: image}
        |> DuplicateReport.creation_changeset(%{}, actor.user)

      {:ok, {image, reports_for_image(actor, image), changeset}}
    end
  end

  @doc """
  Creates a duplicate report between two actor-visible images.

  Write access and the class `:create` ability are checked before either image
  is loaded. The locators are parsed independently; malformed, missing, or
  forbidden images return the shared loader errors. Validation failures return
  the report changeset with both images attached.

  ## Examples

      iex> create_duplicate_report(actor, "1", "2", %{"reason" => "same image"})
      {:ok, %DuplicateReport{}}

      iex> create_duplicate_report(actor, "1", "1", %{})
      {:error, %Ecto.Changeset{}}

  """
  @spec create_duplicate_report(
          Actor.t(),
          Loader.integer_id(),
          Loader.integer_id(),
          map()
        ) ::
          {:ok, DuplicateReport.t()}
          | {:error, :ban | :not_found | :unauthorized | Ecto.Changeset.t()}
  def create_duplicate_report(%Actor{} = actor, source_id, target_id, attrs) do
    with :ok <- verify_write_access(actor),
         :ok <- authorize(actor, :create, DuplicateReport),
         {:ok, source} <- Images.load_report_target(actor, source_id),
         {:ok, target} <- Images.load_report_target(actor, target_id) do
      create_report(source, target, actor.user, attrs)
    end
  end

  @doc """
  Generates automated duplicate reports for one media-pipeline image.

  Up to ten visible perceptual matches are considered. Each insert is
  independent and the per-target insert results are returned to the worker.

  ## Examples

      iex> generate_reports(source_image)
      [{:ok, %DuplicateReport{}}, ...]

  """
  @spec generate_reports(Image.t()) ::
          [{:ok, DuplicateReport.t()} | {:error, Ecto.Changeset.t()}]
  def generate_reports(%Image{} = source) do
    source = Repo.preload(source, :intensity)

    {source.intensity, source.image_aspect_ratio}
    |> duplicate_query(dist: 0.2)
    |> where([image], image.id != ^source.id and image.hidden_from_users == false)
    |> Repo.all()
    |> Enum.map(
      &create_report(source, &1, nil, %{
        "reason" => "Automated Perceptual dedupe match"
      })
    )
  end

  @doc """
  Prepares an empty reverse-image-search result for the actor.

  ## Examples

      iex> new_reverse_search(actor)
      {:ok, %SearchResult{images: nil}}

  """
  @spec new_reverse_search(Actor.t()) ::
          {:ok, SearchResult.t()} | {:error, :unauthorized}
  def new_reverse_search(%Actor{} = actor) do
    with :ok <- authorize(actor, :search, DuplicateReport) do
      {:ok,
       %SearchResult{
         images: nil,
         changeset: SearchQuery.changeset(%SearchQuery{})
       }}
    end
  end

  @doc """
  Runs a reverse image search for the uploaded image in `attrs`.

  The upload metadata, distance, and limit are validated before media analysis.
  Results exclude hidden images unless the actor may view them, and carry the
  normalized search changeset alongside the page. Invalid input returns the
  rejected changeset explicitly.

  ## Examples

      iex> search_duplicates(actor, %{"image" => upload, "distance" => "0.25"})
      {:ok, %SearchResult{images: %Scrivener.Page{}}}

      iex> search_duplicates(actor, %{"image" => upload, "distance" => "bad"})
      {:error, %Ecto.Changeset{}}

  """
  @spec search_duplicates(Actor.t(), map()) ::
          {:ok, SearchResult.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def search_duplicates(%Actor{} = actor, attrs) do
    with :ok <- authorize(actor, :search, DuplicateReport),
         {:ok, search_query} <-
           %SearchQuery{}
           |> SearchQuery.changeset(attrs)
           |> Uploader.analyze_upload(attrs)
           |> Ecto.Changeset.apply_action(:create) do
      intensities = generate_intensities(search_query)

      images =
        {intensities, search_query.image_aspect_ratio}
        |> duplicate_query(
          dist: search_query.distance,
          aspect_dist: search_query.distance,
          limit: search_query.limit
        )
        |> apply_search_visibility(actor)
        |> preload([:user, :intensity, :sources, tags: :aliases])
        |> Repo.paginate(page_size: 50)

      {:ok,
       %SearchResult{
         images: images,
         changeset: SearchQuery.changeset(search_query)
       }}
    end
  end

  @doc """
  Accepts a duplicate report and merges its source image into its target.

  Write access, the distinct `:accept` ability, the report direction, and both
  images are checked before row-locked state is changed. The report, competing
  active reports, image merge, and moderation log commit atomically. Merge
  indexing, notifications, thumbnails, and broadcasts run after commit.

  ## Examples

      iex> accept_duplicate_report(moderator, "42")
      {:ok, %{duplicate_report: %DuplicateReport{}, image: %Image{}}}

      iex> accept_duplicate_report(user, "42")
      {:error, :unauthorized}

  """
  @spec accept_duplicate_report(Actor.t(), Loader.integer_id()) ::
          {:ok, map()}
          | {:error, :ban | :not_found | :unauthorized | :report_failed | Ecto.Changeset.t()}
  def accept_duplicate_report(%Actor{} = actor, report_id) do
    with :ok <- verify_write_access(actor),
         {:ok, report} <- load_report(actor, :accept, report_id) do
      persist_accept(actor, report)
    end
  end

  @doc """
  Accepts a duplicate report in reverse and merges its target into its source.

  The original report is rejected and a locked reverse-direction report is
  inserted or accepted in the same transaction as the image merge and audit
  log. Authorization and post-commit behavior match `accept_duplicate_report/2`.

  ## Examples

      iex> accept_reverse_duplicate_report(moderator, "42")
      {:ok, %{duplicate_report: %DuplicateReport{}, image: %Image{}}}

  """
  @spec accept_reverse_duplicate_report(Actor.t(), Loader.integer_id()) ::
          {:ok, map()}
          | {:error, :ban | :not_found | :unauthorized | :report_failed | Ecto.Changeset.t()}
  def accept_reverse_duplicate_report(%Actor{} = actor, report_id) do
    with :ok <- verify_write_access(actor),
         {:ok, report} <- load_report(actor, :accept_reverse, report_id) do
      persist_reverse_accept(actor, report)
    end
  end

  @doc """
  Claims one open, unclaimed duplicate report for the acting staff member.

  The report is reloaded under a row lock and authorized with `:claim`. A
  repeated or racing claim returns a changeset; the audit log commits with the
  state change.

  ## Examples

      iex> claim_duplicate_report(moderator, "42")
      {:ok, %DuplicateReport{state: "claimed"}}

  """
  @spec claim_duplicate_report(Actor.t(), Loader.integer_id()) ::
          {:ok, DuplicateReport.t()}
          | {:error, :ban | :not_found | :unauthorized | :report_failed | Ecto.Changeset.t()}
  def claim_duplicate_report(%Actor{} = actor, report_id) do
    with :ok <- verify_write_access(actor),
         {:ok, report} <- load_report(actor, :claim, report_id) do
      persist_report_transition(
        actor,
        report,
        :claim,
        &DuplicateReport.claim_changeset/2,
        fn _changes ->
          {"DuplicateReport.Claim:create", "/duplicate_reports", "Claimed a duplicate report"}
        end
      )
    end
  end

  @doc """
  Releases one claimed duplicate report.

  The locked report is authorized with `:unclaim`. An already-open or otherwise
  non-claimed report returns a changeset and does not write an audit log.

  ## Examples

      iex> unclaim_duplicate_report(moderator, "42")
      {:ok, %DuplicateReport{state: "open"}}

  """
  @spec unclaim_duplicate_report(Actor.t(), Loader.integer_id()) ::
          {:ok, DuplicateReport.t()}
          | {:error, :ban | :not_found | :unauthorized | :report_failed | Ecto.Changeset.t()}
  def unclaim_duplicate_report(%Actor{} = actor, report_id) do
    with :ok <- verify_write_access(actor),
         {:ok, report} <- load_report(actor, :unclaim, report_id) do
      persist_report_transition(
        actor,
        report,
        :unclaim,
        fn locked_report, _user -> DuplicateReport.unclaim_changeset(locked_report) end,
        fn _changes ->
          {"DuplicateReport.Claim:delete", "/duplicate_reports", "Released a duplicate report"}
        end
      )
    end
  end

  @doc """
  Rejects one active duplicate report.

  The locked report is authorized with `:reject`; its state change and the
  direction-bearing moderation log commit atomically.

  ## Examples

      iex> reject_duplicate_report(moderator, "42")
      {:ok, %DuplicateReport{state: "rejected"}}

  """
  @spec reject_duplicate_report(Actor.t(), Loader.integer_id()) ::
          {:ok, DuplicateReport.t()}
          | {:error, :ban | :not_found | :unauthorized | :report_failed | Ecto.Changeset.t()}
  def reject_duplicate_report(%Actor{} = actor, report_id) do
    with :ok <- verify_write_access(actor),
         {:ok, report} <- load_report(actor, :reject, report_id) do
      persist_report_transition(
        actor,
        report,
        :reject,
        &DuplicateReport.reject_changeset/2,
        fn %{duplicate_report: rejected_report} ->
          {
            "DuplicateReport.Reject:create",
            "/duplicate_reports",
            "Rejected duplicate report (#{rejected_report.image_id} -> #{rejected_report.duplicate_of_image_id})"
          }
        end
      )
    end
  end

  @doc """
  Counts open duplicate reports for the staff navigation counter.

  The count is authorized with `:index`; unauthorized actors receive `nil`.

  ## Examples

      iex> count_duplicate_reports(moderator)
      4

      iex> count_duplicate_reports(user)
      nil

  """
  @spec count_duplicate_reports(Actor.t()) :: non_neg_integer() | nil
  def count_duplicate_reports(%Actor{} = actor) do
    case authorize(actor, :index, DuplicateReport) do
      :ok -> DuplicateReport |> where(state: "open") |> Repo.aggregate(:count, :id)
      {:error, :unauthorized} -> nil
    end
  end
end
