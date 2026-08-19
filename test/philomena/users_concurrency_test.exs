defmodule Philomena.UsersConcurrencyTest do
  use Philomena.ConcurrentDataCase

  import Philomena.UsersFixtures

  alias Philomena.Repo
  alias Philomena.Users
  alias Philomena.Users.User

  test "concurrent failed attempts only allow ten attempts" do
    user = confirmed_user_fixture()

    results =
      concurrently(
        for _ <- 1..20 do
          fn -> Users.get_user_by_email_and_password(user.email, "invalid", & &1) end
        end
      )

    assert results == List.duplicate(nil, 20)

    user = Repo.get!(User, user.id)
    assert user.failed_attempts == 10
    assert user.locked_at
  end
end
