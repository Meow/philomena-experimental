defmodule Philomena.ModerationLogsTest do
  use Philomena.DataCase, async: true

  alias Philomena.ModerationLogs

  describe "moderation_logs" do
    alias Philomena.ModerationLogs.ModerationLog

    import Philomena.UsersFixtures

    test "create_moderation_log/4 with valid data creates a moderation_log" do
      user = user_fixture()

      assert {:ok, %ModerationLog{} = _moderation_log} =
               ModerationLogs.create_moderation_log(
                 user,
                 "User:update",
                 "/path/to/subject",
                 "Updated user"
               )
    end

    test "create_moderation_log/4 with invalid data returns error changeset" do
      user = user_fixture()

      assert {:error, %Ecto.Changeset{}} =
               ModerationLogs.create_moderation_log(user, nil, nil, nil)
    end
  end

  describe "load_moderation_logs/2" do
    import Philomena.UsersFixtures

    alias Scrivener.Page

    @pagination [page: 1, page_size: 25]

    defp logged_entry do
      {:ok, log} =
        ModerationLogs.create_moderation_log(
          admin_user_fixture(),
          "User:update",
          "/path/to/subject",
          "Updated user"
        )

      log
    end

    test "a moderator gets the paginated logs" do
      log = logged_entry()

      assert {:ok, %Page{} = page} =
               ModerationLogs.load_moderation_logs(moderator_user_fixture(), @pagination)

      assert log.id in Enum.map(page.entries, & &1.id)
    end

    test "an admin gets the paginated logs" do
      assert {:ok, %Page{}} =
               ModerationLogs.load_moderation_logs(admin_user_fixture(), @pagination)
    end

    test "a regular user is unauthorized" do
      assert ModerationLogs.load_moderation_logs(confirmed_user_fixture(), @pagination) ==
               {:error, :unauthorized}
    end

    test "an anonymous viewer is unauthorized" do
      assert ModerationLogs.load_moderation_logs(nil, @pagination) == {:error, :unauthorized}
    end
  end
end
