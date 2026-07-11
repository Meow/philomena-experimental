defmodule Philomena.ForumsTest do
  @moduledoc """
  Context-level tests for the actor-first forum subscription API on
  `Philomena.Forums`: `subscribe/2` and `unsubscribe/2`.

  These pin the authorization matrix (anonymous / user / moderator / admin),
  the unknown-forum divergence between the two actions, and the idempotent
  success paths. The corresponding controller characterization tests pin the
  HTTP behavior on top of these results.

  The actor here is a plain `User.t()` or `nil`, matching what the controller
  hands in as `conn.assigns.current_user`. Unlike the topic API, the forum
  functions load only a forum by short name, so there is no separate
  not-found surface: a missing forum is authorized as a `nil` subject.
  """

  use Philomena.DataCase, async: true

  import Ecto.Query

  import Philomena.ForumsFixtures
  import Philomena.UsersFixtures

  alias Philomena.Repo
  alias Philomena.Forums
  alias Philomena.Forums.Subscription

  defp subscribed?(forum, user) do
    Repo.exists?(
      from s in Subscription,
        where: s.forum_id == ^forum.id and s.user_id == ^user.id
    )
  end

  defp subscription_count(forum, user) do
    Repo.aggregate(
      from(s in Subscription, where: s.forum_id == ^forum.id and s.user_id == ^user.id),
      :count
    )
  end

  describe "subscribe/2" do
    test "a regular user subscribes to a visible forum and the row is created" do
      user = confirmed_user_fixture()
      forum = forum_fixture()

      assert {:ok, loaded_forum} = Forums.subscribe(user, forum.short_name)

      assert loaded_forum.id == forum.id
      assert subscribed?(forum, user)
    end

    test "subscribing twice is idempotent and leaves a single row" do
      # create_subscription inserts with on_conflict: :nothing, so a repeat is a
      # successful no-op rather than a changeset error.
      user = confirmed_user_fixture()
      forum = forum_fixture()

      assert {:ok, _} = Forums.subscribe(user, forum.short_name)
      assert {:ok, _} = Forums.subscribe(user, forum.short_name)

      assert subscription_count(forum, user) == 1
    end

    test "a moderator subscribes to a visible forum" do
      moderator = moderator_user_fixture()
      forum = forum_fixture()

      assert {:ok, loaded_forum} = Forums.subscribe(moderator, forum.short_name)
      assert loaded_forum.id == forum.id
      assert subscribed?(forum, moderator)
    end

    test "an admin subscribes to a visible forum" do
      admin = admin_user_fixture()
      forum = forum_fixture()

      assert {:ok, _forum} = Forums.subscribe(admin, forum.short_name)
      assert subscribed?(forum, admin)
    end

    test "an unknown forum slug is unauthorized for a regular user" do
      # The retired plug loaded the forum by short name and authorized the nil
      # result for :show, which no ordinary rule permits.
      assert Forums.subscribe(confirmed_user_fixture(), "nonexistent") ==
               {:error, :unauthorized}
    end

    test "an unknown forum slug is unauthorized for anonymous" do
      assert Forums.subscribe(nil, "nonexistent") == {:error, :unauthorized}
    end

    test "a restricted forum is unauthorized for a regular user and no row is created" do
      user = confirmed_user_fixture()
      forum = forum_fixture(access_level: "staff")

      assert Forums.subscribe(user, forum.short_name) == {:error, :unauthorized}
      refute subscribed?(forum, user)
    end

    test "a restricted forum is subscribable by a moderator" do
      moderator = moderator_user_fixture()
      forum = forum_fixture(access_level: "staff")

      assert {:ok, _forum} = Forums.subscribe(moderator, forum.short_name)
      assert subscribed?(forum, moderator)
    end

    test "anonymous reaching a visible forum crashes on the nil actor" do
      # NOTE: nothing in subscribe/2 denies anonymous for a normal, publicly
      # readable forum; the only guard against it is the controller's
      # require_authenticated_user plug. At the context level a nil actor that
      # clears forum :show reaches create_subscription, which dereferences
      # actor.id and raises BadMapError.
      forum = forum_fixture()

      assert_raise BadMapError, ~r/expected a map, got:/, fn ->
        Forums.subscribe(nil, forum.short_name)
      end
    end

    test "an admin with an unknown forum crashes rather than reporting unauthorized" do
      # NOTE: the admin blanket rule authorizes :show on the nil forum load, so
      # the divergence the other actors get (unauthorized) is skipped and
      # create_subscription then dereferences the nil forum, raising BadMapError.
      assert_raise BadMapError, ~r/expected a map, got:/, fn ->
        Forums.subscribe(admin_user_fixture(), "nonexistent")
      end
    end
  end

  describe "unsubscribe/2" do
    test "a regular user unsubscribes from a visible forum and the row is removed" do
      user = confirmed_user_fixture()
      forum = forum_fixture()
      {:ok, _} = Forums.create_subscription(forum, user)
      assert subscribed?(forum, user)

      assert {:ok, loaded_forum} = Forums.unsubscribe(user, forum.short_name)

      assert loaded_forum.id == forum.id
      refute subscribed?(forum, user)
    end

    test "unsubscribing with no existing subscription still succeeds" do
      # delete_subscription runs an unconditional delete_all and hard-matches
      # {:ok, _}, so the absence of a row is not an error.
      user = confirmed_user_fixture()
      forum = forum_fixture()
      refute subscribed?(forum, user)

      assert {:ok, _forum} = Forums.unsubscribe(user, forum.short_name)
      refute subscribed?(forum, user)
    end

    test "a moderator unsubscribes from a visible forum" do
      moderator = moderator_user_fixture()
      forum = forum_fixture()
      {:ok, _} = Forums.create_subscription(forum, moderator)

      assert {:ok, _forum} = Forums.unsubscribe(moderator, forum.short_name)
      refute subscribed?(forum, moderator)
    end

    test "an unknown forum slug is unauthorized for a regular user" do
      assert Forums.unsubscribe(confirmed_user_fixture(), "nonexistent") ==
               {:error, :unauthorized}
    end

    test "a restricted forum is unauthorized for a regular user" do
      user = confirmed_user_fixture()
      forum = forum_fixture(access_level: "staff")

      assert Forums.unsubscribe(user, forum.short_name) == {:error, :unauthorized}
    end
  end
end
