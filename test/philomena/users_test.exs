defmodule Philomena.UsersTest do
  use Philomena.DataCase, async: true

  alias Philomena.Users
  import Philomena.UsersFixtures
  import Philomena.AttributionFixtures
  import Philomena.UserIpsFixtures
  import Philomena.UserFingerprintsFixtures
  alias Philomena.Users.{User, UserToken}

  # A truthy ban value in the shape production passes; only its presence matters
  # to the write-access and not-banned checks the profile loaders run first.
  @ban %{
    reason: "Rule #0",
    valid_until: ~U[3000-01-01 00:00:00Z],
    generated_ban_id: "U123456",
    type: "User"
  }

  describe "get_user_by_email/1" do
    test "does not return the user if the email does not exist" do
      refute Users.get_user_by_email("unknown@example.com")
    end

    test "returns the user if the email exists" do
      %{id: id} = user = user_fixture()
      assert %User{id: ^id} = Users.get_user_by_email(user.email)
    end
  end

  describe "get_user_by_email_and_password/3" do
    test "does not return the user if the email does not exist" do
      refute Users.get_user_by_email_and_password("unknown@example.com", "hello world!", & &1)
    end

    test "does not return the user if the password is not valid" do
      user = user_fixture()
      refute Users.get_user_by_email_and_password(user.email, "invalid", & &1)

      user = Users.get_user!(user.id)
      assert user.failed_attempts == 1
    end

    test "sends lock email if too many attempts to sign in are made" do
      user = user_fixture()

      Enum.map(1..10, fn _ ->
        refute Users.get_user_by_email_and_password(user.email, "invalid", & &1)
      end)

      user = Users.get_user!(user.id)

      token =
        extract_user_token(fn url ->
          Users.deliver_user_unlock_instructions(user, url)
        end)

      {:ok, token} = Base.url_decode64(token, padding: false)
      assert user_token = Repo.get_by(UserToken, token: :crypto.hash(:sha256, token))
      assert user_token.user_id == user.id
      assert user_token.sent_to == user.email
      assert user_token.context == "unlock"
      assert user.failed_attempts == 10
      refute is_nil(user.locked_at)
    end

    test "denies access to account if locked" do
      user = user_fixture()

      Enum.map(1..10, fn _ ->
        refute Users.get_user_by_email_and_password(user.email, "invalid", & &1)
      end)

      refute Users.get_user_by_email_and_password(user.email, valid_user_password(), & &1)
    end

    test "returns the user if the email and password are valid" do
      %{id: id} = user = user_fixture()

      assert %User{id: ^id} =
               Users.get_user_by_email_and_password(user.email, valid_user_password(), & &1)
    end
  end

  describe "get_user!/1" do
    test "raises if id is invalid" do
      assert_raise Ecto.NoResultsError, fn ->
        Users.get_user!(-1)
      end
    end

    test "returns the user with the given id" do
      %{id: id} = user = user_fixture()
      assert %User{id: ^id} = Users.get_user!(user.id)
    end
  end

  describe "register_user/1" do
    test "requires email and password to be set" do
      {:error, changeset} = Users.register_user(%{})

      assert %{
               password: ["can't be blank"],
               email: ["can't be blank"]
             } = errors_on(changeset)
    end

    test "validates email and password when given" do
      {:error, changeset} = Users.register_user(%{email: "not valid", password: "not valid"})

      assert %{
               email: ["must be valid (e.g., user@example.com)"],
               password: ["should be at least 12 character(s)"]
             } = errors_on(changeset)
    end

    test "validates maximum values for email and password for security" do
      too_long = String.duplicate("db", 100)
      {:error, changeset} = Users.register_user(%{email: too_long, password: too_long})
      assert "should be at most 160 character(s)" in errors_on(changeset).email
      assert "should be at most 80 character(s)" in errors_on(changeset).password
    end

    test "validates email uniqueness" do
      %{email: email} = user_fixture()

      {:error, changeset} = Users.register_user(%{name: email, email: email})
      assert "has already been taken" in errors_on(changeset).email

      # Now try with the upper cased email too, to check that email case is ignored.
      {:error, changeset} =
        Users.register_user(%{
          name: String.upcase(email),
          email: String.upcase(email),
          password: valid_user_password()
        })

      assert "has already been taken" in errors_on(changeset).email
    end

    test "registers users with a hashed password" do
      email = unique_user_email()

      {:ok, user} =
        Users.register_user(%{name: email, email: email, password: valid_user_password()})

      assert user.email == email
      assert is_binary(user.hashed_password)
      assert is_nil(user.confirmed_at)
      assert is_nil(user.password)
    end
  end

  describe "change_user_registration/2" do
    test "returns a changeset" do
      assert %Ecto.Changeset{} = changeset = Users.change_user_registration(%User{})
      assert changeset.required == [:password, :email, :name]
    end
  end

  describe "change_user_email/2" do
    test "returns a user changeset" do
      assert %Ecto.Changeset{} = changeset = Users.change_user_email(%User{})
      assert changeset.required == [:email]
    end
  end

  describe "apply_user_email/3" do
    setup do
      %{user: user_fixture()}
    end

    test "requires email to change", %{user: user} do
      {:error, changeset} = Users.apply_user_email(user, valid_user_password(), %{})
      assert %{email: ["did not change"]} = errors_on(changeset)
    end

    test "validates email", %{user: user} do
      {:error, changeset} =
        Users.apply_user_email(user, valid_user_password(), %{email: "not valid"})

      assert %{email: ["must be valid (e.g., user@example.com)"]} = errors_on(changeset)
    end

    test "validates maximum value for email for security", %{user: user} do
      too_long = String.duplicate("db", 100)

      {:error, changeset} =
        Users.apply_user_email(user, valid_user_password(), %{email: too_long})

      assert "should be at most 160 character(s)" in errors_on(changeset).email
    end

    test "validates email uniqueness", %{user: user} do
      %{email: email} = user_fixture()

      {:error, changeset} = Users.apply_user_email(user, valid_user_password(), %{email: email})

      assert "has already been taken" in errors_on(changeset).email
    end

    test "validates current password", %{user: user} do
      {:error, changeset} = Users.apply_user_email(user, "invalid", %{email: unique_user_email()})

      assert %{current_password: ["is not valid"]} = errors_on(changeset)
    end

    test "applies the email without persisting it", %{user: user} do
      email = unique_user_email()
      {:ok, user} = Users.apply_user_email(user, valid_user_password(), %{email: email})
      assert user.email == email
      assert Users.get_user!(user.id).email != email
    end
  end

  describe "deliver_update_email_instructions/3" do
    setup do
      %{user: user_fixture()}
    end

    test "sends token through notification", %{user: user} do
      token =
        extract_user_token(fn url ->
          Users.deliver_update_email_instructions(user, "current@example.com", url)
        end)

      {:ok, token} = Base.url_decode64(token, padding: false)
      assert user_token = Repo.get_by(UserToken, token: :crypto.hash(:sha256, token))
      assert user_token.user_id == user.id
      assert user_token.sent_to == user.email
      assert user_token.context == "change:current@example.com"
    end
  end

  describe "update_user_email/2" do
    setup do
      user = user_fixture()
      email = unique_user_email()

      token =
        extract_user_token(fn url ->
          Users.deliver_update_email_instructions(%{user | email: email}, user.email, url)
        end)

      %{user: user, token: token, email: email}
    end

    test "updates the email with a valid token", %{user: user, token: token, email: email} do
      assert Users.update_user_email(user, token) == :ok
      changed_user = Repo.get!(User, user.id)
      assert changed_user.email != user.email
      assert changed_user.email == email
      assert changed_user.confirmed_at
      assert changed_user.confirmed_at != user.confirmed_at
      refute Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not update email with invalid token", %{user: user} do
      assert Users.update_user_email(user, "oops") == :error
      assert Repo.get!(User, user.id).email == user.email
      assert Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not update email if user email changed", %{user: user, token: token} do
      assert Users.update_user_email(%{user | email: "current@example.com"}, token) == :error
      assert Repo.get!(User, user.id).email == user.email
      assert Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not update email if token expired", %{user: user, token: token} do
      {1, nil} = Repo.update_all(UserToken, set: [created_at: ~N[2020-01-01 00:00:00]])
      assert Users.update_user_email(user, token) == :error
      assert Repo.get!(User, user.id).email == user.email
      assert Repo.get_by(UserToken, user_id: user.id)
    end
  end

  describe "change_user_password/2" do
    test "returns a user changeset" do
      assert %Ecto.Changeset{} = changeset = Users.change_user_password(%User{})
      assert changeset.required == [:password]
    end
  end

  describe "update_user_password/3" do
    setup do
      %{user: user_fixture()}
    end

    test "validates password", %{user: user} do
      {:error, changeset} =
        Users.update_user_password(user, valid_user_password(), %{
          password: "not valid",
          password_confirmation: "another"
        })

      assert %{
               password: ["should be at least 12 character(s)"],
               password_confirmation: ["does not match password"]
             } = errors_on(changeset)
    end

    test "validates maximum values for password for security", %{user: user} do
      too_long = String.duplicate("db", 200)

      {:error, changeset} =
        Users.update_user_password(user, valid_user_password(), %{password: too_long})

      assert "should be at most 80 character(s)" in errors_on(changeset).password
    end

    test "validates current password", %{user: user} do
      {:error, changeset} =
        Users.update_user_password(user, "invalid", %{password: valid_user_password()})

      assert %{current_password: ["is not valid"]} = errors_on(changeset)
    end

    test "updates the password", %{user: user} do
      {:ok, user} =
        Users.update_user_password(user, valid_user_password(), %{
          password: "new valid password"
        })

      assert is_nil(user.password)
      assert Users.get_user_by_email_and_password(user.email, "new valid password", & &1)
    end

    test "deletes all tokens for the given user", %{user: user} do
      _ = Users.generate_user_session_token(user)

      {:ok, _} =
        Users.update_user_password(user, valid_user_password(), %{
          password: "new valid password"
        })

      refute Repo.get_by(UserToken, user_id: user.id)
    end
  end

  describe "generate_user_session_token/1" do
    setup do
      %{user: user_fixture()}
    end

    test "generates a token", %{user: user} do
      token = Users.generate_user_session_token(user)
      assert user_token = Repo.get_by(UserToken, token: token)
      assert user_token.context == "session"

      # Creating the same token for another user should fail
      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%UserToken{
          token: user_token.token,
          user_id: user_fixture().id,
          context: "session"
        })
      end
    end
  end

  describe "get_user_by_session_token/1" do
    setup do
      user = user_fixture()
      token = Users.generate_user_session_token(user)
      %{user: user, token: token}
    end

    test "returns user by token", %{user: user, token: token} do
      assert session_user = Users.get_user_by_session_token(token)
      assert session_user.id == user.id
    end

    test "does not return user for invalid token" do
      refute Users.get_user_by_session_token("oops")
    end

    test "does not return user for expired token", %{token: token} do
      {1, nil} = Repo.update_all(UserToken, set: [created_at: ~N[2019-01-01 00:00:00]])
      refute Users.get_user_by_session_token(token)
    end
  end

  describe "delete_session_token/1" do
    test "deletes the token" do
      user = user_fixture()
      token = Users.generate_user_session_token(user)
      assert Users.delete_session_token(token) == :ok
      refute Users.get_user_by_session_token(token)
    end
  end

  describe "generate_user_totp_token/1" do
    setup do
      %{user: user_fixture()}
    end

    test "generates a token", %{user: user} do
      token = Users.generate_user_totp_token(user)
      assert user_token = Repo.get_by(UserToken, token: token)
      assert user_token.context == "totp"

      # Creating the same token for another user should fail
      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%UserToken{
          token: user_token.token,
          user_id: user_fixture().id,
          context: "totp"
        })
      end
    end
  end

  describe "user_totp_token_valid?/1" do
    setup do
      user = user_fixture()
      token = Users.generate_user_totp_token(user)
      %{user: user, token: token}
    end

    test "returns true for valid token", %{user: user, token: token} do
      assert Users.user_totp_token_valid?(user, token)
    end

    test "returns false for invalid token", %{user: user} do
      refute Users.user_totp_token_valid?(user, "oops")
    end

    test "returns false for expired token", %{user: user, token: token} do
      {1, nil} = Repo.update_all(UserToken, set: [created_at: ~N[2019-01-01 00:00:00]])
      refute Users.user_totp_token_valid?(user, token)
    end
  end

  describe "delete_totp_token/1" do
    test "deletes the token" do
      user = user_fixture()
      token = Users.generate_user_totp_token(user)
      assert Users.delete_totp_token(token) == :ok
      refute Users.user_totp_token_valid?(user, token)
    end
  end

  describe "deliver_user_confirmation_instructions/2" do
    setup do
      %{user: user_fixture()}
    end

    test "sends token through notification", %{user: user} do
      token =
        extract_user_token(fn url ->
          Users.deliver_user_confirmation_instructions(user, url)
        end)

      {:ok, token} = Base.url_decode64(token, padding: false)
      assert user_token = Repo.get_by(UserToken, token: :crypto.hash(:sha256, token))
      assert user_token.user_id == user.id
      assert user_token.sent_to == user.email
      assert user_token.context == "confirm"
    end
  end

  describe "confirm_user/2" do
    setup do
      user = user_fixture()

      token =
        extract_user_token(fn url ->
          Users.deliver_user_confirmation_instructions(user, url)
        end)

      %{user: user, token: token}
    end

    test "confirms the email with a valid token", %{user: user, token: token} do
      assert {:ok, confirmed_user} = Users.confirm_user(token)
      assert confirmed_user.confirmed_at
      assert confirmed_user.confirmed_at != user.confirmed_at
      assert Repo.get!(User, user.id).confirmed_at
      refute Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not confirm with invalid token", %{user: user} do
      assert Users.confirm_user("oops") == :error
      refute Repo.get!(User, user.id).confirmed_at
      assert Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not confirm email if token expired", %{user: user, token: token} do
      {1, nil} = Repo.update_all(UserToken, set: [created_at: ~N[2020-01-01 00:00:00]])
      assert Users.confirm_user(token) == :error
      refute Repo.get!(User, user.id).confirmed_at
      assert Repo.get_by(UserToken, user_id: user.id)
    end
  end

  describe "deliver_user_unlock_instructions/2" do
    setup do
      %{user: locked_user_fixture()}
    end

    test "sends token through notification", %{user: user} do
      token =
        extract_user_token(fn url ->
          Users.deliver_user_unlock_instructions(user, url)
        end)

      {:ok, token} = Base.url_decode64(token, padding: false)
      assert user_token = Repo.get_by(UserToken, token: :crypto.hash(:sha256, token))
      assert user_token.user_id == user.id
      assert user_token.sent_to == user.email
      assert user_token.context == "unlock"
    end
  end

  describe "unlock_user_by_token/1" do
    setup do
      user = locked_user_fixture()

      token =
        extract_user_token(fn url ->
          Users.deliver_user_unlock_instructions(user, url)
        end)

      %{user: user, token: token}
    end

    test "unlocks the user with a valid token", %{user: user, token: token} do
      assert {:ok, unlocked_user} = Users.unlock_user_by_token(token)
      refute unlocked_user.locked_at
      refute Repo.get!(User, user.id).locked_at
      refute Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not confirm with invalid token", %{user: user} do
      assert Users.unlock_user_by_token("oops") == :error
      assert Repo.get!(User, user.id).locked_at
      assert Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not unlocked if token expired", %{user: user, token: token} do
      {1, nil} = Repo.update_all(UserToken, set: [created_at: ~N[2020-01-01 00:00:00]])
      assert Users.unlock_user_by_token(token) == :error
      assert Repo.get!(User, user.id).locked_at
      assert Repo.get_by(UserToken, user_id: user.id)
    end
  end

  describe "unlock_user/1" do
    setup do
      user = user_fixture()
      locked_user = locked_user_fixture()

      %{user: user, locked_user: locked_user}
    end

    test "unlocks the user when locked", %{locked_user: locked_user} do
      assert {:ok, unlocked_user} = Users.unlock_user(locked_user)
      refute unlocked_user.locked_at
      refute Repo.get!(User, unlocked_user.id).locked_at
    end

    test "does nothing when not locked", %{user: user} do
      assert {:ok, unlocked_user} = Users.unlock_user(user)
      refute unlocked_user.locked_at
      refute Repo.get!(User, unlocked_user.id).locked_at
    end
  end

  describe "deliver_user_reset_password_instructions/2" do
    setup do
      %{user: user_fixture()}
    end

    test "sends token through notification", %{user: user} do
      token =
        extract_user_token(fn url ->
          Users.deliver_user_reset_password_instructions(user, url)
        end)

      {:ok, token} = Base.url_decode64(token, padding: false)
      assert user_token = Repo.get_by(UserToken, token: :crypto.hash(:sha256, token))
      assert user_token.user_id == user.id
      assert user_token.sent_to == user.email
      assert user_token.context == "reset_password"
    end
  end

  describe "get_user_by_reset_password_token/2" do
    setup do
      user = user_fixture()

      token =
        extract_user_token(fn url ->
          Users.deliver_user_reset_password_instructions(user, url)
        end)

      %{user: user, token: token}
    end

    test "returns the user with valid token", %{user: %{id: id}, token: token} do
      assert %User{id: ^id} = Users.get_user_by_reset_password_token(token)
      assert Repo.get_by(UserToken, user_id: id)
    end

    test "does not return the user with invalid token", %{user: user} do
      refute Users.get_user_by_reset_password_token("oops")
      assert Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not return the user if token expired", %{user: user, token: token} do
      {1, nil} = Repo.update_all(UserToken, set: [created_at: ~N[2020-01-01 00:00:00]])
      refute Users.get_user_by_reset_password_token(token)
      assert Repo.get_by(UserToken, user_id: user.id)
    end
  end

  describe "reset_user_password/3" do
    setup do
      %{user: user_fixture()}
    end

    test "validates password", %{user: user} do
      {:error, changeset} =
        Users.reset_user_password(user, %{
          password: "not valid",
          password_confirmation: "another"
        })

      assert %{
               password: ["should be at least 12 character(s)"],
               password_confirmation: ["does not match password"]
             } = errors_on(changeset)
    end

    test "validates maximum values for password for security", %{user: user} do
      too_long = String.duplicate("db", 100)
      {:error, changeset} = Users.reset_user_password(user, %{password: too_long})
      assert "should be at most 80 character(s)" in errors_on(changeset).password
    end

    test "updates the password", %{user: user} do
      {:ok, updated_user} = Users.reset_user_password(user, %{password: "new valid password"})
      assert is_nil(updated_user.password)
      assert Users.get_user_by_email_and_password(user.email, "new valid password", & &1)
    end

    test "deletes all tokens for the given user", %{user: user} do
      _ = Users.generate_user_session_token(user)
      {:ok, _} = Users.reset_user_password(user, %{password: "new valid password"})
      refute Repo.get_by(UserToken, user_id: user.id)
    end
  end

  describe "inspect/2" do
    test "does not include password" do
      refute inspect(%User{password: "123456"}) =~ "password: \"123456\""
    end
  end

  describe "load_profile_for_description_edit/2" do
    test "the profile owner may edit their own description" do
      user = confirmed_user_fixture()

      assert {:ok, loaded} = Users.load_profile_for_description_edit(actor(user), user.slug)
      assert loaded.id == user.id
    end

    test "a moderator may edit another user's description" do
      user = confirmed_user_fixture()

      assert {:ok, loaded} =
               Users.load_profile_for_description_edit(actor(moderator_user_fixture()), user.slug)

      assert loaded.id == user.id
    end

    test "an unrelated user may not edit another user's description" do
      user = confirmed_user_fixture()

      assert Users.load_profile_for_description_edit(actor(confirmed_user_fixture()), user.slug) ==
               {:error, :unauthorized}
    end

    test "a banned actor is rejected before any authorization" do
      user = confirmed_user_fixture()

      assert Users.load_profile_for_description_edit(actor(user, ban: @ban), user.slug) ==
               {:error, :ban}
    end

    test "an unknown slug is unauthorized for a moderator, not-found for an admin" do
      assert Users.load_profile_for_description_edit(
               actor(moderator_user_fixture()),
               "no-such-user"
             ) ==
               {:error, :unauthorized}

      assert Users.load_profile_for_description_edit(actor(admin_user_fixture()), "no-such-user") ==
               {:error, :not_found}
    end
  end

  describe "update_description/3" do
    test "the owner updates their description" do
      user = confirmed_user_fixture()

      assert {:ok, updated} =
               Users.update_description(actor(user), user.slug, %{"description" => "New bio text"})

      assert updated.id == user.id
      assert Users.get_user!(user.id).description == "New bio text"
    end

    test "a banned actor is rejected" do
      user = confirmed_user_fixture()

      assert Users.update_description(actor(user, ban: @ban), user.slug, %{
               "description" => "New bio text"
             }) == {:error, :ban}
    end

    test "an actor with no fingerprint is unauthorized" do
      user = confirmed_user_fixture()

      assert Users.update_description(actor(user, fingerprint: nil), user.slug, %{
               "description" => "New bio text"
             }) == {:error, :unauthorized}
    end

    test "an unrelated user may not update another user's description" do
      user = confirmed_user_fixture()

      assert Users.update_description(actor(confirmed_user_fixture()), user.slug, %{
               "description" => "New bio text"
             }) == {:error, :unauthorized}
    end
  end

  describe "load_profile_for_scratchpad_edit/2" do
    test "a moderator may edit the scratchpad" do
      user = confirmed_user_fixture()

      assert {:ok, loaded} =
               Users.load_profile_for_scratchpad_edit(actor(moderator_user_fixture()), user.slug)

      assert loaded.id == user.id
    end

    test "an assistant may edit the scratchpad" do
      user = confirmed_user_fixture()

      assert {:ok, loaded} =
               Users.load_profile_for_scratchpad_edit(actor(assistant_user_fixture()), user.slug)

      assert loaded.id == user.id
    end

    test "a regular user may not edit the scratchpad" do
      user = confirmed_user_fixture()

      assert Users.load_profile_for_scratchpad_edit(actor(confirmed_user_fixture()), user.slug) ==
               {:error, :unauthorized}
    end

    test "a banned actor is rejected before the mod-note check" do
      user = confirmed_user_fixture()

      assert Users.load_profile_for_scratchpad_edit(
               actor(moderator_user_fixture(), ban: @ban),
               user.slug
             ) == {:error, :ban}
    end

    test "a permitted actor naming an unknown slug is not-found" do
      assert Users.load_profile_for_scratchpad_edit(
               actor(moderator_user_fixture()),
               "no-such-user"
             ) ==
               {:error, :not_found}
    end
  end

  describe "update_scratchpad/3" do
    test "a moderator updates the scratchpad" do
      user = confirmed_user_fixture()

      assert {:ok, updated} =
               Users.update_scratchpad(actor(moderator_user_fixture()), user.slug, %{
                 "scratchpad" => "Mod notes here"
               })

      assert updated.id == user.id
      assert Users.get_user!(user.id).scratchpad == "Mod notes here"
    end

    test "a regular user may not update the scratchpad" do
      user = confirmed_user_fixture()

      assert Users.update_scratchpad(actor(confirmed_user_fixture()), user.slug, %{
               "scratchpad" => "Mod notes here"
             }) == {:error, :unauthorized}
    end

    test "a banned actor is rejected" do
      user = confirmed_user_fixture()

      assert Users.update_scratchpad(actor(moderator_user_fixture(), ban: @ban), user.slug, %{
               "scratchpad" => "Mod notes here"
             }) == {:error, :ban}
    end
  end

  describe "load_alias_matches/2" do
    test "a moderator sees a user sharing only an IP under ip_matches" do
      subject = confirmed_user_fixture()
      alias_user = confirmed_user_fixture()
      user_ip_fixture(subject, "203.0.113.70")
      user_ip_fixture(alias_user, "203.0.113.70")

      assert {:ok, matches} = Users.load_alias_matches(moderator_user_fixture(), subject.slug)
      assert alias_user.id in Enum.map(matches.ip_matches, & &1.id)
      refute alias_user.id in Enum.map(matches.fp_matches, & &1.id)
      refute alias_user.id in Enum.map(matches.both_matches, & &1.id)
    end

    test "a moderator sees a user sharing only a fingerprint under fp_matches" do
      subject = confirmed_user_fixture()
      alias_user = confirmed_user_fixture()
      user_fingerprint_fixture(subject, "aliasfp70")
      user_fingerprint_fixture(alias_user, "aliasfp70")

      assert {:ok, matches} = Users.load_alias_matches(moderator_user_fixture(), subject.slug)
      assert alias_user.id in Enum.map(matches.fp_matches, & &1.id)
      refute alias_user.id in Enum.map(matches.ip_matches, & &1.id)
    end

    test "a moderator sees a user sharing both an IP and a fingerprint under both_matches" do
      subject = confirmed_user_fixture()
      alias_user = confirmed_user_fixture()
      user_ip_fixture(subject, "203.0.113.71")
      user_ip_fixture(alias_user, "203.0.113.71")
      user_fingerprint_fixture(subject, "aliasfp71")
      user_fingerprint_fixture(alias_user, "aliasfp71")

      assert {:ok, matches} = Users.load_alias_matches(moderator_user_fixture(), subject.slug)
      assert alias_user.id in Enum.map(matches.both_matches, & &1.id)
      refute alias_user.id in Enum.map(matches.ip_matches, & &1.id)
      refute alias_user.id in Enum.map(matches.fp_matches, & &1.id)
    end

    test "a regular user may not load alias matches" do
      assert Users.load_alias_matches(confirmed_user_fixture(), confirmed_user_fixture().slug) ==
               {:error, :unauthorized}
    end

    test "an unknown slug is unauthorized for a moderator, not-found for an admin" do
      assert Users.load_alias_matches(moderator_user_fixture(), "no-such-user") ==
               {:error, :unauthorized}

      assert Users.load_alias_matches(admin_user_fixture(), "no-such-user") ==
               {:error, :not_found}
    end
  end
end
