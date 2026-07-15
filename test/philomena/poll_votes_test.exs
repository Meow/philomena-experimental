defmodule Philomena.PollVotesTest do
  @moduledoc """
  Context-level tests for the actor-first `Philomena.PollVotes` API:
  `list_votes/3`, `create_votes/4`, and `delete_vote/4`.

  These pin the shared load-and-authorize chain the vote routes reuse (forum
  `:show`, topic visibility, poll existence) and where each function diverges
  from it: `list_votes/3` and `delete_vote/4` additionally gate on the topic
  `:hide` permission, while `create_votes/4` runs `verify_write_access/1` first
  (before any loading) and never checks `:hide`. The corresponding controller
  characterization tests pin the HTTP behavior on top of these results.
  """

  use Philomena.DataCase, async: true

  import Ecto.Query

  import Philomena.AttributionFixtures
  import Philomena.ForumsFixtures
  import Philomena.TopicsFixtures
  import Philomena.UsersFixtures

  alias Philomena.PollVotes
  alias Philomena.PollVotes.PollVote
  alias Philomena.Repo

  # A truthy ban value in the shape production passes (the result of
  # Philomena.Bans.find/3); only its presence matters to verify_write_access.
  @ban %{
    reason: "Rule #0",
    valid_until: ~U[3000-01-01 00:00:00Z],
    generated_ban_id: "U123456",
    type: "User"
  }

  # A visible topic (in a normal, publicly readable forum) carrying a two-option
  # poll, with the options preloaded and sorted by label. This is the common
  # shape all three functions load through.
  defp forum_topic_poll_options do
    forum = forum_fixture()
    {topic, poll} = topic_with_poll_fixture(forum)
    poll = Repo.preload(poll, :options)
    [option_a, option_b] = Enum.sort_by(poll.options, & &1.label)

    %{forum: forum, topic: topic, poll: poll, option_a: option_a, option_b: option_b}
  end

  # Records a vote for `option` by a fresh confirmed voter through the engine,
  # returning the persisted PollVote row.
  defp record_vote(poll, option) do
    voter = confirmed_user_fixture()

    {:ok, _votes} =
      PollVotes.create_poll_votes(voter, poll, %{"option_ids" => [to_string(option.id)]})

    Repo.one!(
      from pv in PollVote,
        where: pv.poll_option_id == ^option.id and pv.user_id == ^voter.id
    )
  end

  describe "list_votes/3" do
    test "a regular user is unauthorized even though the poll exists" do
      # The topic is visible, so the forum :show and topic visibility checks pass
      # and the poll load succeeds; the block on the topic :hide permission is
      # what denies a regular user.
      user = confirmed_user_fixture()
      %{forum: forum, topic: topic} = forum_topic_poll_options()

      assert PollVotes.list_votes(actor(user), forum.short_name, topic.slug) ==
               {:error, :unauthorized}
    end

    test "a moderator gets only options with votes, with voters preloaded" do
      moderator = moderator_user_fixture()

      %{forum: forum, topic: topic, poll: poll, option_a: option_a, option_b: option_b} =
        forum_topic_poll_options()

      vote = record_vote(poll, option_a)

      assert {:ok, [option]} =
               PollVotes.list_votes(actor(moderator), forum.short_name, topic.slug)

      # Only the option that carries a vote is returned; the zero-vote option is
      # dropped so the index view renders only options someone voted for.
      assert option.id == option_a.id
      refute option.id == option_b.id

      # The votes and their voters are preloaded (a loaded list of PollVote rows,
      # each with a loaded %User{}), not unloaded associations.
      assert [%PollVote{} = loaded_vote] = option.poll_votes
      assert loaded_vote.id == vote.id
      assert %Philomena.Users.User{} = loaded_vote.user
    end

    test "an unknown forum is unauthorized" do
      # The forum is loaded by short name and authorized for :show; the nil result
      # is denied before any topic or poll load, for a moderator as much as anyone.
      assert PollVotes.list_votes(actor(moderator_user_fixture()), "nonexistent", "whatever") ==
               {:error, :unauthorized}
    end

    test "an existing forum with an unknown topic is not found" do
      forum = forum_fixture()

      assert PollVotes.list_votes(
               actor(moderator_user_fixture()),
               forum.short_name,
               "nonexistent-topic"
             ) ==
               {:error, :not_found}
    end

    test "a topic without a poll is not found for a moderator" do
      # A topic that carries no poll is not_found, and this check runs before
      # the :hide authorization.
      forum = forum_fixture()
      topic = topic_fixture(forum)

      assert PollVotes.list_votes(actor(moderator_user_fixture()), forum.short_name, topic.slug) ==
               {:error, :not_found}
    end
  end

  describe "create_votes/4" do
    test "a banned actor is rejected before any loading" do
      # verify_write_access runs first, so a banned actor is {:error, :ban} even
      # against a forum slug that does not exist: had loading run first, a missing
      # forum would surface as :unauthorized. Getting :ban pins that the ban check
      # precedes the forum/topic/poll load.
      actor = actor(confirmed_user_fixture(), ban: @ban)

      assert PollVotes.create_votes(actor, "nonexistent", "whatever", %{"option_ids" => ["1"]}) ==
               {:error, :ban}
    end

    test "an actor with no fingerprint is unauthorized before any loading, signed in or not" do
      # The fingerprint requirement applies regardless of whether a user is signed
      # in, and (like the ban check) precedes loading, so a missing forum still
      # answers unauthorized from the write-access gate rather than the loader.
      signed_in = actor(confirmed_user_fixture(), fingerprint: nil)
      anonymous = actor(nil, fingerprint: nil)

      assert PollVotes.create_votes(signed_in, "nonexistent", "whatever", %{
               "option_ids" => ["1"]
             }) == {:error, :unauthorized}

      assert PollVotes.create_votes(anonymous, "nonexistent", "whatever", %{
               "option_ids" => ["1"]
             }) == {:error, :unauthorized}
    end

    test "a valid signed-in actor records the vote" do
      user = confirmed_user_fixture()
      %{forum: forum, topic: topic, poll: poll, option_a: option_a} = forum_topic_poll_options()

      assert {:ok, {loaded_forum, loaded_topic}} =
               PollVotes.create_votes(actor(user), forum.short_name, topic.slug, %{
                 "option_ids" => [to_string(option_a.id)]
               })

      assert loaded_forum.id == forum.id
      assert loaded_topic.id == topic.id

      assert Repo.exists?(
               from pv in PollVote,
                 where: pv.poll_option_id == ^option_a.id and pv.user_id == ^user.id
             )

      assert Repo.reload!(option_a).vote_count == 1
      assert Repo.reload!(poll).total_votes == 1
    end

    test "a nil poll parameter records nothing and reports failure with the topic" do
      user = confirmed_user_fixture()
      %{forum: forum, topic: topic} = forum_topic_poll_options()

      assert {:error, error_forum, error_topic} =
               PollVotes.create_votes(actor(user), forum.short_name, topic.slug, nil)

      assert error_forum.id == forum.id
      assert error_topic.id == topic.id
      assert Repo.aggregate(PollVote, :count) == 0
    end

    test "an expired poll is an engine failure reported with the topic" do
      # The engine's :ended step bails when the poll is no longer active, so a
      # closed poll surfaces as {:error, forum, topic} (both carried so the
      # controller can redirect back) with nothing recorded.
      user = confirmed_user_fixture()
      %{forum: forum, topic: topic, poll: poll, option_a: option_a} = forum_topic_poll_options()

      poll
      |> Ecto.Changeset.change(active_until: DateTime.add(DateTime.utc_now(:second), -1, :day))
      |> Repo.update!()

      assert {:error, error_forum, error_topic} =
               PollVotes.create_votes(actor(user), forum.short_name, topic.slug, %{
                 "option_ids" => [to_string(option_a.id)]
               })

      assert error_forum.id == forum.id
      assert error_topic.id == topic.id
      assert Repo.aggregate(PollVote, :count) == 0
    end

    test "a repeat vote by the same user is an engine failure reported with the topic" do
      user = confirmed_user_fixture()

      %{forum: forum, topic: topic, option_a: option_a, option_b: option_b} =
        forum_topic_poll_options()

      assert {:ok, {_forum, _topic}} =
               PollVotes.create_votes(actor(user), forum.short_name, topic.slug, %{
                 "option_ids" => [to_string(option_a.id)]
               })

      assert {:error, error_forum, error_topic} =
               PollVotes.create_votes(actor(user), forum.short_name, topic.slug, %{
                 "option_ids" => [to_string(option_b.id)]
               })

      assert error_forum.id == forum.id
      assert error_topic.id == topic.id
      assert Repo.aggregate(from(pv in PollVote, where: pv.user_id == ^user.id), :count) == 1
    end

    test "an anonymous but fingerprinted actor crashes in the engine on a real option" do
      # NOTE: create_votes runs no :hide check and no per-user authorization, so
      # an anonymous (user: nil) actor that carries a fingerprint clears
      # verify_write_access and the public forum/topic/poll load, then reaches
      # create_poll_votes with a nil user. filter_options builds each vote row
      # with user.id, which raises BadMapError on nil rather than returning a
      # clean error. A real, valid option id is needed to hit the map step.
      %{forum: forum, topic: topic, option_a: option_a} = forum_topic_poll_options()

      assert_raise BadMapError, ~r/expected a map/, fn ->
        PollVotes.create_votes(actor(nil), forum.short_name, topic.slug, %{
          "option_ids" => [to_string(option_a.id)]
        })
      end

      assert Repo.aggregate(PollVote, :count) == 0
    end
  end

  describe "delete_vote/4" do
    test "a regular user is unauthorized and the vote survives" do
      # The :hide check runs before the vote is even looked up, so a regular user
      # is denied regardless of the vote id.
      user = confirmed_user_fixture()
      %{forum: forum, topic: topic, poll: poll, option_a: option_a} = forum_topic_poll_options()
      vote = record_vote(poll, option_a)

      assert PollVotes.delete_vote(actor(user), forum.short_name, topic.slug, to_string(vote.id)) ==
               {:error, :unauthorized}

      assert Repo.get(PollVote, vote.id)
    end

    test "a moderator with an unknown vote id gets the failure tuple with the topic" do
      moderator = moderator_user_fixture()
      %{forum: forum, topic: topic} = forum_topic_poll_options()

      assert {:error, error_forum, error_topic} =
               PollVotes.delete_vote(actor(moderator), forum.short_name, topic.slug, "999999999")

      assert error_forum.id == forum.id
      assert error_topic.id == topic.id
    end

    test "a moderator with a non-integer vote id gets the failure tuple with the topic" do
      # The id is parsed with IntegerId first, so an unparsable id takes the same
      # nil path as an unknown one rather than raising.
      moderator = moderator_user_fixture()
      %{forum: forum, topic: topic} = forum_topic_poll_options()

      assert {:error, error_forum, error_topic} =
               PollVotes.delete_vote(
                 actor(moderator),
                 forum.short_name,
                 topic.slug,
                 "not-a-number"
               )

      assert error_forum.id == forum.id
      assert error_topic.id == topic.id
    end

    test "a moderator removes the vote and decrements the cached tallies" do
      moderator = moderator_user_fixture()
      %{forum: forum, topic: topic, poll: poll, option_a: option_a} = forum_topic_poll_options()
      vote = record_vote(poll, option_a)

      assert Repo.reload!(option_a).vote_count == 1
      assert Repo.reload!(poll).total_votes == 1

      assert {:ok, {loaded_forum, loaded_topic}} =
               PollVotes.delete_vote(
                 actor(moderator),
                 forum.short_name,
                 topic.slug,
                 to_string(vote.id)
               )

      assert loaded_forum.id == forum.id
      assert loaded_topic.id == topic.id
      refute Repo.get(PollVote, vote.id)

      assert Repo.reload!(option_a).vote_count == 0
      assert Repo.reload!(poll).total_votes == 0
    end
  end
end
