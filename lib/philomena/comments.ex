defmodule Philomena.Comments do
  @moduledoc """
  The Comments context.
  """

  import Ecto.Query, warn: false

  import Philomena.Authorization,
    only: [authorize: 3, verify_write_access: 1, verify_not_banned: 1]

  alias Ecto.Multi
  alias Philomena.Repo
  alias Philomena.RateLimiter
  alias Philomena.Attribution.Actor

  @comment_create_window 15

  alias PhilomenaQuery.Search
  alias Philomena.IntegerId
  alias Philomena.ModerationLogs
  alias Philomena.ModerationLogs.Paths
  alias Philomena.UserStatistics
  alias Philomena.Users.User
  alias Philomena.Filters.Filter
  alias Philomena.Comments.Comment
  alias Philomena.Comments.Query
  alias Philomena.Comments
  alias Philomena.IndexWorker
  alias Philomena.Images.Image
  alias Philomena.Images
  alias Philomena.Tags.Tag
  alias Philomena.Notifications
  alias Philomena.Versions
  alias Philomena.Versions.Version
  alias Philomena.Reports
  alias Philomena.Reports.Report

  @doc """
  Gets a single comment.

  Raises `Ecto.NoResultsError` if the Comment does not exist.

  ## Examples

      iex> get_comment!(123)
      %Comment{}

      iex> get_comment!(456)
      ** (Ecto.NoResultsError)

  """
  def get_comment!(id), do: Repo.get!(Comment, id)

  @doc """
  Loads the comment named by `id`, with its image and author preloaded.

  A comment that does not exist, or whose content has been destroyed, is
  `{:error, :not_found}`. A comment whose image is hidden from users is
  `{:error, :hidden_image}`. Otherwise the comment is returned, including comments
  hidden from users.

  Returns `{:ok, comment}`, `{:error, :not_found}`, or `{:error, :hidden_image}`.

  ## Examples

      iex> load_comment("1")
      {:ok, %Comment{}}

      iex> load_comment("999999999")
      {:error, :not_found}

  """
  @spec load_comment(any()) ::
          {:ok, Comment.t()} | {:error, :not_found} | {:error, :hidden_image}
  def load_comment(id) do
    # The id is interpolated without casting, so a non-integer id raises
    # Ecto.Query.CastError.
    comment =
      Comment
      |> where(id: ^id)
      |> preload([:image, :user])
      |> Repo.one()

    cond do
      is_nil(comment) or comment.destroyed_content ->
        {:error, :not_found}

      comment.image.hidden_from_users ->
        {:error, :hidden_image}

      true ->
        {:ok, comment}
    end
  end

  @doc """
  Loads the edit history of the comment named by `comment_id` on
  the image named by `image_id`, on behalf of `actor` (a
  `Philomena.Attribution.Actor` whose user may be `nil` for an anonymous
  visitor). This is a public read with no ban check.

  The image is loaded by id and authorized for `:show`, so a missing or
  non-visible image is `{:error, :unauthorized}`. The comment is then loaded by
  id scoped to that image: a
  missing comment is `{:error, :not_found}`, and a comment hidden from users is
  visible only when `actor` may `:show` it, otherwise `{:error, :unauthorized}`.

  Returns `{:ok, {image, comment, versions}}` carrying the last 25 versions,
  newest first, with diffs and version authors resolved.

  ## Examples

      iex> comment_history(user, "1", "1")
      {:ok, {%Image{}, %Comment{}, [%Version{}, ...]}}

      iex> comment_history(user, "1", "999999999")
      {:error, :not_found}

  """
  @spec comment_history(Actor.t(), any(), any()) ::
          {:ok, {Image.t(), Comment.t(), [Version.t()]}}
          | {:error, :unauthorized | :not_found}
  def comment_history(%Actor{} = actor, image_id, comment_id) do
    with {:ok, image} <- Images.load_visible_image(actor, image_id),
         {:ok, comment} <- load_image_comment(actor, image, comment_id) do
      {:ok, {image, comment, Versions.load_last_versions("Comment", comment)}}
    end
  end

  # The comment is loaded by id scoped to the image, a missing row is
  # `{:error, :not_found}`, and a comment
  # hidden from users is authorized for `:show` - visible to staff, otherwise
  # `{:error, :unauthorized}`.
  defp load_image_comment(actor, %Image{} = image, comment_id) do
    Comment
    |> where(image_id: ^image.id, id: ^to_string(comment_id))
    |> preload([:image, :deleted_by, user: [awards: :badge]])
    |> Repo.one()
    |> authorize_comment_visibility(actor)
  end

  defp authorize_comment_visibility(nil, _actor),
    do: {:error, :not_found}

  defp authorize_comment_visibility(%Comment{hidden_from_users: false} = comment, _actor),
    do: {:ok, comment}

  defp authorize_comment_visibility(%Comment{} = comment, actor) do
    with :ok <- authorize(actor, :show, comment) do
      {:ok, comment}
    end
  end

  @doc """
  Searches comments on behalf of `actor`, applying the viewing user's
  hidden-tag `filter`, the compiled query string `cq_string`, and `pagination`,
  sorted newest first.

  Hidden and non-approved comments are excluded from the results unless the
  viewing user is staff. Results carry the associations named by
  `opts[:preload]`, defaulting to the listing-display preloads. Returns
  `{:ok, results}`, or `{:error, msg}` when `cq_string` fails to compile.

  ## Examples

      iex> search_comments(actor, filter, "created_at.gte:1 week ago", pagination)
      {:ok, %Scrivener.Page{}}

      iex> search_comments(actor, filter, "created_at.gte:not-a-date", pagination)
      {:error, "Cannot parse date."}

  """
  @spec search_comments(Actor.t(), Filter.t(), String.t(), map(), Keyword.t()) ::
          {:ok, Scrivener.Page.t()} | {:error, String.t()}
  def search_comments(%Actor{user: user}, filter, cq_string, pagination, opts \\ []) do
    preloads =
      Keyword.get(opts, :preload, [
        :deleted_by,
        image: [:sources, tags: :aliases],
        user: [awards: :badge]
      ])

    case Query.compile(cq_string, user: user) do
      {:ok, query} ->
        results =
          user
          |> comment_search_definition(filter, query, pagination: pagination)
          |> Search.search_records(preload(Comment, ^preloads))

        {:ok, results}

      {:error, msg} ->
        {:error, msg}
    end
  end

  # Search-side exclusion filters mirroring the visibility rules a comment
  # listing enforces: everyone hides comments carrying the viewer's hidden
  # tags; non-staff additionally hide deleted and non-approved comments (a
  # signed-in user still sees their own non-approved comments). Staff see the
  # hidden and non-approved comments the extra filters would exclude.
  defp comment_filters(user, filter, show_hidden?) do
    [%{terms: %{"image.tag_ids" => filter.hidden_tag_ids}}]
    |> hide_deleted(show_hidden?)
    |> hide_non_approved(user, show_hidden?)
  end

  defp staff?(%{role: role}) when role in ~W(assistant moderator admin), do: true
  defp staff?(_user), do: false

  defp hide_deleted(filters, true), do: filters

  defp hide_deleted(filters, _show_hidden?),
    do: [
      %{term: %{hidden_from_users: true}},
      %{term: %{"image.hidden_from_users" => true}}
      | filters
    ]

  defp hide_non_approved(filters, _user, true), do: filters

  defp hide_non_approved(filters, %{id: user_id}, _show_hidden?),
    do: [
      %{
        bool: %{
          should: [%{term: %{approved: false}}, %{term: %{"image.approved" => false}}],
          must_not: [%{term: %{user_id: user_id}}]
        }
      }
      | filters
    ]

  defp hide_non_approved(filters, _user, _show_hidden?),
    do: [
      %{term: %{approved: false}},
      %{term: %{"image.approved" => false}}
      | filters
    ]

  @doc """
  Builds an unexecuted comment search definition for `user`, excluding
  comments the viewer's `filter` hides.

  `body` is one or more compiled query clauses. Options: `:pagination` sets
  the result window; `:show_hidden` (default `true`) lets staff viewers see
  deleted and non-approved comments - pass `false` for listings that stay
  clean regardless of who is looking. Results sort newest first.

  The definition is meant for batching into
  `PhilomenaQuery.Search.msearch_records/2` alongside other page content;
  execute it directly for a standalone listing.

  ## Examples

      iex> comment_search_definition(user, filter, %{term: %{author_id: 1}})
      %{module: Comment, ...}

  """
  @spec comment_search_definition(User.t() | nil, Filter.t(), map() | [map()], Keyword.t()) ::
          PhilomenaQuery.Search.search_definition()
  def comment_search_definition(user, filter, body, opts \\ []) do
    pagination = Keyword.get(opts, :pagination, %{})
    show_hidden? = Keyword.get(opts, :show_hidden, true) and staff?(user)

    Search.search_definition(
      Comment,
      %{
        query: %{
          bool: %{
            must: body,
            must_not: comment_filters(user, filter, show_hidden?)
          }
        },
        sort: %{created_at: :desc}
      },
      pagination
    )
  end

  @doc """
  Loads a page of `image`'s comments for `user`.

  `scrivener` is the `page`/`page_size` keyword list. Comments order by
  creation time, oldest first for users who read oldest-first and newest
  first otherwise. Staff see destroyed and non-approved comments; a
  signed-in user still sees their own non-approved ones.

  ## Examples

      iex> paginate_image_comments(user, image, page: 1, page_size: 25)
      %Scrivener.Page{}

  """
  @spec paginate_image_comments(User.t() | nil, Image.t(), Keyword.t()) :: Scrivener.Page.t()
  def paginate_image_comments(user, image, scrivener) do
    direction = load_direction(user)

    visible_image_comments(user, image)
    |> order_by([{^direction, :created_at}])
    |> preload([:image, :deleted_by, user: [awards: :badge]])
    |> Repo.paginate(scrivener)
  end

  @doc """
  Returns the page number on which `comment_id` appears in `image`'s comment
  listing for `actor`, honoring the viewer's reading direction.

  Raises `Ecto.NoResultsError` when the comment does not belong to the image.

  ## Examples

      iex> find_comment_page(actor, image, comment.id, page_size: 25)
      3

  """
  @spec find_comment_page(Actor.t(), Image.t(), integer(), Keyword.t()) :: pos_integer()
  def find_comment_page(%Actor{user: user}, image, comment_id, scrivener) do
    comment =
      Comment
      |> where(image_id: ^image.id)
      |> where(id: ^comment_id)
      |> Repo.one!()

    offset =
      visible_image_comments(user, image)
      |> filter_direction(comment.created_at, user)
      |> Repo.aggregate(:count, :id)

    page_size = scrivener[:page_size]

    # Pagination starts at page 1
    div(offset, page_size) + 1
  end

  @doc """
  Returns the number of the last page of `image`'s comment listing for
  `user`.

  ## Examples

      iex> last_comment_page(user, image, page_size: 25)
      4

  """
  @spec last_comment_page(User.t() | nil, Image.t(), Keyword.t()) :: pos_integer()
  def last_comment_page(user, image, scrivener) do
    offset =
      visible_image_comments(user, image)
      |> Repo.aggregate(:count, :id)

    page_size = scrivener[:page_size]

    # Pagination starts at page 1
    div(offset, page_size) + 1
  end

  defp visible_image_comments(user, image) do
    show_hidden? = staff?(user)

    Comment
    |> where(image_id: ^image.id)
    |> filter_destroyed(show_hidden?)
    |> filter_non_approved(user, show_hidden?)
  end

  defp load_direction(%{comments_newest_first: false}), do: :asc
  defp load_direction(_user), do: :desc

  defp filter_destroyed(query, true), do: query
  defp filter_destroyed(query, _show_hidden?), do: where(query, [c], not c.destroyed_content)

  defp filter_non_approved(query, _user, true), do: query

  defp filter_non_approved(query, %{id: user_id}, _show_hidden?),
    do: where(query, [c], c.approved or c.user_id == ^user_id)

  defp filter_non_approved(query, _user, _show_hidden?),
    do: where(query, [c], c.approved)

  # The offset counts only the comments ahead of the target in
  # the viewer's reading direction; counting the target itself would push
  # a comment sitting exactly on a page boundary onto the next page.
  defp filter_direction(query, time, %{comments_newest_first: false}),
    do: where(query, [c], c.created_at < ^time)

  defp filter_direction(query, time, _user),
    do: where(query, [c], c.created_at > ^time)

  @doc """
  Loads the image named by `image_id` for the comment `action`
  (`:index`, `:show`, `:create`, `:edit`, or `:update`), on behalf of `actor` (a
  `Philomena.Attribution.Actor` whose user may be `nil` for an anonymous
  visitor).

  The image is loaded with `:sources` and `tags: :aliases` preloaded, and
  authorized for the action's semantic ability: `:index` for a listing, `:show`
  for a single
  comment (resolving a duplicate image to its target and authorizing `:show` on
  it), and `:create_comment` for posting, editing, or updating. A non-castable
  id is `{:error, :not_found}`; a well-formed id that names no row authorizes
  `nil`, which no rule permits, so it is `{:error, :unauthorized}`.

  ## Examples

      iex> load_commentable_image(actor, "1", :index)
      {:ok, %Image{}}

      iex> load_commentable_image(actor, "1", :create)
      {:error, :unauthorized}

  """
  @spec load_commentable_image(Actor.t(), any(), atom()) ::
          {:ok, Image.t()} | {:error, :unauthorized | :not_found}
  def load_commentable_image(%Actor{user: user}, image_id, action) do
    case IntegerId.parse(image_id) do
      {:ok, id} ->
        image =
          Image
          |> preload([:sources, tags: :aliases])
          |> Repo.get(id)

        authorize_commentable_image(user, image, action)

      :error ->
        {:error, :not_found}
    end
  end

  defp authorize_commentable_image(user, image, :index) do
    with :ok <- authorize(user, :index, image), do: {:ok, image}
  end

  defp authorize_commentable_image(user, image, :show) do
    with :ok <- authorize(user, :show, image) do
      target = resolve_duplicate(image)

      with :ok <- authorize(user, :show, target), do: {:ok, target}
    end
  end

  defp authorize_commentable_image(user, image, action)
       when action in [:create, :edit, :update] do
    with :ok <- authorize(user, :create_comment, image), do: {:ok, image}
  end

  defp resolve_duplicate(%Image{duplicate_id: nil} = image), do: image

  defp resolve_duplicate(%Image{duplicate_id: duplicate_id}) do
    Image
    |> preload([:sources, tags: :aliases])
    |> Repo.get(duplicate_id)
  end

  @doc """
  Creates a comment on `image` from `params`, on behalf of `actor` (a
  `Philomena.Attribution.Actor` whose user may be `nil` for an anonymous
  visitor).

  This is a write, so `actor`'s write access is verified first (banned actor
  `{:error, :ban}`, no fingerprint `{:error, :unauthorized}`), then a non-exempt
  actor who has commented within the last 15 seconds gets
  `{:error, :rate_limited}`; `image` is expected to have been authorized for
  `:create_comment` by the caller. On a successful insert the comment and image
  are reindexed and post-insert bookkeeping runs: an approved comment increments
  its author's comment count (a no-op for an anonymous author), an unapproved one
  is reported for external links.

  Returns `{:ok, comment}` on success, `{:error, :creation_failed}` when the
  insert is rejected, `{:error, :rate_limited}` when the actor is over the limit,
  or `{:error, :ban}` / `{:error, :unauthorized}` from the write-access check.

  ## Examples

      iex> create_comment(actor, image, %{"body" => "Hi"})
      {:ok, %Comment{}}

      iex> create_comment(actor, image, %{"body" => ""})
      {:error, :creation_failed}

  """
  @spec create_comment(Actor.t(), Image.t(), map()) ::
          {:ok, Comment.t()}
          | {:error, :creation_failed | :ban | :unauthorized | :rate_limited}
  def create_comment(%Actor{} = actor, %Image{} = image, params) do
    with :ok <- verify_write_access(actor),
         :ok <- RateLimiter.check_rate_limit(actor, :comment_create) do
      case create_loaded_comment(image, actor_attributes(actor), params) do
        {:ok, %{comment: comment}} ->
          reindex_comment(comment)
          Images.reindex_image(image)
          record_comment_creation(actor, comment)
          RateLimiter.record_action(actor, :comment_create, @comment_create_window)
          {:ok, comment}

        _error ->
          {:error, :creation_failed}
      end
    end
  end

  # The IP/fingerprint/user attribution `create_loaded_comment/3` records,
  # rebuilt from the actor into the keyword list it expects.
  defp actor_attributes(%Actor{ip: ip, fingerprint: fingerprint, user: user}),
    do: [ip: ip, fingerprint: fingerprint, user: user]

  # Post-insert bookkeeping: an approved comment counts toward its author's
  # comment total (a no-op for an anonymous author, whose user is nil), an
  # unapproved one is reported for external links.
  defp record_comment_creation(%Actor{user: user}, %Comment{approved: true}),
    do: UserStatistics.inc_stat(user, :comments_count)

  defp record_comment_creation(_actor, comment),
    do: report_non_approved(comment)

  @doc """
  Inserts a comment built on `image` from `params` with the `attribution`
  keyword list (`:user`, `:ip`, `:fingerprint`), incrementing the image's comment
  count, notifying subscribers, and subscribing the author on reply.

  This is the internal insertion engine shared with `create_comment/3`; it
  performs no authorization and no post-insert reindex or bookkeeping.

  ## Examples

      iex> create_loaded_comment(image, [user: user], %{"body" => "Hi"})
      {:ok, %{comment: %Comment{}}}

  """
  def create_loaded_comment(image, attribution, params \\ %{}) do
    comment =
      Ecto.build_assoc(image, :comments)
      |> Comment.creation_changeset(params, attribution)

    image_query =
      Image
      |> where(id: ^image.id)

    image_lock_query =
      lock(image_query, "FOR UPDATE")

    Multi.new()
    |> Multi.one(:image, image_lock_query)
    |> Multi.insert(:comment, comment)
    |> Multi.update_all(:update_image, image_query, inc: [comments_count: 1])
    |> Multi.run(:notification, &notify_comment/2)
    |> Images.maybe_subscribe_on(:image, attribution[:user], :watch_on_reply)
    |> Repo.transaction()
  end

  defp notify_comment(_repo, %{image: image, comment: comment}) do
    Notifications.create_image_comment_notification(comment.user, image, comment)
  end

  @doc """
  Loads the comment named by `comment_id` on `image`. A missing comment is
  `{:error, :not_found}`; hidden comments are returned as well, not filtered out.

  ## Examples

      iex> load_comment_for_show(image, "1")
      {:ok, %Comment{}}

      iex> load_comment_for_show(image, "999999999")
      {:error, :not_found}

  """
  @spec load_comment_for_show(Image.t(), any()) ::
          {:ok, Comment.t()} | {:error, :not_found}
  def load_comment_for_show(%Image{} = image, comment_id) do
    case load_scoped_comment(image, comment_id, [:image, :deleted_by, user: [awards: :badge]]) do
      nil -> {:error, :not_found}
      comment -> {:ok, comment}
    end
  end

  @doc """
  Loads the comment named by `comment_id` on `image` for editing, on behalf of
  `actor` (a `Philomena.Attribution.Actor` whose user may be `nil`).

  This is a read that precedes an edit: a banned actor is rejected with
  `{:error, :ban}` first, but the fingerprint requirement that the write itself
  enforces does not apply here. The comment is then loaded and authorized for
  `:edit`.

  Returns `{:ok, {comment, changeset}}` - the loaded comment and a change-tracking
  changeset for it - `{:error, :ban}` for a banned actor,
  `{:error, :not_found}` when the comment does not exist, or
  `{:error, :unauthorized}` when it may not be edited.

  ## Examples

      iex> load_comment_for_edit(actor, image, "1")
      {:ok, {%Comment{}, %Ecto.Changeset{}}}

  """
  @spec load_comment_for_edit(Actor.t(), Image.t(), any()) ::
          {:ok, {Comment.t(), Ecto.Changeset.t()}}
          | {:error, :ban | :unauthorized | :not_found}
  def load_comment_for_edit(%Actor{} = actor, %Image{} = image, comment_id) do
    with :ok <- verify_not_banned(actor),
         {:ok, comment} <- load_editable_comment(actor.user, image, comment_id) do
      {:ok, {comment, change_comment(comment)}}
    end
  end

  # Load-and-authorize chain shared by the edit and update actions: the comment
  # is loaded within the image (a missing row is `{:error, :not_found}`) and
  # authorized for `:edit`.
  defp load_editable_comment(user, image, comment_id) do
    case load_scoped_comment(image, comment_id, [:image, user: [awards: :badge]]) do
      nil ->
        {:error, :not_found}

      comment ->
        with :ok <- authorize(user, :edit, comment), do: {:ok, comment}
    end
  end

  defp load_scoped_comment(image, comment_id, preloads) do
    Comment
    |> where(image_id: ^image.id, id: ^to_string(comment_id))
    |> preload(^preloads)
    |> Repo.one()
  end

  @doc """
  Loads the comment named by `comment_id` on the image named by `image_id` for
  reporting, on behalf of `actor` (a `Philomena.Attribution.Actor` whose user may
  be `nil` for an anonymous visitor).

  This is a read that precedes a report: a banned actor is rejected with
  `{:error, :ban}` first, but the fingerprint requirement that the write itself
  enforces does not apply here. The image is authorized for `:show` and the
  comment loaded within it (a hidden comment visible only to actors who may
  `:show` it).

  Returns `{:ok, {comment, changeset}}` - the comment with its image preloaded,
  and a changeset for reporting it - `{:error, :ban}` for a banned actor,
  `{:error, :unauthorized}` when the image or hidden comment is not visible, or
  `{:error, :not_found}` when the comment does not exist.

  ## Examples

      iex> load_comment_for_report(actor, "1", "1")
      {:ok, {%Comment{}, %Ecto.Changeset{}}}

  """
  @spec load_comment_for_report(Actor.t(), any(), any()) ::
          {:ok, {Comment.t(), Ecto.Changeset.t()}}
          | {:error, :ban | :unauthorized | :not_found}
  def load_comment_for_report(%Actor{} = actor, image_id, comment_id) do
    with :ok <- verify_not_banned(actor),
         {:ok, comment} <- load_reportable_comment(actor.user, image_id, comment_id) do
      changeset =
        Reports.change_report(%Report{reportable_type: "Comment", reportable_id: comment.id})

      {:ok, {comment, changeset}}
    end
  end

  @doc """
  Loads the comment named by `comment_id` on the image named by `image_id` for
  creating its report, on behalf of `actor` (a `Philomena.Attribution.Actor`
  whose user may be `nil`).

  This is the write path, so `actor`'s write access is verified first: a banned
  actor is `{:error, :ban}` and an actor with no fingerprint is
  `{:error, :unauthorized}`. The image is then authorized for `:show` and the
  comment loaded within it, as `load_comment_for_report/3` does.

  Returns `{:ok, comment}` - the comment with its image preloaded - `{:error, :ban}`
  or `{:error, :unauthorized}` from the write-access check,
  `{:error, :unauthorized}` when the image or hidden comment is not visible, or
  `{:error, :not_found}` when the comment does not exist.

  ## Examples

      iex> load_comment_for_report_creation(actor, "1", "1")
      {:ok, %Comment{}}

  """
  @spec load_comment_for_report_creation(Actor.t(), any(), any()) ::
          {:ok, Comment.t()} | {:error, :ban | :unauthorized | :not_found}
  def load_comment_for_report_creation(%Actor{} = actor, image_id, comment_id) do
    with :ok <- verify_write_access(actor) do
      load_reportable_comment(actor.user, image_id, comment_id)
    end
  end

  # Shared image-and-comment load-and-authorize chain for the report actions: the
  # image is authorized for `:show`, the comment is loaded within it (a missing
  # row is `{:error, :not_found}`), and a comment hidden from users is visible
  # only to a user who may `:show` it.
  defp load_reportable_comment(user, image_id, comment_id) do
    with {:ok, image} <- Images.load_visible_image(user, image_id) do
      image
      |> load_scoped_comment(comment_id, [:image, :deleted_by, user: [awards: :badge]])
      |> authorize_comment_visibility(user)
    end
  end

  @doc """
  Updates the comment named by `comment_id` on `image` from
  `params`, on behalf of `actor` (a `Philomena.Attribution.Actor` whose user may
  be `nil`).

  This is a write, so `actor`'s write access is verified first (banned actor
  `{:error, :ban}`, no fingerprint `{:error, :unauthorized}`), before the comment
  is loaded within the image and authorized for `:edit`. The edit is then applied,
  recording a version attributed to `actor`'s user; an unapproved result is
  reported for containing external links, and the comment is reindexed.

  Returns `{:ok, comment}` on success, `{:error, {comment, changeset}}` when the
  edit is rejected, `{:error, :ban}` or
  `{:error, :unauthorized}` from the write-access check, `{:error, :unauthorized}`
  when the comment may not be edited, or `{:error, :not_found}` when it does not
  exist.

  ## Examples

      iex> update_comment(actor, image, "1", %{"body" => "Edited"})
      {:ok, %Comment{}}

      iex> update_comment(actor, image, "1", %{"body" => ""})
      {:error, {%Comment{}, %Ecto.Changeset{}}}

  """
  @spec update_comment(Actor.t(), Image.t(), any(), map() | nil) ::
          {:ok, Comment.t()}
          | {:error, {Comment.t(), Ecto.Changeset.t()}}
          | {:error, :ban | :unauthorized | :not_found}
  def update_comment(%Actor{} = actor, %Image{} = image, comment_id, params) do
    with :ok <- verify_write_access(actor),
         {:ok, comment} <- load_editable_comment(actor.user, image, comment_id) do
      case update_comment(comment, actor.user, params || %{}) do
        {:ok, %{comment: updated_comment}} ->
          report_non_approved(updated_comment)
          reindex_comment(updated_comment)
          {:ok, updated_comment}

        {:error, :comment, changeset, _changes} ->
          {:error, {comment, changeset}}
      end
    end
  end

  @doc """
  Updates a comment.

  ## Examples

      iex> update_comment(comment, %{field: new_value})
      {:ok, %Comment{}}

      iex> update_comment(comment, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_comment(%Comment{} = comment, editor, attrs) do
    now = DateTime.utc_now(:second)
    current_body = comment.body
    current_reason = comment.edit_reason

    comment_changes = Comment.changeset(comment, attrs, now)

    Multi.new()
    |> Multi.update(:comment, comment_changes)
    |> Multi.run(:version, fn _repo, _changes ->
      Versions.create_version("Comment", comment.id, editor.id, %{
        "body" => current_body,
        "edit_reason" => current_reason
      })
    end)
    |> Repo.transaction()
  end

  @doc """
  Deletes a Comment.

  ## Examples

      iex> delete_comment(comment)
      {:ok, %Comment{}}

      iex> delete_comment(comment)
      {:error, %Ecto.Changeset{}}

  """
  def delete_comment(%Comment{} = comment) do
    Repo.delete(comment)
  end

  @doc """
  Hides the comment named by `comment_id` with `params`
  (carrying the deletion reason), on behalf of `actor` (a
  `Philomena.Attribution.Actor`).

  Authorization (`:hide` on the loaded comment) happens here; on success the
  comment is hidden, its associated reports are closed, it is reindexed, and a
  moderation log is written attributing the hide to `actor`. An id that cannot
  name a row is `{:error, :not_found}`, while a well-formed id that names no row
  authorizes `nil` - which no rule permits - and is therefore
  `{:error, :unauthorized}`.

  A blank deletion reason fails the hide changeset and returns
  `{:error, %Comment{}}` carrying the loaded comment so the caller can still
  act on it.

  ## Examples

      iex> hide_comment(moderator, "1", %{"deletion_reason" => "Spam"})
      {:ok, %Comment{}}

      iex> hide_comment(user, "1", %{"deletion_reason" => "Spam"})
      {:error, :unauthorized}

      iex> hide_comment(moderator, "not-an-integer", %{})
      {:error, :not_found}

  """
  @spec hide_comment(Actor.t(), any(), map()) ::
          {:ok, Comment.t()}
          | {:error, :unauthorized | :not_found}
          | {:error, Comment.t()}
  def hide_comment(%Actor{} = actor, comment_id, params) do
    case IntegerId.parse(comment_id) do
      {:ok, id} ->
        comment = Repo.get(Comment, id)

        with :ok <- authorize(actor, :hide, comment) do
          hide_authorized_comment(actor, comment, params)
        end

      :error ->
        {:error, :not_found}
    end
  end

  defp hide_authorized_comment(actor, %Comment{} = comment, params) do
    case hide_loaded_comment(comment, params, actor.user) do
      {:ok, hidden_comment} ->
        log_comment_hide(actor, hidden_comment)
        {:ok, hidden_comment}

      _error ->
        {:error, comment}
    end
  end

  defp log_comment_hide(actor, %Comment{} = comment) do
    ModerationLogs.create_moderation_log(
      actor,
      "Image.Comment.Hide:create",
      Paths.image_comment_path(comment.image_id, comment.id),
      "Deleted comment on image #{comment.image_id} (#{comment.deletion_reason})"
    )
  end

  @doc """
  Hides a comment and handles associated reports.

  ## Parameters
  - comment: The comment to hide
  - attrs: Attributes for the hide operation
  - user: The user performing the hide action

  ## Examples

      iex> hide_loaded_comment(comment, %{staff_note: "Rule violation"}, user)
      {:ok, %Comment{}}

  """
  def hide_loaded_comment(%Comment{} = comment, attrs, user) do
    report_query = Reports.close_report_query({"Comment", comment.id}, user)
    comment = Comment.hide_changeset(comment, attrs, user)

    Multi.new()
    |> Multi.update(:comment, comment)
    |> Multi.update_all(:reports, report_query, [])
    |> Repo.transaction()
    |> case do
      {:ok, %{comment: comment, reports: {_count, reports}}} ->
        Reports.reindex_reports(reports)
        reindex_comment(comment)

        {:ok, comment}

      error ->
        error
    end
  end

  @doc """
  Restores the comment named by `comment_id`, on behalf of
  `actor` (a `Philomena.Attribution.Actor`).

  Authorization (`:hide` on the loaded comment) happens here; on success the
  comment is unhidden, reindexed, and a moderation log is written attributing
  the restore to `actor`. An id that cannot name a row is `{:error, :not_found}`,
  while a well-formed id that names no row authorizes `nil` - which no rule
  permits - and is therefore `{:error, :unauthorized}`.

  Restoring an already-visible comment succeeds and re-logs; the restore is
  idempotent. A failed restore returns `{:error, %Comment{}}` carrying the loaded
  comment so the caller can still act on it.

  ## Examples

      iex> unhide_comment(moderator, "1")
      {:ok, %Comment{}}

      iex> unhide_comment(user, "1")
      {:error, :unauthorized}

      iex> unhide_comment(moderator, "not-an-integer")
      {:error, :not_found}

  """
  @spec unhide_comment(Actor.t(), any()) ::
          {:ok, Comment.t()}
          | {:error, :unauthorized | :not_found}
          | {:error, Comment.t()}
  def unhide_comment(%Actor{} = actor, comment_id) do
    case IntegerId.parse(comment_id) do
      {:ok, id} ->
        comment = Repo.get(Comment, id)

        with :ok <- authorize(actor, :hide, comment) do
          unhide_authorized_comment(actor, comment)
        end

      :error ->
        {:error, :not_found}
    end
  end

  defp unhide_authorized_comment(actor, %Comment{} = comment) do
    case unhide_comment(comment) do
      {:ok, restored_comment} ->
        log_comment_unhide(actor, restored_comment)
        {:ok, restored_comment}

      _error ->
        {:error, comment}
    end
  end

  defp log_comment_unhide(actor, %Comment{} = comment) do
    ModerationLogs.create_moderation_log(
      actor,
      "Image.Comment.Hide:delete",
      Paths.image_comment_path(comment.image_id, comment.id),
      "Restored comment on image #{comment.image_id}"
    )
  end

  @doc """
  Unhides a previously hidden comment.

  ## Examples

      iex> unhide_comment(comment)
      {:ok, %Comment{}}

  """
  def unhide_comment(%Comment{} = comment) do
    comment
    |> Comment.unhide_changeset()
    |> Repo.update()
    |> reindex_after_update()
  end

  @doc """
  Destroys the content of the comment named by `comment_id`, on
  behalf of `actor` (a `Philomena.Attribution.Actor`).

  Authorization (`:hide` on the loaded comment) happens here; on success the
  comment's text is removed, its image's comment count is decremented, the
  comment is reindexed, and a moderation log is written attributing the
  destruction to `actor`. An id that cannot name a row is `{:error, :not_found}`,
  while a well-formed id that names no row authorizes `nil` - which no rule
  permits - and is therefore `{:error, :unauthorized}`.

  A failed destruction returns `{:error, %Comment{}}` carrying the loaded comment
  so the caller can still act on it.

  ## Examples

      iex> destroy_comment(moderator, "1")
      {:ok, %Comment{}}

      iex> destroy_comment(user, "1")
      {:error, :unauthorized}

      iex> destroy_comment(moderator, "not-an-integer")
      {:error, :not_found}

  """
  @spec destroy_comment(Actor.t(), any()) ::
          {:ok, Comment.t()}
          | {:error, :unauthorized | :not_found}
          | {:error, Comment.t()}
  def destroy_comment(%Actor{} = actor, comment_id) do
    case IntegerId.parse(comment_id) do
      {:ok, id} ->
        comment = Repo.get(Comment, id)

        with :ok <- authorize(actor, :hide, comment) do
          destroy_loaded_comment(actor, comment)
        end

      :error ->
        {:error, :not_found}
    end
  end

  defp destroy_loaded_comment(actor, %Comment{} = comment) do
    case destroy_comment(comment) do
      {:ok, destroyed_comment} ->
        log_comment_destruction(actor, destroyed_comment)
        {:ok, destroyed_comment}

      _error ->
        # The destroy changeset always succeeds, so this branch is not reachable;
        # it carries the loaded comment for the caller to reuse.
        {:error, comment}
    end
  end

  defp log_comment_destruction(actor, %Comment{} = comment) do
    ModerationLogs.create_moderation_log(
      actor,
      "Image.Comment.Delete:create",
      Paths.image_comment_path(comment.image_id, comment.id),
      "Destroyed comment on image #{comment.image_id}"
    )
  end

  @doc """
  Marks a comment as destroyed and removes its text (hard deletion).

  ## Examples

      iex> destroy_comment(comment)
      {:ok, %Comment{}}

  """
  def destroy_comment(%Comment{} = comment) do
    comment = comment |> Repo.preload(:user)

    Multi.new()
    |> Multi.update(:comment, Comment.destroy_changeset(comment))
    |> Multi.update_all(
      :image,
      Image |> where(id: ^comment.image_id),
      inc: [comments_count: -1]
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{comment: comment}} ->
        UserStatistics.inc_stat(comment.user_id, :comments_count, -1)
        reindex_comment(comment)

        {:ok, comment}

      error ->
        error
    end
  end

  defp reindex_after_update(result) do
    case result do
      {:ok, comment} ->
        reindex_comment(comment)

        {:ok, comment}

      error ->
        error
    end
  end

  @doc """
  Approves the comment named by `comment_id`, on behalf of
  `actor` (a `Philomena.Attribution.Actor`).

  Authorization (`:approve` on the loaded comment) happens here; on success the
  comment's associated reports are closed, the author's comment count is
  incremented, the comment is reindexed, and a moderation log is written
  attributing the approval to `actor`. An id that cannot name a row is
  `{:error, :not_found}`, while a well-formed id that names no row authorizes
  `nil` - which no rule permits - and is therefore `{:error, :unauthorized}`.

  Approving an already-approved comment succeeds and re-logs; the approval is
  idempotent. A failed approval changeset returns
  `{:error, %Comment{}}` carrying the loaded comment.

  ## Examples

      iex> approve_comment(moderator, "1")
      {:ok, %Comment{}}

      iex> approve_comment(user, "1")
      {:error, :unauthorized}

      iex> approve_comment(moderator, "not-an-integer")
      {:error, :not_found}

  """
  @spec approve_comment(Actor.t(), any()) ::
          {:ok, Comment.t()}
          | {:error, :unauthorized | :not_found}
          | {:error, Comment.t()}
  def approve_comment(%Actor{} = actor, comment_id) do
    case IntegerId.parse(comment_id) do
      {:ok, id} ->
        comment = Repo.get(Comment, id)

        with :ok <- authorize(actor, :approve, comment) do
          approve_loaded_comment(actor, comment)
        end

      :error ->
        {:error, :not_found}
    end
  end

  defp approve_loaded_comment(actor, %Comment{} = comment) do
    report_query = Reports.close_report_query({"Comment", comment.id}, actor.user)
    changeset = Comment.approve_changeset(comment)

    Multi.new()
    |> Multi.update(:comment, changeset)
    |> Multi.update_all(:reports, report_query, [])
    |> Repo.transaction()
    |> case do
      {:ok, %{comment: approved_comment, reports: {_count, reports}}} ->
        UserStatistics.inc_stat(approved_comment.user_id, :comments_count)
        Reports.reindex_reports(reports)
        reindex_comment(approved_comment)
        log_comment_approval(actor, approved_comment)

        {:ok, approved_comment}

      _error ->
        # The approval changeset sets a boolean unconditionally, so this branch
        # is not reachable; it carries the loaded comment for symmetry.
        {:error, comment}
    end
  end

  defp log_comment_approval(actor, %Comment{} = comment) do
    ModerationLogs.create_moderation_log(
      actor,
      "Image.Comment.Approve:create",
      Paths.image_comment_path(comment.image_id, comment.id),
      "Approved comment on image #{comment.image_id}"
    )
  end

  @doc """
  Creates a system report for non-approved comments containing external images.
  Returns false for already approved comments.

  ## Returns
  - `false`: If the comment is already approved
  - `{:ok, %Report{}}`: If a system report was created

  ## Examples

      iex> report_non_approved(approved_comment)
      false

      iex> report_non_approved(unapproved_comment)
      {:ok, %Report{}}

  """
  def report_non_approved(%Comment{approved: true}), do: false

  def report_non_approved(comment) do
    Reports.create_system_report(
      {"Comment", comment.id},
      "Approval",
      "Comment contains external links"
    )
  end

  @doc """
  Migrates comments from one image to another when handling duplicate images.
  Returns the duplicate image parameter unchanged, for use in a pipeline.

  ## Parameters
  - image: The source image whose comments will be moved
  - duplicate_of_image: The target image that will receive the comments

  ## Examples

      iex> migrate_comments(source_image, target_image)
      %Image{}

  """
  def migrate_comments(image, duplicate_of_image) do
    {count, nil} =
      Comment
      |> where(image_id: ^image.id)
      |> Repo.update_all(set: [image_id: duplicate_of_image.id])

    Image
    |> where(id: ^duplicate_of_image.id)
    |> Repo.update_all(inc: [comments_count: count])

    reindex_comments_on_image(duplicate_of_image)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking comment changes.

  ## Examples

      iex> change_comment(comment)
      %Ecto.Changeset{source: %Comment{}}

  """
  def change_comment(%Comment{} = comment) do
    Comment.changeset(comment, %{})
  end

  @doc """
  Updates comment search indices when a user's name changes.

  ## Examples

      iex> user_name_reindex("old_username", "new_username")
      :ok

  """
  def user_name_reindex(old_name, new_name) do
    data = Comments.SearchIndex.user_name_update_by_query(old_name, new_name)

    Search.update_by_query(Comment, data.query, data.set_replacements, data.replacements)
  end

  @doc """
  Queues a single comment for search index updates.
  Returns the comment struct unchanged, for use in a pipeline.

  ## Examples

      iex> reindex_comment(comment)
      %Comment{}

  """
  def reindex_comment(%Comment{} = comment) do
    Exq.enqueue(Exq, "indexing", IndexWorker, ["Comments", "id", [comment.id]])

    comment
  end

  @doc """
  Queues all comments associated with an image for search index updates.
  Returns the image struct unchanged, for use in a pipeline.

  ## Examples

      iex> reindex_comments_on_image(image)
      %Image{}

  """
  def reindex_comments_on_image(image) do
    Exq.enqueue(Exq, "indexing", IndexWorker, ["Comments", "image_id", [image.id]])

    image
  end

  @doc """
  Queues all comments associated with a list of image IDs for search index updates.
  Returns the list unchanged, for use in a pipeline.

  ## Examples

      iex> reindex_comments_on_images([1, 2, 3])
      [1, 2, 3]

  """
  def reindex_comments_on_images(image_ids) do
    Exq.enqueue(Exq, "indexing", IndexWorker, ["Comments", "image_id", image_ids])

    image_ids
  end

  @doc """
  Provides preload queries for comment indexing operations.

  ## Examples

      iex> indexing_preloads()
      [user: user_query, image: image_query]

  """
  def indexing_preloads do
    user_query = select(User, [u], map(u, [:id, :name]))
    tag_query = select(Tag, [t], map(t, [:id, :name]))

    image_query =
      Image
      |> select([i], struct(i, [:approved, :hidden_from_users, :id]))
      |> preload(tags: ^tag_query)

    [
      user: user_query,
      image: image_query,
      deleted_by: user_query
    ]
  end

  @doc """
  Performs a search reindex operation on comments matching the given criteria.

  ## Parameters
  - column: The database column to filter on (e.g., :id, :image_id)
  - condition: A list of values to match against the column

  ## Examples

      iex> perform_reindex(:id, [1, 2, 3])
      :ok

      iex> perform_reindex(:image_id, [123])
      :ok

  """
  def perform_reindex(column, condition) do
    Comment
    |> preload(^indexing_preloads())
    |> where([c], field(c, ^column) in ^condition)
    |> Search.reindex(Comment)
  end
end
