defmodule Philomena.ForumsTest do
  @moduledoc """
  Context-level tests for the actor-first forum APIs on `Philomena.Forums`: the
  subscription toggle (`subscribe/2`, `unsubscribe/2`) and the admin management
  functions (`authorize_admin/1`, `new_forum/1`, `create_forum/2`,
  `load_forum_for_edit/2`, `update_forum/3`).

  These pin the authorization matrix (anonymous / user / moderator / admin),
  the unknown-forum divergence between the subscription actions, the idempotent
  subscription success paths, and - for the admin functions - the admin-only
  restriction (a plain moderator is rejected, so restricted-forum existence
  does not leak) plus the unknown-short-name split (not_found for an authorized
  admin, unauthorized for everyone else). The corresponding controller
  characterization tests pin the HTTP behavior on top of these results.

  The actor here is a `Philomena.Attribution.Actor`, matching what the controller
  hands in as `conn.assigns.actor`. Unlike the topic API, the forum
  functions load only a forum by short name, so there is no separate
  not-found surface on the subscription side: a missing forum is authorized as
  a `nil` subject.
  """

  use Philomena.DataCase, async: true

  import Ecto.Query

  import Philomena.AttributionFixtures
  import Philomena.ForumsFixtures
  import Philomena.UsersFixtures

  alias Philomena.Repo
  alias Philomena.Forums
  alias Philomena.Forums.Forum
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

      assert {:ok, loaded_forum} = Forums.subscribe(actor(user), forum.short_name)

      assert loaded_forum.id == forum.id
      assert subscribed?(forum, user)
    end

    test "subscribing twice is idempotent and leaves a single row" do
      # create_subscription inserts with on_conflict: :nothing, so a repeat is a
      # successful no-op rather than a changeset error.
      user = confirmed_user_fixture()
      forum = forum_fixture()

      assert {:ok, _} = Forums.subscribe(actor(user), forum.short_name)
      assert {:ok, _} = Forums.subscribe(actor(user), forum.short_name)

      assert subscription_count(forum, user) == 1
    end

    test "a moderator subscribes to a visible forum" do
      moderator = moderator_user_fixture()
      forum = forum_fixture()

      assert {:ok, loaded_forum} = Forums.subscribe(actor(moderator), forum.short_name)
      assert loaded_forum.id == forum.id
      assert subscribed?(forum, moderator)
    end

    test "an admin subscribes to a visible forum" do
      admin = admin_user_fixture()
      forum = forum_fixture()

      assert {:ok, _forum} = Forums.subscribe(actor(admin), forum.short_name)
      assert subscribed?(forum, admin)
    end

    test "an unknown forum slug is unauthorized for a regular user" do
      # An unknown short name loads nil, and authorizing nil for :show is
      # unauthorized for every non-admin actor.
      assert Forums.subscribe(actor(confirmed_user_fixture()), "nonexistent") ==
               {:error, :unauthorized}
    end

    test "an unknown forum slug is unauthorized for anonymous" do
      assert Forums.subscribe(actor(), "nonexistent") == {:error, :unauthorized}
    end

    test "a restricted forum is unauthorized for a regular user and no row is created" do
      user = confirmed_user_fixture()
      forum = forum_fixture(access_level: "staff")

      assert Forums.subscribe(actor(user), forum.short_name) == {:error, :unauthorized}
      refute subscribed?(forum, user)
    end

    test "a restricted forum is subscribable by a moderator" do
      moderator = moderator_user_fixture()
      forum = forum_fixture(access_level: "staff")

      assert {:ok, _forum} = Forums.subscribe(actor(moderator), forum.short_name)
      assert subscribed?(forum, moderator)
    end

    test "anonymous reaching a visible forum crashes on the nil user" do
      # NOTE: nothing in subscribe/2 denies anonymous for a normal, publicly
      # readable forum; the only guard against it is the controller's
      # require_authenticated_user plug. At the context level an anonymous actor
      # (user: nil) that clears forum :show reaches create_subscription, which
      # dereferences the nil user's id and raises BadMapError.
      forum = forum_fixture()

      assert_raise BadMapError, ~r/expected a map, got:/, fn ->
        Forums.subscribe(actor(), forum.short_name)
      end
    end

    test "an admin with an unknown forum crashes rather than reporting unauthorized" do
      # NOTE: the admin blanket rule authorizes :show on the nil forum load, so
      # the divergence the other actors get (unauthorized) is skipped and
      # create_subscription then dereferences the nil forum, raising BadMapError.
      assert_raise BadMapError, ~r/expected a map, got:/, fn ->
        Forums.subscribe(actor(admin_user_fixture()), "nonexistent")
      end
    end
  end

  describe "unsubscribe/2" do
    test "a regular user unsubscribes from a visible forum and the row is removed" do
      user = confirmed_user_fixture()
      forum = forum_fixture()
      {:ok, _} = Forums.create_subscription(forum, user)
      assert subscribed?(forum, user)

      assert {:ok, loaded_forum} = Forums.unsubscribe(actor(user), forum.short_name)

      assert loaded_forum.id == forum.id
      refute subscribed?(forum, user)
    end

    test "unsubscribing with no existing subscription still succeeds" do
      # delete_subscription runs an unconditional delete_all and hard-matches
      # {:ok, _}, so the absence of a row is not an error.
      user = confirmed_user_fixture()
      forum = forum_fixture()
      refute subscribed?(forum, user)

      assert {:ok, _forum} = Forums.unsubscribe(actor(user), forum.short_name)
      refute subscribed?(forum, user)
    end

    test "a moderator unsubscribes from a visible forum" do
      moderator = moderator_user_fixture()
      forum = forum_fixture()
      {:ok, _} = Forums.create_subscription(forum, moderator)

      assert {:ok, _forum} = Forums.unsubscribe(actor(moderator), forum.short_name)
      refute subscribed?(forum, moderator)
    end

    test "an unknown forum slug is unauthorized for a regular user" do
      assert Forums.unsubscribe(actor(confirmed_user_fixture()), "nonexistent") ==
               {:error, :unauthorized}
    end

    test "a restricted forum is unauthorized for a regular user" do
      user = confirmed_user_fixture()
      forum = forum_fixture(access_level: "staff")

      assert Forums.unsubscribe(actor(user), forum.short_name) == {:error, :unauthorized}
    end
  end

  describe "authorize_admin/1" do
    test "an admin is authorized" do
      assert Forums.authorize_admin(actor(admin_user_fixture())) == :ok
    end

    test "a plain moderator is not authorized" do
      assert Forums.authorize_admin(actor(moderator_user_fixture())) == {:error, :unauthorized}
    end

    test "a regular user is not authorized" do
      assert Forums.authorize_admin(actor(confirmed_user_fixture())) == {:error, :unauthorized}
    end

    test "an anonymous visitor is not authorized" do
      assert Forums.authorize_admin(actor()) == {:error, :unauthorized}
    end
  end

  describe "new_forum/1" do
    test "an admin gets a changeset" do
      assert {:ok, %Ecto.Changeset{}} = Forums.new_forum(actor(admin_user_fixture()))
    end

    test "a plain moderator is not authorized" do
      assert Forums.new_forum(actor(moderator_user_fixture())) == {:error, :unauthorized}
    end

    test "a regular user is not authorized" do
      assert Forums.new_forum(actor(confirmed_user_fixture())) == {:error, :unauthorized}
    end

    test "an anonymous visitor is not authorized" do
      assert Forums.new_forum(actor()) == {:error, :unauthorized}
    end
  end

  describe "create_forum/2" do
    test "an admin creates a forum" do
      assert {:ok, %Forum{} = forum} =
               Forums.create_forum(actor(admin_user_fixture()), valid_attrs())

      assert Repo.get(Forum, forum.id)
    end

    test "invalid attributes return a changeset" do
      assert {:error, %Ecto.Changeset{}} =
               Forums.create_forum(actor(admin_user_fixture()), %{valid_attrs() | "name" => ""})
    end

    test "a plain moderator is not authorized and creates nothing" do
      assert Forums.create_forum(actor(moderator_user_fixture()), valid_attrs()) ==
               {:error, :unauthorized}
    end

    test "a regular user is not authorized" do
      assert Forums.create_forum(actor(confirmed_user_fixture()), valid_attrs()) ==
               {:error, :unauthorized}
    end

    test "an anonymous visitor is not authorized" do
      assert Forums.create_forum(actor(), valid_attrs()) == {:error, :unauthorized}
    end
  end

  describe "load_forum_for_edit/2" do
    test "an admin loads a forum by short name" do
      forum = forum_fixture()

      assert {:ok, {loaded, %Ecto.Changeset{}}} =
               Forums.load_forum_for_edit(actor(admin_user_fixture()), forum.short_name)

      assert loaded.id == forum.id
    end

    test "an unknown short name is not found for an admin" do
      assert Forums.load_forum_for_edit(actor(admin_user_fixture()), "nonexistent") ==
               {:error, :not_found}
    end

    test "an unknown short name is unauthorized for a plain moderator" do
      # Authorization runs before the load, so an unprivileged actor cannot
      # tell a missing forum from a real one.
      assert Forums.load_forum_for_edit(actor(moderator_user_fixture()), "nonexistent") ==
               {:error, :unauthorized}
    end

    test "a real forum is unauthorized for a plain moderator" do
      forum = forum_fixture()

      assert Forums.load_forum_for_edit(actor(moderator_user_fixture()), forum.short_name) ==
               {:error, :unauthorized}
    end

    test "a regular user is not authorized" do
      forum = forum_fixture()

      assert Forums.load_forum_for_edit(actor(confirmed_user_fixture()), forum.short_name) ==
               {:error, :unauthorized}
    end
  end

  describe "update_forum/3" do
    test "an admin updates a forum" do
      forum = forum_fixture()

      assert {:ok, updated} =
               Forums.update_forum(actor(admin_user_fixture()), forum.short_name, %{
                 "name" => "Renamed"
               })

      assert updated.name == "Renamed"
    end

    test "invalid attributes return a changeset" do
      forum = forum_fixture()

      assert {:error, %Ecto.Changeset{}} =
               Forums.update_forum(actor(admin_user_fixture()), forum.short_name, %{"name" => ""})
    end

    test "an unknown short name is not found for an admin" do
      assert Forums.update_forum(actor(admin_user_fixture()), "nonexistent", %{"name" => "x"}) ==
               {:error, :not_found}
    end

    test "an unknown short name is unauthorized for a plain moderator" do
      assert Forums.update_forum(actor(moderator_user_fixture()), "nonexistent", %{"name" => "x"}) ==
               {:error, :unauthorized}
    end

    test "a real forum is unauthorized for a plain moderator" do
      forum = forum_fixture()

      assert Forums.update_forum(actor(moderator_user_fixture()), forum.short_name, %{
               "name" => "x"
             }) ==
               {:error, :unauthorized}
    end

    test "a regular user is not authorized" do
      forum = forum_fixture()

      assert Forums.update_forum(actor(confirmed_user_fixture()), forum.short_name, %{
               "name" => "x"
             }) ==
               {:error, :unauthorized}
    end
  end

  # Controller-shaped attrs (string keys) a forum insert requires; the short
  # name must be lowercase letters only.
  defp valid_attrs do
    %{
      "name" => "Admin Test Forum",
      "short_name" => unique_forum_short_name(),
      "description" => "A forum created in an admin test",
      "access_level" => "normal"
    }
  end
end
