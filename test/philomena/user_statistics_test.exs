defmodule Philomena.UserStatisticsTest do
  use Philomena.DataCase, async: false

  import Philomena.UsersFixtures

  alias Philomena.Repo
  alias Philomena.Users.User
  alias Philomena.UserStatistics
  alias Philomena.UserStatistics.UserStatistic

  test "increments a loaded user's lifetime and current UTC-day counters" do
    user = confirmed_user_fixture()

    assert UserStatistics.increment(user, :images_count) == {:ok, nil}

    assert Repo.get!(User, user.id).images_count == 1

    assert %UserStatistic{images_count: 1, day: day} =
             Repo.get_by!(UserStatistic, user_id: user.id)

    assert day == Date.utc_today()
  end

  test "accepts an ID and negative amounts" do
    user = confirmed_user_fixture()

    assert UserStatistics.increment(user.id, :comments_count, 4) == {:ok, nil}
    assert UserStatistics.increment(user.id, :comments_count, -2) == {:ok, nil}

    assert Repo.get!(User, user.id).comments_count == 2
    assert Repo.get_by!(UserStatistic, user_id: user.id).comments_count == 2
  end

  test "nil users are a no-op for anonymous activity" do
    assert UserStatistics.increment(nil, :comments_count) == {:ok, nil}
    assert Repo.aggregate(UserStatistic, :count) == 0
  end

  test "a missing user ID is not-found and creates no daily row" do
    assert UserStatistics.increment(2_000_000_000, :posts_count) == {:error, :not_found}
    assert Repo.aggregate(UserStatistic, :count) == 0
  end

  test "unknown keys and non-integer amounts do not match the service API" do
    user = confirmed_user_fixture()

    assert_raise FunctionClauseError, fn ->
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(UserStatistics, :increment, [user, :email, 1])
    end

    assert_raise FunctionClauseError, fn ->
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(UserStatistics, :increment, [user, :images_count, 1.5])
    end
  end

  test "an owning transaction rollback restores both counters" do
    user = confirmed_user_fixture()

    assert Repo.transact(fn ->
             assert UserStatistics.increment(user, :topics_count) == {:ok, nil}
             {:error, :forced_rollback}
           end) == {:error, :forced_rollback}

    assert Repo.get!(User, user.id).topics_count == 0
    refute Repo.get_by(UserStatistic, user_id: user.id)
  end

  test "atomic increments do not lose updates from concurrent callers" do
    user = confirmed_user_fixture()

    tasks =
      for _ <- 1..8 do
        Task.async(fn -> UserStatistics.increment(user.id, :image_votes_count) end)
      end

    assert Enum.map(tasks, &Task.await(&1, 5_000)) == List.duplicate({:ok, nil}, 8)
    assert Repo.get!(User, user.id).image_votes_count == 8
    assert Repo.get_by!(UserStatistic, user_id: user.id).image_votes_count == 8
  end

  test "daily rows cascade on user deletion and deleted IDs are not-found" do
    user = confirmed_user_fixture()
    assert UserStatistics.increment(user, :posts_count) == {:ok, nil}

    Repo.delete!(user)

    refute Repo.get_by(UserStatistic, user_id: user.id)
    assert UserStatistics.increment(user.id, :posts_count) == {:error, :not_found}
  end
end
