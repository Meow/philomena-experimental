defmodule Philomena.Users.Eraser do
  import Ecto.Query
  alias Philomena.Repo

  alias Philomena.Attribution.Actor
  alias Philomena.Bans
  alias Philomena.Comments.Comment
  alias Philomena.Comments
  alias Philomena.Galleries
  alias Philomena.Posts.Post
  alias Philomena.Posts
  alias Philomena.Topics.Topic
  alias Philomena.Topics
  alias Philomena.Images
  alias Philomena.SourceChanges.SourceChange
  alias Philomena.SourceChanges
  alias Philomena.Reports
  alias Philomena.Users
  alias Philomena.Multi

  @reason "Site abuse"
  @wipe_ip %Postgrex.INET{address: {127, 0, 1, 1}, netmask: 32}
  @wipe_fp "ffff"

  def erase_permanently!(user, moderator) do
    # Erase avatar
    {:ok, user} = Users.clear_avatar_for_erasure(user)

    # Erase "about me" and personal title
    {:ok, user} = Users.clear_profile_for_erasure(user)

    # Delete all forum posts
    Post
    |> where(user_id: ^user.id)
    |> preload(topic: :forum)
    |> Repo.all()
    |> Enum.each(fn post ->
      {:ok, _post} = Posts.erase_post(post, moderator)
    end)

    # Delete all comments
    Comment
    |> where(user_id: ^user.id)
    |> Repo.all()
    |> Enum.each(fn comment ->
      {:ok, _comment} = Comments.erase_user_comment(comment, moderator)
    end)

    # Delete all galleries
    {:ok, _gallery_count} = Galleries.erase_user_galleries(user, moderator)

    # Delete all posted topics
    Topic
    |> where(user_id: ^user.id)
    |> preload(:forum)
    |> Repo.all()
    |> Enum.each(fn topic ->
      {:ok, _topic} = Topics.erase_topic(topic, moderator)
    end)

    # Revert all source changes
    SourceChange
    |> where(user_id: ^user.id)
    |> order_by(desc: :created_at)
    |> preload(:image)
    |> Repo.all()
    |> Enum.each(fn source_change ->
      if source_change.added do
        revert_added_source_change(source_change, user)
      else
        revert_removed_source_change(source_change, user)
      end
    end)

    # Delete all source changes
    SourceChanges.delete_for_user!(user.id)

    # Ban the user
    {:ok, _ban} =
      Bans.create_system_user_ban(
        moderator,
        user.id,
        %{
          "reason" => @reason,
          "valid_until" => "permanent"
        }
      )

    # Close all reports against the user
    {:ok, _changes} =
      Multi.new()
      |> Reports.put_close_reports(:close_reports, moderator, reported_user_id: user.id)
      |> Multi.transact()

    # We succeeded
    :ok
  end

  defp revert_removed_source_change(source_change, user) do
    old_sources = %{}
    new_sources = %{"0" => %{"source" => source_change.source_url}}

    revert_source_change(source_change, user, old_sources, new_sources)
  end

  defp revert_added_source_change(source_change, user) do
    old_sources = %{"0" => %{"source" => source_change.source_url}}
    new_sources = %{}

    revert_source_change(source_change, user, old_sources, new_sources)
  end

  defp revert_source_change(source_change, user, old_sources, new_sources) do
    attrs = %{"old_sources" => old_sources, "sources" => new_sources}

    actor = %Actor{
      user: user,
      ip: @wipe_ip,
      fingerprint: @wipe_fp
    }

    {:ok, _} = Images.revert_source_change_for_erasure(source_change.image, actor, attrs)
  end
end
