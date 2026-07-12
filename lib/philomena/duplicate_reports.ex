defmodule Philomena.DuplicateReports do
  @moduledoc """
  The DuplicateReports context.
  """

  import Philomena.DuplicateReports.Power
  import Ecto.Query, warn: false

  import Philomena.Authorization, only: [authorize: 3, verify_write_access: 1]

  alias Ecto.Multi
  alias Philomena.Repo
  alias Philomena.IntegerId

  alias Philomena.Attribution.Actor
  alias Philomena.DuplicateReports.DuplicateReport
  alias Philomena.DuplicateReports.SearchQuery
  alias Philomena.DuplicateReports.Uploader
  alias Philomena.ImageIntensities.ImageIntensity
  alias Philomena.Images.Image
  alias Philomena.Images
  alias Philomena.ModerationLogs
  alias Philomena.ModerationLogs.Paths
  alias Philomena.Users.User

  @valid_states ~w(open rejected accepted claimed)

  @doc """
  Returns a paginated list of duplicate reports for the report index.

  `params["states"]` selects which report states to show; a single value or a
  list is accepted, filtered against the `open`/`rejected`/`accepted`/`claimed`
  allowlist. A blank or missing selection defaults to `open` and `claimed`; a
  selection that survives the filter as an empty list matches nothing. The
  reports carry their user, modifier, and both images (with users, sources, and
  tags) preloaded, newest first.

  ## Examples

      iex> list_duplicate_reports(%{"states" => ["rejected"]}, page_size: 25)
      %Scrivener.Page{}

  """
  @spec list_duplicate_reports(map(), Scrivener.Config.t() | keyword()) :: Scrivener.Page.t()
  def list_duplicate_reports(params, pagination) do
    states =
      (presence(params["states"]) || ~w(open claimed))
      |> wrap()
      |> Enum.filter(&Enum.member?(@valid_states, &1))

    DuplicateReport
    |> where([d], d.state in ^states)
    |> preload([
      :user,
      :modifier,
      image: [:user, :sources, tags: :aliases],
      duplicate_of_image: [:user, :sources, tags: :aliases]
    ])
    |> order_by(desc: :created_at)
    |> Repo.paginate(pagination)
  end

  @doc """
  Loads the duplicate report named by `id` for its show page.

  A non-castable or out-of-range id, and a well-formed but unknown id, are both
  `{:error, :not_found}`. The report carries its reported and claimed-duplicate
  images preloaded. Any visitor may view a report; there is no authorization.

  Returns `{:ok, duplicate_report}` or `{:error, :not_found}`.

  ## Examples

      iex> show_duplicate_report("42")
      {:ok, %DuplicateReport{}}

      iex> show_duplicate_report("not-an-integer")
      {:error, :not_found}

  """
  @spec show_duplicate_report(String.t() | integer()) ::
          {:ok, DuplicateReport.t()} | {:error, :not_found}
  def show_duplicate_report(id) do
    with {:ok, report_id} <- IntegerId.parse(id),
         %DuplicateReport{} = report <-
           Repo.get(preload(DuplicateReport, [:image, :duplicate_of_image]), report_id) do
      {:ok, report}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Generates automated duplicate reports for an image based on perceptual matching.

  Takes a source image and generates duplicate reports for similar images based on
  intensity and aspect ratio comparison.

  ## Examples

      iex> generate_reports(source_image)
      [{:ok, %DuplicateReport{}}, ...]

  """
  def generate_reports(source) do
    source = Repo.preload(source, :intensity)

    {source.intensity, source.image_aspect_ratio}
    |> find_duplicates(dist: 0.2)
    |> where([i, _it], i.id != ^source.id)
    |> Repo.all()
    |> Enum.map(fn target ->
      create_duplicate_report(source, target, %{}, %{
        "reason" => "Automated Perceptual dedupe match"
      })
    end)
  end

  @doc """
  Query for potential duplicate images based on intensity values and aspect ratio.

  Takes a tuple of {intensities, aspect_ratio} and optional options to control the search:
  - `:aspect_dist` - Maximum aspect ratio difference (default: 0.05)
  - `:limit` - Maximum number of results (default: 10)
  - `:dist` - Maximum intensity difference per channel (default: 0.25)

  ## Examples

      iex> find_duplicates({%{nw: 0.5, ne: 0.5, sw: 0.5, se: 0.5}, 1.0})
      #Ecto.Query<...>

      iex> find_duplicates({intensities, ratio}, dist: 0.3, limit: 20)
      #Ecto.Query<...>

  """
  def find_duplicates({intensities, aspect_ratio}, opts \\ []) do
    aspect_dist = Keyword.get(opts, :aspect_dist, 0.05)
    limit = Keyword.get(opts, :limit, 10)
    dist = Keyword.get(opts, :dist, 0.25)

    # for each color channel
    dist = dist * 3

    from i in Image,
      inner_join: it in ImageIntensity,
      on: it.image_id == i.id,
      where: it.nw >= ^(intensities.nw - dist) and it.nw <= ^(intensities.nw + dist),
      where: it.ne >= ^(intensities.ne - dist) and it.ne <= ^(intensities.ne + dist),
      where: it.sw >= ^(intensities.sw - dist) and it.sw <= ^(intensities.sw + dist),
      where: it.se >= ^(intensities.se - dist) and it.se <= ^(intensities.se + dist),
      where:
        i.image_aspect_ratio >= ^(aspect_ratio - aspect_dist) and
          i.image_aspect_ratio <= ^(aspect_ratio + aspect_dist),
      order_by: [
        asc:
          power(it.nw - ^intensities.nw, 2) +
            power(it.ne - ^intensities.ne, 2) +
            power(it.sw - ^intensities.sw, 2) +
            power(it.se - ^intensities.se, 2) +
            power(i.image_aspect_ratio - ^aspect_ratio, 2)
      ],
      limit: ^limit
  end

  @doc """
  Executes the reverse image search query from parameters.

  ## Examples

      iex> execute_search_query(%{"image" => ..., "distance" => "0.25"})
      {:ok, [%Image{...}, ....]}

      iex> execute_search_query(%{"image" => ..., "distance" => "asdf"})
      {:error, %Ecto.Changeset{}}

  """
  def execute_search_query(attrs \\ %{}) do
    %SearchQuery{}
    |> SearchQuery.changeset(attrs)
    |> Uploader.analyze_upload(attrs)
    |> Ecto.Changeset.apply_action(:create)
    |> case do
      {:ok, search_query} ->
        intensities = generate_intensities(search_query)
        aspect = search_query.image_aspect_ratio
        limit = search_query.limit
        dist = search_query.distance

        images =
          {intensities, aspect}
          |> find_duplicates(dist: dist, aspect_dist: dist, limit: limit)
          |> preload([:user, :intensity, [:sources, tags: :aliases]])
          |> Repo.paginate(page_size: 50)

        {:ok, images}

      error ->
        error
    end
  end

  defp generate_intensities(search_query) do
    analysis = SearchQuery.to_analysis(search_query)
    file = search_query.uploaded_image

    PhilomenaMedia.Processors.intensities(analysis, file)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking search query changes.

  ## Examples

      iex> change_search_query(search_query)
      %Ecto.Changeset{source: %SearchQuery{}}

  """
  def change_search_query(%SearchQuery{} = search_query) do
    SearchQuery.changeset(search_query)
  end

  @doc """
  Lists the duplicate reports involving the image named by `image_id`, on behalf
  of `actor` (a user, or `nil` for an anonymous visitor).

  The image is loaded by id (with its sources and tags preloaded for rendering)
  and authorized for `:show`. A non-castable or out-of-range id is
  `{:error, :not_found}`. A well-formed but unknown id is authorized as a `nil`
  load: an actor who may not `:show` it gets `{:error, :unauthorized}`, while an
  actor permitted to act on the `nil` load gets `{:error, :not_found}`. Reports
  where the image is either the reported image or the claimed duplicate are
  returned, with their user, modifier, and image associations preloaded.

  Returns `{:ok, {image, duplicate_reports}}`.

  ## Examples

      iex> image_duplicate_reports(user, "42")
      {:ok, {%Image{}, [%DuplicateReport{}, ...]}}

      iex> image_duplicate_reports(user, "999999999")
      {:error, :unauthorized}

  """
  @spec image_duplicate_reports(User.t() | nil, String.t() | integer()) ::
          {:ok, {Image.t(), [DuplicateReport.t()]}} | {:error, :unauthorized | :not_found}
  def image_duplicate_reports(actor, image_id) do
    with {:ok, id} <- IntegerId.parse(image_id),
         image = Repo.get(preload(Image, [:sources, tags: :aliases]), id),
         :ok <- authorize(actor, :show, image),
         %Image{} <- image do
      dupe_reports =
        DuplicateReport
        |> preload([
          :user,
          :modifier,
          image: [:user, :sources, tags: :aliases],
          duplicate_of_image: [:user, :sources, tags: :aliases]
        ])
        |> where([d], d.image_id == ^image.id or d.duplicate_of_image_id == ^image.id)
        |> Repo.all()

      {:ok, {image, dupe_reports}}
    else
      # Non-castable id, or a `nil` load the actor was permitted to act on.
      shape when shape in [:error, nil] -> {:error, :not_found}
      {:error, :unauthorized} -> {:error, :unauthorized}
    end
  end

  @doc """
  Gets a single duplicate_report.

  Raises `Ecto.NoResultsError` if the Duplicate report does not exist.

  ## Examples

      iex> get_duplicate_report!(123)
      %DuplicateReport{}

      iex> get_duplicate_report!(456)
      ** (Ecto.NoResultsError)

  """
  def get_duplicate_report!(id), do: Repo.get!(DuplicateReport, id)

  @doc """
  Submits a duplicate report from `params["duplicate_report"]`, on behalf of
  `actor` (a `Philomena.Attribution.Actor` whose user may be `nil` for an
  anonymous visitor).

  The write is refused for a banned actor (`{:error, :ban}`) or one without a
  fingerprint (`{:error, :unauthorized}`), checked before anything else. A
  missing `duplicate_report` param, or a source `image_id` that names no image,
  has nowhere to redirect back to and is `{:error, :not_found}`. A resolvable
  source with an unresolvable `duplicate_of_image_id`, or a rejected changeset
  (such as reporting an image as a duplicate of itself), is
  `{:error, :report_failed, source}`, carrying the source image for the caller's
  redirect. On success the report is inserted with the actor's user recorded as
  the reporter.

  Returns `{:ok, duplicate_report}`, `{:error, :ban}`, `{:error, :unauthorized}`,
  `{:error, :not_found}`, or `{:error, :report_failed, source}`.

  ## Examples

      iex> create_duplicate_report(actor, %{"duplicate_report" => %{"image_id" => "1", "duplicate_of_image_id" => "2"}})
      {:ok, %DuplicateReport{}}

      iex> create_duplicate_report(actor, %{"duplicate_report" => %{"image_id" => "1", "duplicate_of_image_id" => "1"}})
      {:error, :report_failed, %Image{}}

  """
  @spec create_duplicate_report(Actor.t(), map()) ::
          {:ok, DuplicateReport.t()}
          | {:error, :ban | :unauthorized | :not_found}
          | {:error, :report_failed, Image.t()}
  def create_duplicate_report(%Actor{} = actor, params) do
    with :ok <- verify_write_access(actor) do
      submit_duplicate_report(actor, params)
    end
  end

  # A missing or malformed duplicate_report param has nowhere to redirect back to.
  defp submit_duplicate_report(actor, %{"duplicate_report" => report_params})
       when is_map(report_params) do
    source = load_image(report_params["image_id"])
    target = load_image(report_params["duplicate_of_image_id"])

    build_duplicate_report(actor, source, target, report_params)
  end

  defp submit_duplicate_report(_actor, _params), do: {:error, :not_found}

  # Without a source image there is nowhere to redirect back to.
  defp build_duplicate_report(_actor, nil, _target, _params), do: {:error, :not_found}

  defp build_duplicate_report(_actor, source, nil, _params),
    do: {:error, :report_failed, source}

  defp build_duplicate_report(actor, source, target, report_params) do
    case create_duplicate_report(source, target, actor_attributes(actor), report_params) do
      {:ok, duplicate_report} -> {:ok, duplicate_report}
      {:error, _changeset} -> {:error, :report_failed, source}
    end
  end

  defp load_image(id) do
    case IntegerId.parse(id) do
      {:ok, id} -> Repo.get(Image, id)
      :error -> nil
    end
  end

  # The user attribution the report changeset records, rebuilt from the actor.
  defp actor_attributes(%Actor{ip: ip, fingerprint: fingerprint, user: user}),
    do: [ip: ip, fingerprint: fingerprint, user: user]

  defp presence(""), do: nil
  defp presence(x), do: x

  defp wrap(list) when is_list(list), do: list
  defp wrap(not_a_list), do: [not_a_list]

  @doc """
  Creates a duplicate_report.

  ## Examples

      iex> create_duplicate_report(%{field: value})
      {:ok, %DuplicateReport{}}

      iex> create_duplicate_report(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_duplicate_report(source, target, attribution, attrs \\ %{}) do
    %DuplicateReport{image_id: source.id, duplicate_of_image_id: target.id}
    |> DuplicateReport.creation_changeset(attrs, attribution)
    |> Repo.insert()
  end

  @doc """
  Accepts the duplicate report named by `id` and merges the duplicate image into
  the target, on behalf of `actor` (the acting user).

  The report is authorized for `:edit` after being loaded by id. A non-castable
  id, and a well-formed unknown id an admin is otherwise permitted to act on, are
  `{:error, :not_found}`; an unknown id for a non-admin actor is
  `{:error, :unauthorized}`. Any other duplicate reports between the same two
  images are rejected, the images are merged, and a moderation log is written on
  success. A merge that cannot complete (such as a report already accepted by
  someone else) is `{:error, :report_failed}`.

  Returns `{:ok, results}` (the transaction result map), `{:error, :not_found}`,
  `{:error, :unauthorized}`, or `{:error, :report_failed}`.

  ## Examples

      iex> accept_duplicate_report(moderator, "42")
      {:ok, %{duplicate_report: %DuplicateReport{}, ...}}

  """
  @spec accept_duplicate_report(User.t() | nil, String.t() | integer()) ::
          {:ok, map()} | {:error, :not_found | :unauthorized | :report_failed}
  def accept_duplicate_report(actor, id) do
    with {:ok, report_id} <- IntegerId.parse(id),
         report = Repo.get(preload(DuplicateReport, [:image, :duplicate_of_image]), report_id),
         :ok <- authorize(actor, :edit, report),
         %DuplicateReport{} <- report,
         {:ok, results} <- accept_report_multi(report, actor) do
      report = results.duplicate_report

      ModerationLogs.create_moderation_log(
        actor,
        "DuplicateReport.Accept:create",
        Paths.image_path(report.image),
        "Accepted duplicate report, merged #{report.image.id} into #{report.duplicate_of_image.id}"
      )

      {:ok, results}
    else
      shape when shape in [:error, nil] -> {:error, :not_found}
      {:error, :unauthorized} -> {:error, :unauthorized}
      _ -> {:error, :report_failed}
    end
  end

  @doc """
  Merges the duplicate image of `duplicate_report` into its target image.

  Takes an optional `Ecto.Multi`, the duplicate report to accept, and the user
  accepting the report. Rejects any other duplicate reports between the same two
  images and merges the images. Runs the transaction unless composed into a
  larger multi.

  ## Examples

      iex> accept_report_multi(nil, duplicate_report, user)
      {:ok, %{duplicate_report: %DuplicateReport{}, ...}}

      iex> accept_report_multi(existing_multi, duplicate_report, user)
      %Ecto.Multi{}

  """
  def accept_report_multi(multi \\ nil, %DuplicateReport{} = duplicate_report, user) do
    duplicate_report = Repo.preload(duplicate_report, [:image, :duplicate_of_image])

    other_duplicate_reports =
      DuplicateReport
      |> where(
        [dr],
        (dr.image_id == ^duplicate_report.image_id and
           dr.duplicate_of_image_id == ^duplicate_report.duplicate_of_image_id) or
          (dr.image_id == ^duplicate_report.duplicate_of_image_id and
             dr.duplicate_of_image_id == ^duplicate_report.image_id)
      )
      |> where([dr], dr.id != ^duplicate_report.id)
      |> update(set: [state: "rejected"])

    changeset = DuplicateReport.accept_changeset(duplicate_report, user)

    multi = multi || Multi.new()

    multi
    |> Multi.update(:duplicate_report, changeset)
    |> Multi.update_all(:other_reports, other_duplicate_reports, [])
    |> Images.merge_image(duplicate_report.image, duplicate_report.duplicate_of_image, user)
  end

  @doc """
  Accepts the duplicate report named by `id` in reverse, making the reported
  image the duplicate of the target instead, on behalf of `actor` (the acting
  user).

  The report is authorized for `:edit` after being loaded by id, with the same
  not-found/unauthorized shapes as `accept_duplicate_report/2`. The original
  report is rejected, the images are merged the other way, and a moderation log
  is written on success. A merge that cannot complete is
  `{:error, :report_failed}`.

  Returns `{:ok, results}` (the transaction result map), `{:error, :not_found}`,
  `{:error, :unauthorized}`, or `{:error, :report_failed}`.

  ## Examples

      iex> accept_reverse_duplicate_report(moderator, "42")
      {:ok, %{duplicate_report: %DuplicateReport{}, ...}}

  """
  @spec accept_reverse_duplicate_report(User.t() | nil, String.t() | integer()) ::
          {:ok, map()} | {:error, :not_found | :unauthorized | :report_failed}
  def accept_reverse_duplicate_report(actor, id) do
    with {:ok, report_id} <- IntegerId.parse(id),
         report = Repo.get(preload(DuplicateReport, [:image, :duplicate_of_image]), report_id),
         :ok <- authorize(actor, :edit, report),
         %DuplicateReport{} <- report,
         {:ok, results} <- accept_reverse_report_multi(report, actor) do
      report = results.duplicate_report

      ModerationLogs.create_moderation_log(
        actor,
        "DuplicateReport.AcceptReverse:create",
        Paths.image_path(report.image),
        "Reverse-accepted duplicate report, merged #{report.image.id} into #{report.duplicate_of_image.id}"
      )

      {:ok, results}
    else
      shape when shape in [:error, nil] -> {:error, :not_found}
      {:error, :unauthorized} -> {:error, :unauthorized}
      _ -> {:error, :report_failed}
    end
  end

  @doc """
  Merges the target of `duplicate_report` into its reported image.

  Creates a duplicate report with the reversed image relationship if one does not
  already exist, rejects the original report, and accepts the reversed report,
  running the transaction.

  ## Examples

      iex> accept_reverse_report_multi(duplicate_report, user)
      {:ok, %{duplicate_report: %DuplicateReport{}, ...}}

  """
  def accept_reverse_report_multi(%DuplicateReport{} = duplicate_report, user) do
    new_report =
      DuplicateReport
      |> where(duplicate_of_image_id: ^duplicate_report.image_id)
      |> where(image_id: ^duplicate_report.duplicate_of_image_id)
      |> limit(1)
      |> Repo.one()

    new_report =
      if new_report do
        new_report
      else
        %DuplicateReport{
          image_id: duplicate_report.duplicate_of_image_id,
          duplicate_of_image_id: duplicate_report.image_id,
          reason: Enum.join([duplicate_report.reason, "(Reverse accepted)"], "\n"),
          user_id: user.id
        }
        |> DuplicateReport.changeset(%{})
        |> Repo.insert!()
      end

    Multi.new()
    |> Multi.run(:reject_duplicate_report, fn _, %{} ->
      reject_report(duplicate_report, user)
    end)
    |> accept_report_multi(new_report, user)
  end

  @doc """
  Claims the duplicate report named by `id` for review, on behalf of `actor`
  (the acting user).

  The report is authorized for `:edit` after being loaded by id, with the same
  not-found/unauthorized shapes as `accept_duplicate_report/2`. The report is
  marked claimed by the actor and a moderation log is written on success.

  Returns `{:ok, duplicate_report}`, `{:error, :not_found}`, or
  `{:error, :unauthorized}`.

  ## Examples

      iex> claim_duplicate_report(moderator, "42")
      {:ok, %DuplicateReport{}}

  """
  @spec claim_duplicate_report(User.t() | nil, String.t() | integer()) ::
          {:ok, DuplicateReport.t()} | {:error, :not_found | :unauthorized}
  def claim_duplicate_report(actor, id) do
    with {:ok, report_id} <- IntegerId.parse(id),
         report = Repo.get(DuplicateReport, report_id),
         :ok <- authorize(actor, :edit, report),
         %DuplicateReport{} <- report do
      {:ok, report} = Repo.update(DuplicateReport.claim_changeset(report, actor))

      ModerationLogs.create_moderation_log(
        actor,
        "DuplicateReport.Claim:create",
        "/duplicate_reports",
        "Claimed a duplicate report"
      )

      {:ok, report}
    else
      shape when shape in [:error, nil] -> {:error, :not_found}
      {:error, :unauthorized} -> {:error, :unauthorized}
    end
  end

  @doc """
  Removes the claim on the duplicate report named by `id`, on behalf of `actor`
  (the acting user).

  The report is authorized for `:edit` after being loaded by id, with the same
  not-found/unauthorized shapes as `claim_duplicate_report/2`. The report is
  returned to the open, unclaimed state and a moderation log is written on
  success.

  Returns `{:ok, duplicate_report}`, `{:error, :not_found}`, or
  `{:error, :unauthorized}`.

  ## Examples

      iex> unclaim_duplicate_report(moderator, "42")
      {:ok, %DuplicateReport{}}

  """
  @spec unclaim_duplicate_report(User.t() | nil, String.t() | integer()) ::
          {:ok, DuplicateReport.t()} | {:error, :not_found | :unauthorized}
  def unclaim_duplicate_report(actor, id) do
    with {:ok, report_id} <- IntegerId.parse(id),
         report = Repo.get(DuplicateReport, report_id),
         :ok <- authorize(actor, :edit, report),
         %DuplicateReport{} <- report do
      {:ok, report} = Repo.update(DuplicateReport.unclaim_changeset(report))

      ModerationLogs.create_moderation_log(
        actor,
        "DuplicateReport.Claim:delete",
        "/duplicate_reports",
        "Released a duplicate report"
      )

      {:ok, report}
    else
      shape when shape in [:error, nil] -> {:error, :not_found}
      {:error, :unauthorized} -> {:error, :unauthorized}
    end
  end

  @doc """
  Rejects the duplicate report named by `id`, on behalf of `actor` (the acting
  user).

  The report is authorized for `:edit` after being loaded by id (with its images
  preloaded for the log), with the same not-found/unauthorized shapes as
  `accept_duplicate_report/2`. The report is marked rejected by the actor and a
  moderation log is written on success.

  Returns `{:ok, duplicate_report}`, `{:error, :not_found}`, or
  `{:error, :unauthorized}`.

  ## Examples

      iex> reject_duplicate_report(moderator, "42")
      {:ok, %DuplicateReport{}}

  """
  @spec reject_duplicate_report(User.t() | nil, String.t() | integer()) ::
          {:ok, DuplicateReport.t()} | {:error, :not_found | :unauthorized}
  def reject_duplicate_report(actor, id) do
    with {:ok, report_id} <- IntegerId.parse(id),
         report = Repo.get(preload(DuplicateReport, [:image, :duplicate_of_image]), report_id),
         :ok <- authorize(actor, :edit, report),
         %DuplicateReport{} <- report do
      {:ok, report} = reject_report(report, actor)

      ModerationLogs.create_moderation_log(
        actor,
        "DuplicateReport.Reject:create",
        "/duplicate_reports",
        "Rejected duplicate report (#{report.image.id} -> #{report.duplicate_of_image.id})"
      )

      {:ok, report}
    else
      shape when shape in [:error, nil] -> {:error, :not_found}
      {:error, :unauthorized} -> {:error, :unauthorized}
    end
  end

  defp reject_report(%DuplicateReport{} = duplicate_report, user) do
    duplicate_report
    |> DuplicateReport.reject_changeset(user)
    |> Repo.update()
  end

  @doc """
  Deletes a DuplicateReport.

  ## Examples

      iex> delete_duplicate_report(duplicate_report)
      {:ok, %DuplicateReport{}}

      iex> delete_duplicate_report(duplicate_report)
      {:error, %Ecto.Changeset{}}

  """
  def delete_duplicate_report(%DuplicateReport{} = duplicate_report) do
    Repo.delete(duplicate_report)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking duplicate_report changes.

  ## Examples

      iex> change_duplicate_report(duplicate_report)
      %Ecto.Changeset{source: %DuplicateReport{}}

  """
  def change_duplicate_report(%DuplicateReport{} = duplicate_report) do
    DuplicateReport.changeset(duplicate_report, %{})
  end

  @doc """
  Counts the number of duplicate reports in "open" state,
  if the user has permission to view them.

  ## Examples

      iex> count_duplicate_reports(admin)
      42

      iex> count_duplicate_reports(user)
      nil

  """
  def count_duplicate_reports(user) do
    if Canada.Can.can?(user, :index, DuplicateReport) do
      DuplicateReport
      |> where(state: "open")
      |> Repo.aggregate(:count, :id)
    else
      nil
    end
  end
end
