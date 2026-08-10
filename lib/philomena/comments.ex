defmodule Philomena.Comments do
  @moduledoc """
  Image comment reads, writes, moderation, search, and indexing.
  """

  import Ecto.Query, warn: false

  import Philomena.Authorization,
    only: [authorize: 3, verify_write_access: 1]

  alias Ecto.Multi
  alias Philomena.Attribution.Actor
  alias Philomena.Comments
  alias Philomena.Comments.{Comment, CommentForm, CommentHistory, Query}
  alias Philomena.Filters.Filter
  alias Philomena.Images
  alias Philomena.Images.Image
  alias Philomena.IndexWorker
  alias Philomena.IntegerId
  alias Philomena.Loader
  alias Philomena.ModerationLogs
  alias Philomena.ModerationLogs.Paths
  alias Philomena.Notifications
  alias Philomena.RateLimiter
  alias Philomena.Repo
  alias Philomena.Reports
  alias Philomena.Tags.Tag
  alias Philomena.UserStatistics
  alias Philomena.Users.User
  alias Philomena.Versions
  alias PhilomenaQuery.Search

  @comment_create_window 15
  @image_preloads [:sources, tags: :aliases]
  @display_preloads [:deleted_by, user: [awards: :badge]]
  @search_preloads [:deleted_by, image: @image_preloads, user: [awards: :badge]]

  @typedoc "A normalized request-facing failure."
  @type request_error :: :ban | :unauthorized | :not_found | :forced_filter

  defp persist_comment(%Image{} = image, %Actor{} = actor, attrs) do
    comment =
      image
      |> Ecto.build_assoc(:comments)
      |> Comment.creation_changeset(attrs, actor)

    image_query = where(Image, id: ^image.id)

    Multi.new()
    |> Multi.one(:image, lock(image_query, "FOR UPDATE"))
    |> Multi.insert(:comment, comment)
    |> Multi.update_all(:update_image, image_query, inc: [comments_count: 1])
    |> Multi.run(:notification, &notify_comment/2)
    |> Images.maybe_subscribe_on(:image, actor.user, :watch_on_reply)
    |> Repo.transaction()
  end

  defp notify_comment(_repo, %{image: image, comment: comment}) do
    Notifications.broadcast_image_comment(comment.user, image, comment)
  end

  defp persist_comment_update(%Comment{} = comment, %Actor{} = actor, attrs) do
    now = DateTime.utc_now(:second)

    comment_query =
      Comment
      |> where(id: ^comment.id)
      |> preload(:user)
      |> lock("FOR UPDATE")

    Multi.new()
    |> Multi.one(:original_comment, comment_query)
    |> Multi.update(:comment, fn %{original_comment: original_comment} ->
      Comment.changeset(original_comment, attrs, now)
    end)
    |> Versions.record_edit(:version, :original_comment, :comment, actor)
    |> Repo.transaction()
  end

  defp change_comment(%Comment{} = comment) do
    Comment.changeset(comment)
  end

  defp report_non_approved(%Comment{approved: true}), do: false

  defp report_non_approved(comment) do
    Reports.create_system_report(
      "Approval",
      "Comment contains external links",
      comment_id: comment.id
    )
  end

  defp record_comment_creation(%Actor{user: user}, %Comment{approved: true}),
    do: UserStatistics.increment(user, :comments_count)

  defp record_comment_creation(_actor, comment), do: report_non_approved(comment)

  defp broadcast_comment(event, %Comment{} = comment) do
    PhilomenaWeb.Endpoint.broadcast!(
      "firehose",
      event,
      PhilomenaWeb.Api.Json.CommentView.render("show.json", %{comment: comment})
    )

    comment
  end

  defp load_global_comment(%Actor{} = actor, id) do
    with {:ok, id} <- IntegerId.parse(id),
         {:ok, comment} <-
           Comment
           |> where([comment], comment.id == ^id and comment.destroyed_content == false)
           |> preload([:image, :user])
           |> Loader.one(),
         :ok <- authorize(actor, :show, comment.image),
         :ok <- authorize(actor, :show, comment) do
      {:ok, comment}
    else
      :error -> {:error, :not_found}
      error -> error
    end
  end

  defp load_image(%Actor{} = actor, image_id, action, preloads) do
    Loader.fetch_and_authorize(Image, actor, action, image_id, preloads)
  end

  defp load_comment_in_image(%Actor{} = actor, %Image{} = image, comment_id, action, preloads) do
    with {:ok, comment_id} <- IntegerId.parse(comment_id),
         {:ok, comment} <-
           Comment
           |> where([comment], comment.image_id == ^image.id and comment.id == ^comment_id)
           |> preload(^preloads)
           |> Loader.one_and_authorize(actor, action) do
      {:ok, %{comment | image: image}}
    else
      :error -> {:error, :not_found}
      error -> error
    end
  end

  defp load_image_comment(
         %Actor{} = actor,
         image_id,
         comment_id,
         action,
         image_preloads,
         comment_preloads
       ) do
    with {:ok, image} <- load_image(actor, image_id, :show, image_preloads),
         {:ok, comment} <-
           load_comment_in_image(actor, image, comment_id, action, comment_preloads) do
      {:ok, {image, comment}}
    end
  end

  defp load_editable_comment(%Actor{} = actor, image, comment_id, action) do
    with :ok <- authorize(actor, :create_comment, image),
         :ok <- Images.verify_forced_filter_access(actor, image) do
      load_comment_in_image(actor, image, comment_id, action, @display_preloads)
    end
  end

  defp load_commentable_image_for_action(%Actor{} = actor, image_id, action) do
    action =
      case action do
        action when action in [:create, :edit, :update] -> :create_comment
        action -> action
      end

    case load_image(actor, image_id, action, @image_preloads) do
      {:ok, %Image{duplicate_id: nil} = image} ->
        {:ok, image}

      {:ok, %Image{duplicate_id: duplicate_id}} ->
        load_image(actor, duplicate_id, action, @image_preloads)

      error ->
        error
    end
  end

  defp authorized?(%Actor{} = actor, action, subject),
    do: authorize(actor, action, subject) == :ok

  defp visibility_policy(%Actor{} = actor, allow_privileged?) do
    %{
      show_hidden_comments?:
        allow_privileged? and
          authorized?(actor, :show, %Comment{hidden_from_users: true}),
      show_hidden_images?:
        allow_privileged? and authorized?(actor, :show, %Image{hidden_from_users: true}),
      show_destroyed_comments?: allow_privileged? and authorized?(actor, :delete, %Comment{}),
      show_unapproved_comments?: allow_privileged? and authorized?(actor, :approve, %Comment{}),
      show_unapproved_images?: allow_privileged? and authorized?(actor, :approve, %Image{})
    }
  end

  defp search_exclusions(%Actor{user: user} = actor, filter, allow_privileged?) do
    policy = visibility_policy(actor, allow_privileged?)

    [%{terms: %{"image.tag_ids" => filter.hidden_tag_ids}}]
    |> exclude_hidden_comments(policy.show_hidden_comments?)
    |> exclude_hidden_images(policy.show_hidden_images?)
    |> exclude_destroyed_comments(policy.show_destroyed_comments?)
    |> exclude_unapproved_comments(user, policy.show_unapproved_comments?)
    |> exclude_unapproved_images(policy.show_unapproved_images?)
  end

  defp exclude_hidden_comments(filters, true), do: filters

  defp exclude_hidden_comments(filters, false),
    do: [%{term: %{hidden_from_users: true}} | filters]

  defp exclude_hidden_images(filters, true), do: filters

  defp exclude_hidden_images(filters, false),
    do: [%{term: %{"image.hidden_from_users" => true}} | filters]

  defp exclude_destroyed_comments(filters, true), do: filters

  defp exclude_destroyed_comments(filters, false),
    do: [%{term: %{destroyed_content: true}} | filters]

  defp exclude_unapproved_comments(filters, _user, true), do: filters

  defp exclude_unapproved_comments(filters, %User{id: user_id}, false) do
    [
      %{
        bool: %{
          must: [%{term: %{approved: false}}],
          must_not: [%{term: %{user_id: user_id}}]
        }
      }
      | filters
    ]
  end

  defp exclude_unapproved_comments(filters, _user, false),
    do: [%{term: %{approved: false}} | filters]

  defp exclude_unapproved_images(filters, true), do: filters

  defp exclude_unapproved_images(filters, false),
    do: [%{term: %{"image.approved" => false}} | filters]

  defp visible_image_comments(%Actor{} = actor, %Image{} = image) do
    policy = visibility_policy(actor, true)

    Comment
    |> where(image_id: ^image.id)
    |> filter_hidden_comments(policy.show_hidden_comments?)
    |> filter_destroyed_comments(policy.show_destroyed_comments?)
    |> filter_non_approved(actor.user, policy.show_unapproved_comments?)
  end

  defp filter_hidden_comments(query, true), do: query

  defp filter_hidden_comments(query, false),
    do: where(query, [comment], not comment.hidden_from_users)

  defp filter_destroyed_comments(query, true), do: query

  defp filter_destroyed_comments(query, false),
    do: where(query, [comment], not comment.destroyed_content)

  defp filter_non_approved(query, _user, true), do: query

  defp filter_non_approved(query, %User{id: user_id}, false),
    do: where(query, [comment], comment.approved or comment.user_id == ^user_id)

  defp filter_non_approved(query, _user, false),
    do: where(query, [comment], comment.approved)

  defp load_direction(%User{settings: %{comments_newest_first: false}}), do: :asc
  defp load_direction(_user), do: :desc

  defp filter_direction(query, %Comment{} = comment, %User{
         settings: %{comments_newest_first: false}
       }) do
    where(
      query,
      [candidate],
      candidate.created_at < ^comment.created_at or
        (candidate.created_at == ^comment.created_at and candidate.id < ^comment.id)
    )
  end

  defp filter_direction(query, %Comment{} = comment, _user) do
    where(
      query,
      [candidate],
      candidate.created_at > ^comment.created_at or
        (candidate.created_at == ^comment.created_at and candidate.id > ^comment.id)
    )
  end

  @doc false
  @spec create_comment_for_fixture(Image.t(), Actor.t(), map()) ::
          {:ok, map()} | {:error, Multi.name(), term(), map()}
  def create_comment_for_fixture(%Image{} = image, %Actor{} = actor, attrs \\ %{}),
    do: persist_comment(image, actor, attrs)

  @doc false
  @spec hide_comment_for_fixture(Comment.t(), map(), User.t()) ::
          {:ok, Comment.t()} | {:error, term()}
  def hide_comment_for_fixture(%Comment{} = comment, attrs, %User{} = user) do
    comment
    |> Comment.hide_changeset(attrs, user)
    |> Repo.update()
    |> case do
      {:ok, hidden_comment} -> {:ok, reindex_comment(hidden_comment)}
      error -> error
    end
  end

  @doc false
  @spec update_comment_for_fixture(Comment.t(), Actor.t(), map()) ::
          {:ok, map()} | {:error, Multi.name(), term(), map()}
  def update_comment_for_fixture(%Comment{} = comment, %Actor{} = actor, attrs) do
    persist_comment_update(comment, actor, attrs)
  end

  @doc false
  @spec destroy_comment_for_fixture(Comment.t()) ::
          {:ok, Comment.t()} | {:error, term()}
  def destroy_comment_for_fixture(%Comment{} = comment) do
    Multi.new()
    |> Multi.update(:comment, Comment.destroy_changeset(comment))
    |> Multi.update_all(:image, where(Image, id: ^comment.image_id), inc: [comments_count: -1])
    |> Repo.transaction()
    |> case do
      {:ok, %{comment: destroyed_comment}} -> {:ok, reindex_comment(destroyed_comment)}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  @doc """
  Builds the blank comment changeset used while assembling an image page.

  This is a cross-context form builder. Authorization of the containing
  image page remains with `Philomena.Images`.

  ## Examples

      iex> new_comment_changeset()
      %Ecto.Changeset{}

  """
  @spec new_comment_changeset() :: Ecto.Changeset.t()
  def new_comment_changeset, do: change_comment(%Comment{})

  @doc """
  Loads a globally addressed comment visible to `actor`.

  IDs are parsed safely. Destroyed comments and missing IDs are not-found. The
  parent image is authorized before the comment, so either forbidden resource
  returns unauthorized.

  ## Examples

      iex> load_comment(actor, "1")
      {:ok, %Comment{}}

      iex> load_comment(actor, "not-a-number")
      {:error, :not_found}

  """
  @spec load_comment(Actor.t(), IntegerId.integer_id()) ::
          {:ok, Comment.t()} | {:error, :unauthorized | :not_found}
  def load_comment(%Actor{} = actor, id), do: load_global_comment(actor, id)

  @doc """
  Searches comments visible to `actor`, applying `filter`, `query_string`, and
  `pagination`, newest first.

  Hidden images, hidden or destroyed comments, and approval states are filtered
  independently through the actor's abilities. A signed-in author may see their
  own unapproved comments. `opts[:preload]` overrides the display associations.

  ## Examples

      iex> search_comments(actor, filter, "created_at.gte:1 week ago", pagination)
      {:ok, %Scrivener.Page{}}

      iex> search_comments(actor, filter, "created_at.gte:not-a-date", pagination)
      {:error, "Cannot parse date."}

  """
  @spec search_comments(
          Actor.t(),
          Filter.t(),
          String.t() | nil,
          Search.pagination_params(),
          keyword()
        ) ::
          {:ok, Scrivener.Page.t(Comment.t())} | {:error, String.t()}
  def search_comments(%Actor{} = actor, %Filter{} = filter, query_string, pagination, opts \\ []) do
    preloads = Keyword.get(opts, :preload, @search_preloads)

    case Query.compile(query_string, actor: actor) do
      {:ok, query} ->
        results =
          actor
          |> comment_search_definition(filter, query, pagination: pagination)
          |> Search.search_records(preload(Comment, ^preloads))

        {:ok, results}

      {:error, msg} ->
        {:error, msg}
    end
  end

  @doc """
  Builds an unexecuted comment search definition for `actor`.

  `show_hidden: false` forces public visibility even for privileged actors.

  ## Examples

      iex> comment_search_definition(actor, filter, %{term: %{author_id: 1}})
      %{module: Comment, ...}

  """
  @spec comment_search_definition(Actor.t(), Filter.t(), map() | [map()], keyword()) ::
          Search.search_definition()
  def comment_search_definition(%Actor{} = actor, %Filter{} = filter, body, opts \\ []) do
    pagination = Keyword.get(opts, :pagination, %{})
    allow_privileged? = Keyword.get(opts, :show_hidden, true)

    Search.search_definition(
      Comment,
      %{
        query: %{
          bool: %{
            must: body,
            must_not: search_exclusions(actor, filter, allow_privileged?)
          }
        },
        sort: %{created_at: :desc}
      },
      pagination
    )
  end

  @doc """
  Returns a database-paginated page of comments visible beneath `image`.

  Visibility, approval, and destroyed-content filters run before pagination.
  Results use the actor's newest/oldest-first setting.

  ## Examples

      iex> paginate_image_comments(actor, image, page: 1, page_size: 25)
      %Scrivener.Page{}

  """
  @spec paginate_image_comments(Actor.t(), Image.t(), Repo.pagination_params()) ::
          Scrivener.Page.t(Comment.t())
  def paginate_image_comments(%Actor{} = actor, %Image{} = image, pagination) do
    direction = load_direction(actor.user)
    preloads = [:image | @display_preloads]

    actor
    |> visible_image_comments(image)
    |> order_by([{^direction, :created_at}, {^direction, :id}])
    |> preload(^preloads)
    |> Repo.paginate(pagination)
  end

  @doc """
  Locates the visible page containing `comment_id` beneath `image`.

  Missing, malformed, mismatched, or collection-invisible comments are
  not-found. A loaded comment forbidden to the actor is unauthorized.

  ## Examples

      iex> find_comment_page(actor, image, comment.id, page_size: 25)
      {:ok, 3}

  """
  @spec find_comment_page(Actor.t(), Image.t(), IntegerId.integer_id(), Repo.pagination_params()) ::
          {:ok, pos_integer()} | {:error, :unauthorized | :not_found}
  def find_comment_page(%Actor{} = actor, %Image{} = image, comment_id, pagination) do
    with {:ok, comment_id} <- IntegerId.parse(comment_id),
         {:ok, comment} <-
           actor
           |> visible_image_comments(image)
           |> where([comment], comment.id == ^comment_id)
           |> Loader.one_and_authorize(actor, :show) do
      offset =
        actor
        |> visible_image_comments(image)
        |> filter_direction(comment, actor.user)
        |> Repo.aggregate(:count, :id)

      {:ok, div(offset, pagination[:page_size]) + 1}
    else
      :error -> {:error, :not_found}
      error -> error
    end
  end

  @doc """
  Returns the final visible comment page beneath `image` for `actor`.

  ## Examples

      iex> last_comment_page(actor, image, page_size: 25)
      4

  """
  @spec last_comment_page(Actor.t(), Image.t(), Repo.pagination_params()) :: pos_integer()
  def last_comment_page(%Actor{} = actor, %Image{} = image, pagination) do
    count =
      actor
      |> visible_image_comments(image)
      |> Repo.aggregate(:count)

    max(Integer.ceil_div(count, pagination[:page_size]), 1)
  end

  @doc """
  Loads and authorizes an image for a comment controller action.

  Duplicate images are resolved to their target. Missing IDs are
  always not-found.

  ## Examples

      iex> load_commentable_image(actor, "1", :index)
      {:ok, %Image{}}

      iex> load_commentable_image(actor, "not-a-number", :show)
      {:error, :not_found}

  """
  @spec load_commentable_image(Actor.t(), IntegerId.integer_id(), atom()) ::
          {:ok, Image.t()} | {:error, :unauthorized | :not_found}
  def load_commentable_image(%Actor{} = actor, image_id, action) do
    load_commentable_image_for_action(actor, image_id, action)
  end

  @doc """
  Creates a comment beneath an authorized `image` on behalf of `actor`.

  Write access, image commenting permission, the Images-owned forced-filter
  prerequisite, and the 15-second creation limit are checked before insertion.
  The transaction updates the image count, notification, and subscription state.
  Indexing, statistics/reporting, rate tracking, and the firehose broadcast run
  after commit.

  ## Examples

      iex> create_comment(actor, image, %{"body" => "Hi"})
      {:ok, %Comment{}}

      iex> create_comment(banned_actor, image, %{"body" => "Hi"})
      {:error, :ban}

  """
  @spec create_comment(Actor.t(), Image.t(), map()) ::
          {:ok, Comment.t()}
          | {:error, :creation_failed | :ban | :unauthorized | :forced_filter | :rate_limited}
  def create_comment(%Actor{} = actor, %Image{} = image, params) do
    with :ok <- verify_write_access(actor),
         :ok <- authorize(actor, :create_comment, image),
         :ok <- Images.verify_forced_filter_access(actor, image),
         :ok <- RateLimiter.check_rate_limit(actor, :comment_create) do
      case persist_comment(image, actor, params) do
        {:ok, %{comment: comment}} ->
          reindex_comment(comment)
          Images.reindex_image(image)
          record_comment_creation(actor, comment)
          RateLimiter.record_action(actor, :comment_create, @comment_create_window)
          broadcast_comment("comment:create", comment)
          {:ok, comment}

        _error ->
          {:error, :creation_failed}
      end
    end
  end

  @doc """
  Loads a visible comment beneath an already loaded route image.

  The parent image and scoped comment are independently authorized for `:show`.

  ## Examples

      iex> load_comment_for_show(actor, image, "1")
      {:ok, %Comment{}}

      iex> load_comment_for_show(actor, image, "not-a-number")
      {:error, :not_found}

  """
  @spec load_comment_for_show(Actor.t(), Image.t(), IntegerId.integer_id()) ::
          {:ok, Comment.t()} | {:error, :unauthorized | :not_found}
  def load_comment_for_show(%Actor{} = actor, %Image{} = image, comment_id) do
    with :ok <- authorize(actor, :show, image) do
      load_comment_in_image(actor, image, comment_id, :show, @display_preloads)
    end
  end

  @doc """
  Loads an editable comment and changeset beneath `image`.

  Write access is checked before image authorization, forced-filter enforcement,
  and comment authorization, matching the update path exactly.

  ## Examples

      iex> load_comment_for_edit(actor, image, "1")
      {:ok, %CommentForm{}}

      iex> load_comment_for_edit(banned_actor, image, "1")
      {:error, :ban}

  """
  @spec load_comment_for_edit(Actor.t(), Image.t(), IntegerId.integer_id()) ::
          {:ok, CommentForm.t()} | {:error, request_error()}
  def load_comment_for_edit(%Actor{} = actor, %Image{} = image, comment_id) do
    with :ok <- verify_write_access(actor),
         {:ok, comment} <- load_editable_comment(actor, image, comment_id, :edit) do
      {:ok, %CommentForm{comment: comment, changeset: change_comment(comment)}}
    end
  end

  @doc """
  Updates a parent-scoped comment on behalf of `actor`.

  The write-access, parent permission, and forced-filter prerequisites match the
  edit form. A successful transaction records the prior version. Reporting,
  indexing, and the firehose broadcast run after commit. Validation returns a
  `CommentForm` preserving the loaded comment.

  ## Examples

      iex> update_comment(actor, image, "1", %{"body" => "Edited"})
      {:ok, %Comment{}}

      iex> update_comment(actor, image, "1", %{"body" => ""})
      {:error, %CommentForm{}}

  """
  @spec update_comment(Actor.t(), Image.t(), IntegerId.integer_id(), map() | nil) ::
          {:ok, Comment.t()} | {:error, CommentForm.t() | request_error()}
  def update_comment(%Actor{} = actor, %Image{} = image, comment_id, params) do
    with :ok <- verify_write_access(actor),
         {:ok, comment} <- load_editable_comment(actor, image, comment_id, :update) do
      case persist_comment_update(comment, actor, params || %{}) do
        {:ok, %{comment: updated_comment}} ->
          report_non_approved(updated_comment)
          reindex_comment(updated_comment)
          broadcast_comment("comment:update", updated_comment)
          {:ok, updated_comment}

        {:error, :comment, changeset, _changes} ->
          {:error, %CommentForm{comment: comment, changeset: changeset}}
      end
    end
  end

  @doc """
  Loads a visible comment's edit history through its route image.

  Parent and child IDs are parsed and scoped before authorization. The returned
  `CommentHistory` carries the latest 25 versions with authors and diffs.

  ## Examples

      iex> comment_history(actor, "1", "2")
      {:ok, %CommentHistory{}}

      iex> comment_history(actor, "1", "not-a-number")
      {:error, :not_found}

  """
  @spec comment_history(Actor.t(), IntegerId.integer_id(), IntegerId.integer_id()) ::
          {:ok, CommentHistory.t()} | {:error, :unauthorized | :not_found}
  def comment_history(%Actor{} = actor, image_id, comment_id) do
    with {:ok, {image, comment}} <-
           load_image_comment(actor, image_id, comment_id, :show, [], @display_preloads) do
      {:ok,
       %CommentHistory{
         image: image,
         comment: comment,
         versions: Versions.for_comment(comment)
       }}
    end
  end

  @doc """
  Loads a comment as a report target through its route image.

  Both resources are authorized for `:show`. Malformed, missing, and mismatched
  IDs are not-found. Reports owns the write prerequisite and form changeset.

  ## Examples

      iex> load_report_target(actor, "1", "2")
      {:ok, %Comment{}}

  """
  @spec load_report_target(Actor.t(), IntegerId.integer_id(), IntegerId.integer_id()) ::
          {:ok, Comment.t()} | {:error, :unauthorized | :not_found}
  def load_report_target(%Actor{} = actor, image_id, comment_id) do
    with {:ok, {_image, comment}} <-
           load_image_comment(
             actor,
             image_id,
             comment_id,
             :show,
             [:sources, tags: :aliases],
             @display_preloads
           ) do
      {:ok, comment}
    end
  end

  @doc """
  Hides a comment scoped beneath `image_id`.

  The comment update, report closure, and moderation log commit atomically.
  Report and comment indexing run after commit.

  ## Examples

      iex> hide_comment(moderator, "1", "2", %{"deletion_reason" => "Spam"})
      {:ok, %Comment{}}

  """
  @spec hide_comment(Actor.t(), IntegerId.integer_id(), IntegerId.integer_id(), map()) ::
          {:ok, Comment.t()} | {:error, request_error() | Ecto.Changeset.t()}
  def hide_comment(%Actor{user: user} = actor, image_id, comment_id, params) do
    with {:ok, {_image, comment}} <-
           load_image_comment(actor, image_id, comment_id, :hide, [], @display_preloads) do
      changeset = Comment.hide_changeset(comment, params, user)
      reason = Ecto.Changeset.get_field(changeset, :deletion_reason)

      Multi.new()
      |> Multi.update(:comment, changeset)
      |> Reports.put_close_reports(:reports, user, comment_id: comment.id)
      |> ModerationLogs.put_log(
        :moderation_log,
        actor,
        "Image.Comment.Hide:create",
        Paths.image_comment_path(comment.image_id, comment.id),
        "Deleted comment on image #{comment.image_id} (#{reason})"
      )
      |> Repo.transact()
      |> case do
        {:ok, %{comment: comment, reports: {_count, report_ids}}} ->
          Reports.reindex_closed_reports(report_ids)
          reindex_comment(comment)

          {:ok, comment}

        {:error, _step, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Restores a comment scoped beneath `image_id`.

  The restore and moderation log commit together. Indexing runs after commit.

  ## Examples

      iex> unhide_comment(moderator, "1", "2")
      {:ok, %Comment{}}

  """
  @spec unhide_comment(Actor.t(), IntegerId.integer_id(), IntegerId.integer_id()) ::
          {:ok, Comment.t()} | {:error, request_error() | Ecto.Changeset.t()}
  def unhide_comment(%Actor{} = actor, image_id, comment_id) do
    with {:ok, {_image, comment}} <-
           load_image_comment(actor, image_id, comment_id, :hide, [], @display_preloads) do
      changeset = Comment.unhide_changeset(comment)

      Multi.new()
      |> Multi.update(:comment, changeset)
      |> ModerationLogs.put_log(
        :moderation_log,
        actor,
        "Image.Comment.Hide:delete",
        Paths.image_comment_path(comment.image_id, comment.id),
        "Restored comment on image #{comment.image_id}"
      )
      |> Repo.transact()
      |> case do
        {:ok, %{comment: comment}} ->
          reindex_comment(comment)

          {:ok, comment}

        {:error, _step, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Destroys a comment's content beneath `image_id`.

  Authorization uses the distinct `:delete` action. Content removal, image
  counters, and the moderation log commit together. Indexing runs after commit.

  ## Examples

      iex> destroy_comment(moderator, "1", "2")
      {:ok, %Comment{}}

  """
  @spec destroy_comment(Actor.t(), IntegerId.integer_id(), IntegerId.integer_id()) ::
          {:ok, Comment.t()} | {:error, request_error() | Ecto.Changeset.t()}
  def destroy_comment(%Actor{} = actor, image_id, comment_id) do
    with {:ok, {_image, comment}} <-
           load_image_comment(actor, image_id, comment_id, :delete, [], @display_preloads) do
      comment_query = from(c in Comment, where: c.id == ^comment.id, lock: "FOR UPDATE")
      image_query = from(i in Image, where: i.id == ^comment.image_id)

      Multi.new()
      |> Multi.one(:locked_comment, comment_query)
      |> Multi.update(:comment, fn %{locked_comment: comment} ->
        Comment.destroy_changeset(comment)
      end)
      |> Multi.update_all(:image, image_query, inc: [comments_count: -1])
      |> ModerationLogs.put_log(
        :moderation_log,
        actor,
        "Image.Comment.Delete:create",
        Paths.image_comment_path(comment.image_id, comment.id),
        "Destroyed comment on image #{comment.image_id}"
      )
      |> Repo.transact()
      |> case do
        {:ok, %{comment: comment}} ->
          UserStatistics.increment(comment.user_id, :comments_count, -1)
          reindex_comment(comment)

          {:ok, comment}

        {:error, _step, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Approves a comment scoped beneath `image_id`.

  Approval, report closure, author statistics, and the moderation log commit
  together.

  ## Examples

      iex> approve_comment(moderator, "1", "2")
      {:ok, %Comment{}}

  """
  @spec approve_comment(Actor.t(), IntegerId.integer_id(), IntegerId.integer_id()) ::
          {:ok, Comment.t()} | {:error, request_error() | Ecto.Changeset.t()}
  def approve_comment(%Actor{user: user} = actor, image_id, comment_id) do
    with {:ok, {_image, comment}} <-
           load_image_comment(actor, image_id, comment_id, :approve, [], @display_preloads) do
      comment_query = from(c in Comment, where: c.id == ^comment.id, lock: "FOR UPDATE")

      Multi.new()
      |> Multi.one(:locked_comment, comment_query)
      |> Multi.update(:comment, fn %{locked_comment: comment} ->
        Comment.approve_changeset(comment)
      end)
      |> Reports.put_close_reports(:reports, user, comment_id: comment.id)
      |> ModerationLogs.put_log(
        :moderation_log,
        actor,
        "Image.Comment.Approve:create",
        Paths.image_comment_path(comment.image_id, comment.id),
        "Approved comment on image #{comment.image_id}"
      )
      |> Repo.transact()
      |> case do
        {:ok, %{comment: comment, reports: {_count, report_ids}}} ->
          UserStatistics.increment(comment.user_id, :comments_count)
          Reports.reindex_closed_reports(report_ids)
          reindex_comment(comment)

          {:ok, comment}

        {:error, _step, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Hides and destroys an already loaded user comment for account erasure.

  This internal function does not perform any request authorization. It
  closes reports and updates counters in one transaction, then reindexes
  after commit.

  ## Examples

      iex> erase_user_comment(comment, moderator)
      {:ok, %Comment{destroyed_content: true}}

  """
  @spec erase_user_comment(Comment.t(), User.t()) ::
          {:ok, Comment.t()} | {:error, Ecto.Changeset.t() | term()}
  def erase_user_comment(%Comment{} = comment, %User{} = moderator) do
    comment_query = from(c in Comment, where: c.id == ^comment.id, lock: "FOR UPDATE")
    image_query = from(i in Image, where: i.id == ^comment.image_id)

    Multi.new()
    |> Multi.one(:locked_comment, comment_query)
    |> Multi.update(:comment, fn %{locked_comment: comment} ->
      comment
      |> Comment.hide_changeset(%{deletion_reason: "Site abuse"}, moderator)
      |> Comment.destroy_changeset()
    end)
    |> Multi.update_all(:image, image_query, inc: [comments_count: -1])
    |> Reports.put_close_reports(:reports, moderator, comment_id: comment.id)
    |> Repo.transact()
    |> case do
      {:ok, %{comment: comment, reports: {_count, report_ids}}} ->
        UserStatistics.increment(comment.user_id, :comments_count, -1)
        Reports.reindex_closed_reports(report_ids)
        reindex_comment(comment)

        {:ok, comment}

      {:error, :comment, %{errors: [destroyed_content: {"has already been destroyed", []}]},
       _changes} ->
        # Skips all of the above if the comment was already destroyed.
        # This is the only expected error.
        {:ok, comment}

      error ->
        error
    end
  end

  @doc """
  Moves all comments from a duplicate image to its target and reindexes them.

  This internal function returns the target image for use in the owning Images
  pipeline.

  ## Examples

      iex> migrate_comments(source_image, target_image)
      %Image{}

  """
  @spec migrate_comments(Image.t(), Image.t()) :: Image.t()
  def migrate_comments(%Image{} = image, %Image{} = duplicate_of_image) do
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
  Updates indexed comment author names after a user rename.

  ## Examples

      iex> user_name_reindex("old_username", "new_username")
      :ok

  """
  @spec user_name_reindex(String.t(), String.t()) :: term()
  def user_name_reindex(old_name, new_name) do
    data = Comments.SearchIndex.user_name_update_by_query(old_name, new_name)
    Search.update_by_query(Comment, data.query, data.set_replacements, data.replacements)
  end

  @doc """
  Queues one comment for search indexing and returns it unchanged.

  ## Examples

      iex> reindex_comment(comment)
      %Comment{}

  """
  @spec reindex_comment(Comment.t()) :: Comment.t()
  def reindex_comment(%Comment{} = comment) do
    Exq.enqueue(Exq, "indexing", IndexWorker, ["Comments", "id", [comment.id]])
    comment
  end

  @doc """
  Queues every comment on `image` for indexing and returns the image unchanged.

  ## Examples

      iex> reindex_comments_on_image(image)
      %Image{}

  """
  @spec reindex_comments_on_image(Image.t()) :: Image.t()
  def reindex_comments_on_image(%Image{} = image) do
    Exq.enqueue(Exq, "indexing", IndexWorker, ["Comments", "image_id", [image.id]])
    image
  end

  @doc """
  Queues comments on the given image IDs for reindexing and returns the list unchanged.

  ## Examples

      iex> reindex_comments_on_images([1, 2, 3])
      [1, 2, 3]

  """
  @spec reindex_comments_on_images([integer()]) :: [integer()]
  def reindex_comments_on_images(image_ids) when is_list(image_ids) do
    Exq.enqueue(Exq, "indexing", IndexWorker, ["Comments", "image_id", image_ids])
    image_ids
  end

  @doc """
  Returns the association queries required to serialize comment search records.

  ## Examples

      iex> indexing_preloads()
      [user: user_query, image: image_query, deleted_by: user_query]

  """
  @spec indexing_preloads() :: list()
  def indexing_preloads do
    user_query = select(User, [user], map(user, [:id, :name]))
    tag_query = select(Tag, [tag], map(tag, [:id, :name]))

    image_query =
      Image
      |> select([image], struct(image, [:approved, :hidden_from_users, :id]))
      |> preload(tags: ^tag_query)

    [user: user_query, image: image_query, deleted_by: user_query]
  end

  @doc """
  Reindexes comments selected by a trusted worker column and values.

  ## Examples

      iex> perform_reindex(:id, [1, 2, 3])
      :ok

  """
  @spec perform_reindex(atom(), [term()]) :: term()
  def perform_reindex(column, condition) when is_atom(column) and is_list(condition) do
    Comment
    |> preload(^indexing_preloads())
    |> where([comment], field(comment, ^column) in ^condition)
    |> Search.reindex(Comment)
  end
end
