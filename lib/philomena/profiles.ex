defmodule Philomena.Profiles do
  @moduledoc """
  Assembly of the data behind a user's profile page and its admin-only IP and
  fingerprint histories, scoped to the viewer.
  """

  import Ecto.Query, warn: false

  import Philomena.Authorization, only: [authorize: 3]

  alias Philomena.Repo
  alias Philomena.Attribution.Actor
  alias Philomena.Profiles.ProfilePage
  alias Philomena.Users.User
  alias Philomena.UserIps.UserIp
  alias Philomena.UserFingerprints.UserFingerprint
  alias Philomena.UserStatistics.UserStatistic
  alias Philomena.UserNameChanges.UserNameChange
  alias Philomena.ModNotes
  alias Philomena.ModNotes.ModNote
  alias Philomena.Bans
  alias Philomena.Comments
  alias Philomena.Comments.Comment
  alias Philomena.Posts.Post
  alias Philomena.Galleries.Gallery
  alias Philomena.Images.Image
  alias Philomena.Images.Search, as: ImageSearch
  alias Philomena.Images.Search.Scope
  alias Philomena.Interactions
  alias Philomena.Filters.Filter
  alias Philomena.Tags.Tag
  alias PhilomenaQuery.Search

  @profile_preloads [
    :forced_filter,
    awards: [:badge, :awarded_by],
    public_links: :tag,
    verified_links: :tag,
    commission: [
      sheet_image: [:sources, tags: :aliases],
      items: [example_image: [:sources, tags: :aliases]]
    ]
  ]

  @doc """
  Assembles the public profile page of the user named by `slug`, for the viewer
  described by `scope`.

  The user is loaded by slug and authorized for `:show`.
  `current_filter` is the viewer's active `Filter`, whose hidden
  tags scope the recent comments strip. The recent uploads, faves, artwork,
  comments, and posts strips are batched into a single multi-search; posts and
  comments the viewer may not see are dropped afterward. Descriptions and
  commission text are carried raw for the caller to process.

  Returns `{:ok, %ProfilePage{}}`.
  """
  @spec load_profile_page(Scope.t(), Filter.t(), String.t()) ::
          {:ok, ProfilePage.t()} | {:error, :unauthorized | :not_found}
  def load_profile_page(%Scope{} = scope, %Filter{} = current_filter, slug) do
    user =
      User
      |> where(slug: ^slug)
      |> preload(^@profile_preloads)
      |> Repo.one()

    with :ok <- authorize(scope.user, :show, user),
         %User{} <- user do
      {:ok, assemble_profile_page(scope, current_filter, user)}
    else
      {:error, :unauthorized} -> {:error, :unauthorized}
      nil -> {:error, :not_found}
    end
  end

  defp assemble_profile_page(scope, current_filter, user) do
    viewer = scope.user

    {:ok, {recent_uploads_def, _tags}} =
      ImageSearch.search_string(scope, "uploader_id:#{user.id}",
        pagination: %{page_number: 1, page_size: 4}
      )

    {:ok, {recent_faves_def, _tags}} =
      ImageSearch.search_string(scope, "faved_by_id:#{user.id}",
        pagination: %{page_number: 1, page_size: 4}
      )

    tags = link_tags(user.public_links)

    verified_tag_ids =
      user.verified_links
      |> link_tags()
      |> Enum.map(& &1.id)

    recent_artwork_def = recent_artwork_definition(scope, tags)

    recent_comments_def =
      Comments.comment_search_definition(
        viewer,
        current_filter,
        [
          %{term: %{author_id: user.id}},
          %{term: %{hidden_from_users: false}}
        ],
        pagination: %{page_size: 3},
        show_hidden: false
      )

    recent_posts_def =
      Search.search_definition(
        Post,
        %{
          query: %{
            bool: %{
              must: [
                %{term: %{author_id: user.id}},
                %{term: %{hidden_from_users: false}},
                %{term: %{access_level: "normal"}}
              ]
            }
          },
          sort: %{created_at: :desc}
        },
        %{page_size: 6}
      )

    [recent_uploads, recent_faves, recent_artwork, recent_comments, recent_posts] =
      Search.msearch_records(
        [
          recent_uploads_def,
          recent_faves_def,
          recent_artwork_def,
          recent_comments_def,
          recent_posts_def
        ],
        [
          preload(Image, [:sources, tags: :aliases]),
          preload(Image, [:sources, tags: :aliases]),
          preload(Image, [:sources, tags: :aliases]),
          preload(Comment, [
            :deleted_by,
            user: [awards: :badge],
            image: [:sources, tags: :aliases]
          ]),
          preload(Post, [:deleted_by, user: [awards: :badge], topic: :forum])
        ]
      )

    recent_posts = Enum.filter(recent_posts, &Canada.Can.can?(viewer, :show, &1.topic))
    recent_comments = Enum.filter(recent_comments, &Canada.Can.can?(viewer, :show, &1.image))

    recent_galleries =
      Gallery
      |> where(user_id: ^user.id, anonymous: false)
      |> preload(thumbnail: [:sources, tags: :aliases])
      |> limit(4)
      |> Repo.all()

    interactions =
      Interactions.user_interactions([recent_uploads, recent_faves, recent_artwork], viewer)

    %ProfilePage{
      user: user,
      recent_uploads: recent_uploads,
      recent_faves: recent_faves,
      recent_artwork: recent_artwork,
      recent_comments: recent_comments,
      recent_posts: recent_posts,
      recent_galleries: recent_galleries,
      statistics: calculate_statistics(user),
      watcher_counts: watcher_counts(verified_tag_ids),
      tags: tags,
      interactions: interactions,
      bans: user_bans(user)
    }
  end

  defp recent_artwork_definition(_scope, []) do
    Search.search_definition(Image, %{query: %{match_none: %{}}})
  end

  defp recent_artwork_definition(scope, tags) do
    {definition, _tags} =
      ImageSearch.query(scope, %{terms: %{tag_ids: Enum.map(tags, & &1.id)}},
        pagination: %{page_number: 1, page_size: 4}
      )

    definition
  end

  defp link_tags([]), do: []
  defp link_tags(links), do: links |> Enum.map(& &1.tag) |> Enum.reject(&is_nil/1)

  defp watcher_counts(tag_ids) do
    Tag
    |> where([t], t.id in ^tag_ids)
    |> join(
      :inner_lateral,
      [t],
      _ in fragment("SELECT count(*) FROM users WHERE watched_tag_ids @> ARRAY[?]", t.id),
      on: true
    )
    |> select([t, c], {t.id, c.count})
    |> Repo.all()
    |> Map.new()
  end

  defp user_bans(user) do
    Bans.User
    |> where(user_id: ^user.id)
    |> order_by(desc: :created_at)
    |> Repo.all()
  end

  defp calculate_statistics(user) do
    today = Date.utc_today()

    last_90 =
      UserStatistic
      |> where(user_id: ^user.id)
      |> where([us], us.day >= ^Date.add(today, -89))
      |> Repo.all()
      |> Map.new(&{Date.diff(today, &1.day), &1})

    %{
      images_count: individual_stat(last_90, :images_count),
      image_faves_count: individual_stat(last_90, :image_faves_count),
      comments_count: individual_stat(last_90, :comments_count),
      image_votes_count: individual_stat(last_90, :image_votes_count),
      metadata_updates_count: individual_stat(last_90, :metadata_updates_count),
      posts_count: individual_stat(last_90, :posts_count)
    }
  end

  defp individual_stat(mapping, stat_name) do
    Enum.map(89..0//-1, &(map_fetch(mapping[&1], stat_name) || 0))
  end

  defp map_fetch(nil, _field_name), do: nil
  defp map_fetch(map, field_name), do: Map.get(map, field_name)

  @doc """
  Returns the admin metadata about `user` for `actor`, or `nil` when the viewer
  may not list users.

  The metadata is the user's current filter and the most recent IP and
  fingerprint rows.

  ## Examples

      iex> admin_metadata(admin, user)
      %{
        filter: %Filter{},
        last_ip: %UserIp{},
        last_fp: %UserFingerprint{}
      }

  """
  @spec admin_metadata(Actor.t(), User.t()) :: map() | nil
  def admin_metadata(%Actor{} = actor, user) do
    # TODO: this should have a struct definition for its return
    # TODO: "fp" should be spelled out as "fingerprint"

    if Canada.Can.can?(actor.user, :index, User) and
         Canada.Can.can?(actor.user, :show, :identity_metadata) do
      user = Repo.preload(user, [:current_filter])

      last_ip =
        UserIp
        |> where(user_id: ^user.id)
        |> order_by(desc: :updated_at)
        |> limit(1)
        |> Repo.one()

      last_fp =
        UserFingerprint
        |> where(user_id: ^user.id)
        |> order_by(desc: :updated_at)
        |> limit(1)
        |> Repo.one()

      %{filter: user.current_filter, last_ip: last_ip, last_fp: last_fp}
    end
  end

  @doc """
  Returns the mod notes on `user` for `actor`, processed through `collection_renderer`,
  or `nil` when the viewer may not read mod notes.
  """
  @spec mod_notes(Actor.t(), User.t(), (list() -> list())) :: list() | nil
  def mod_notes(%Actor{} = actor, user, collection_renderer) do
    if Canada.Can.can?(actor.user, :index, ModNote) do
      ModNotes.list_all_mod_notes_for_target(collection_renderer, user_id: user.id)
    end
  end

  @doc """
  Returns the name changes of `user` for `actor`, or `nil` when the viewer may
  not see them.
  """
  @spec name_changes(Actor.t(), User.t()) :: [UserNameChange.t()] | nil
  def name_changes(%Actor{} = actor, user) do
    if Canada.Can.can?(actor.user, :index, UserNameChange) do
      UserNameChange
      |> where(user_id: ^user.id)
      |> order_by(desc: :id)
      |> Repo.all()
    end
  end

  @doc """
  Loads the IP history of the user named by the profile `slug`, on behalf of
  `actor`: every IP address the user has been seen on, and the other users seen
  on those same addresses.

  The user is loaded by slug and authorized for `:show_details`.

  ## Examples

      iex> load_ip_history(moderator, slug)
      {:ok, %{
          user: %User{},
          user_ips: [%UserIp{}, ...],
          other_users: %{
            ip => [%UserIp{}, ...]
          }
        }}

  """
  @spec load_ip_history(Actor.t(), String.t()) ::
          {:ok, map()} | {:error, :unauthorized | :not_found}
  def load_ip_history(%Actor{} = actor, slug) do
    # TODO: this should have a struct definition for its return
    with {:ok, user} <- load_detailed_profile(actor, slug) do
      user_ips =
        UserIp
        |> where(user_id: ^user.id)
        |> preload(:user)
        |> order_by(desc: :updated_at)
        |> Repo.all()

      distinct_ips =
        user_ips
        |> Enum.map(& &1.ip)
        |> Enum.uniq()

      other_users =
        UserIp
        |> where([u], u.ip in ^distinct_ips)
        |> preload(:user)
        |> order_by(desc: :updated_at)
        |> Repo.all()
        |> Enum.group_by(& &1.ip)

      {:ok, %{user: user, user_ips: user_ips, other_users: other_users}}
    end
  end

  @doc """
  Loads the fingerprint history of the user named by the profile `slug`, on
  behalf of `actor`: every fingerprint the user has been seen with, and the
  other users seen with those same fingerprints.

  The user is loaded by slug and authorized for `:show_details`.

  ## Examples

      iex> load_fp_history(moderator, slug)
      {:ok, %{
          user: %User{},
          user_fps: [%UserFingerprint{}, ...],
          other_users: %{
            fingerprint => [%UserFingerprint{}, ...]
          }
        }}

  """
  @spec load_fp_history(Actor.t(), String.t()) ::
          {:ok, map()} | {:error, :unauthorized | :not_found}
  def load_fp_history(%Actor{} = actor, slug) do
    # TODO: this should have a struct definition for its return
    # TODO: "fp" should be spelled out as "fingerprint"
    with {:ok, user} <- load_detailed_profile(actor, slug) do
      user_fps =
        UserFingerprint
        |> where(user_id: ^user.id)
        |> preload(:user)
        |> order_by(desc: :updated_at)
        |> Repo.all()

      distinct_fps =
        user_fps
        |> Enum.map(& &1.fingerprint)
        |> Enum.uniq()

      other_users =
        UserFingerprint
        |> where([u], u.fingerprint in ^distinct_fps)
        |> preload(:user)
        |> order_by(desc: :updated_at)
        |> Repo.all()
        |> Enum.group_by(& &1.fingerprint)

      {:ok, %{user: user, user_fps: user_fps, other_users: other_users}}
    end
  end

  # Loads a user by profile slug and authorizes the viewer for `:show_details`.
  defp load_detailed_profile(actor, slug) do
    user = Repo.get_by(User, slug: slug)

    with %User{} <- user,
         :ok <- authorize(actor, :show, :identity_metadata),
         :ok <- authorize(actor, :show_details, user) do
      {:ok, user}
    else
      {:error, :unauthorized} -> {:error, :unauthorized}
      nil -> {:error, :not_found}
    end
  end
end
