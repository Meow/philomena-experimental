defmodule Philomena.PollsTest do
  @moduledoc """
  Context-level tests for the actor-first poll editing APIs on `Philomena.Polls`:
  `load_poll_for_edit/3` and `update_poll/4`.

  These pin the shared load-and-authorize chain both functions reuse (forum
  `:show`, topic visibility, poll existence, then topic `:hide`) across the
  anonymous / regular user / moderator matrix, including the ordering quirk
  where the poll-existence check runs before the `:hide` authorization: a
  regular user on a poll-less topic answers not-found rather than unauthorized.
  The corresponding controller characterization tests pin the HTTP behavior on
  top of these results.
  """

  use Philomena.DataCase, async: true

  import Philomena.ForumsFixtures
  import Philomena.TopicsFixtures
  import Philomena.UsersFixtures

  alias Philomena.Polls
  alias Philomena.Repo

  # A visible topic (in a normal, publicly readable forum) that carries a poll,
  # the common shape both functions load through.
  defp forum_topic_poll do
    forum = forum_fixture()
    {topic, poll} = topic_with_poll_fixture(forum)
    {forum, topic, poll}
  end

  describe "load_poll_for_edit/3" do
    test "a moderator loads the poll, preloaded options, and a changeset for it" do
      moderator = moderator_user_fixture()
      {forum, topic, poll} = forum_topic_poll()

      assert {:ok, {loaded_forum, loaded_topic, loaded_poll, changeset}} =
               Polls.load_poll_for_edit(moderator, forum.short_name, topic.slug)

      assert loaded_forum.id == forum.id
      assert loaded_topic.id == topic.id
      assert loaded_poll.id == poll.id

      # The options are preloaded so the edit form can render existing choices:
      # a loaded list, not an unloaded association.
      assert is_list(loaded_poll.options)
      assert length(loaded_poll.options) == 2

      # The changeset drives the edit form and is built from the loaded poll.
      assert %Ecto.Changeset{data: %Philomena.Polls.Poll{}} = changeset
      assert changeset.data.id == poll.id
    end

    test "an admin loads the poll" do
      admin = admin_user_fixture()
      {forum, topic, poll} = forum_topic_poll()

      assert {:ok, {_forum, _topic, loaded_poll, %Ecto.Changeset{}}} =
               Polls.load_poll_for_edit(admin, forum.short_name, topic.slug)

      assert loaded_poll.id == poll.id
    end

    test "a regular user is unauthorized even though the poll exists" do
      # The topic is visible, so the forum :show and topic visibility checks pass
      # and the poll load succeeds; the block on the topic :hide permission is
      # what denies a regular user.
      user = confirmed_user_fixture()
      {forum, topic, _poll} = forum_topic_poll()

      assert Polls.load_poll_for_edit(user, forum.short_name, topic.slug) ==
               {:error, :unauthorized}
    end

    test "an anonymous actor is unauthorized" do
      # nil clears forum :show and topic visibility on normal content and the
      # poll load succeeds, but fails the topic :hide permission, so this is a
      # clean unauthorized rather than a crash on the nil actor.
      {forum, topic, _poll} = forum_topic_poll()

      assert Polls.load_poll_for_edit(nil, forum.short_name, topic.slug) ==
               {:error, :unauthorized}
    end

    test "an unknown forum is unauthorized for a regular user" do
      # The forum is loaded by short name and authorized for :show; the nil result
      # is denied for a regular user before any topic or poll load.
      assert Polls.load_poll_for_edit(confirmed_user_fixture(), "nonexistent", "whatever") ==
               {:error, :unauthorized}
    end

    test "an existing forum with an unknown topic is not found" do
      forum = forum_fixture()

      assert Polls.load_poll_for_edit(
               moderator_user_fixture(),
               forum.short_name,
               "nonexistent-topic"
             ) == {:error, :not_found}
    end

    test "a topic without a poll is not found for a moderator" do
      # A topic that carries no poll is not_found.
      forum = forum_fixture()
      topic = topic_fixture(forum)

      assert Polls.load_poll_for_edit(moderator_user_fixture(), forum.short_name, topic.slug) ==
               {:error, :not_found}
    end

    test "a topic without a poll is not found for a regular user, not unauthorized" do
      # NOTE: pins the ordering of the shared load chain. The poll-existence check
      # runs BEFORE the topic :hide authorization, so a poll-less topic answers
      # not-found even for a regular user who would otherwise fail :hide with
      # unauthorized. Compare the "poll exists" case above, where the same regular
      # user gets unauthorized.
      user = confirmed_user_fixture()
      forum = forum_fixture()
      topic = topic_fixture(forum)

      assert Polls.load_poll_for_edit(user, forum.short_name, topic.slug) ==
               {:error, :not_found}
    end
  end

  describe "update_poll/4" do
    test "a moderator updates the poll title and redirects data is returned" do
      moderator = moderator_user_fixture()
      {forum, topic, poll} = forum_topic_poll()

      assert {:ok, {loaded_forum, loaded_topic}} =
               Polls.update_poll(moderator, forum.short_name, topic.slug, %{
                 "title" => "Moderator updated title"
               })

      assert loaded_forum.id == forum.id
      assert loaded_topic.id == topic.id
      assert Repo.reload!(poll).title == "Moderator updated title"
    end

    test "an admin updates the poll title" do
      admin = admin_user_fixture()
      {forum, topic, poll} = forum_topic_poll()

      assert {:ok, {_forum, _topic}} =
               Polls.update_poll(admin, forum.short_name, topic.slug, %{
                 "title" => "Admin updated title"
               })

      assert Repo.reload!(poll).title == "Admin updated title"
    end

    test "a rejected changeset yields the 4-tuple error and leaves the poll unchanged" do
      # Poll.changeset requires title; a blank title with another real change
      # (active_until) produces an invalid changeset with non-empty changes, so
      # it surfaces as {:error, forum, topic, changeset} (both the loaded forum
      # and topic so the controller can re-render the edit form) rather than the
      # no-op :ignore path.
      moderator = moderator_user_fixture()
      {forum, topic, poll} = forum_topic_poll()

      assert {:error, error_forum, error_topic, changeset} =
               Polls.update_poll(moderator, forum.short_name, topic.slug, %{
                 "title" => "",
                 "active_until" =>
                   DateTime.utc_now(:second) |> DateTime.add(3, :day) |> DateTime.to_iso8601(),
                 "vote_method" => "single"
               })

      assert error_forum.id == forum.id
      assert error_topic.id == topic.id
      assert %Ecto.Changeset{valid?: false} = changeset
      assert Repo.reload!(poll).title == "Best test option?"
    end

    test "a regular user is unauthorized and the poll is unchanged" do
      user = confirmed_user_fixture()
      {forum, topic, poll} = forum_topic_poll()

      assert Polls.update_poll(user, forum.short_name, topic.slug, %{"title" => "Hijacked"}) ==
               {:error, :unauthorized}

      assert Repo.reload!(poll).title == "Best test option?"
    end

    test "an anonymous actor is unauthorized and the poll is unchanged" do
      {forum, topic, poll} = forum_topic_poll()

      assert Polls.update_poll(nil, forum.short_name, topic.slug, %{"title" => "Hijacked"}) ==
               {:error, :unauthorized}

      assert Repo.reload!(poll).title == "Best test option?"
    end

    test "an unknown forum is unauthorized for a regular user" do
      assert Polls.update_poll(confirmed_user_fixture(), "nonexistent", "whatever", %{
               "title" => "New title"
             }) == {:error, :unauthorized}
    end

    test "an existing forum with an unknown topic is not found" do
      forum = forum_fixture()

      assert Polls.update_poll(
               moderator_user_fixture(),
               forum.short_name,
               "nonexistent-topic",
               %{"title" => "New title"}
             ) == {:error, :not_found}
    end

    test "a topic without a poll is not found for a moderator" do
      forum = forum_fixture()
      topic = topic_fixture(forum)

      assert Polls.update_poll(moderator_user_fixture(), forum.short_name, topic.slug, %{
               "title" => "New title"
             }) == {:error, :not_found}
    end

    test "a topic without a poll is not found for a regular user, not unauthorized" do
      # NOTE: same ordering quirk as load_poll_for_edit/3. The poll-existence
      # check precedes the topic :hide authorization, so a regular user on a
      # poll-less topic gets not-found rather than the unauthorized they get when
      # the poll exists.
      user = confirmed_user_fixture()
      forum = forum_fixture()
      topic = topic_fixture(forum)

      assert Polls.update_poll(user, forum.short_name, topic.slug, %{"title" => "New title"}) ==
               {:error, :not_found}
    end
  end
end
