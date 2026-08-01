defmodule Philomena.Authorization do
  @moduledoc """
  The single authorization entry point for context functions.

  Context functions call `authorize/3` at the start of a write
  (or before returning a loaded record on a read).

  This is a thin wrapper over Canada: the permission rules themselves remain the
  single source of truth in `Philomena.Users.Ability` (`lib/philomena/users/ability.ex`).

  The actor is permitted to be `nil` (an anonymous visitor).
  """

  alias Philomena.Attribution.Actor
  alias Philomena.Users.User

  @typedoc "Type of acceptable actor inputs."
  @type actor :: Actor.t() | User.t() | nil

  @doc """
  Authorizes `actor` to perform `action` on `subject`.

  Returns `:ok` when Canada permits the action, otherwise
  `{:error, :unauthorized}`.

  `actor` may be `nil` for an anonymous visitor. It may also be a
  `Philomena.Attribution.Actor`: permissions are decided by its `user` alone -
  the IP and fingerprint attribute the action but grant nothing - so contexts
  that take an attribution can pass it here unchanged.

  ## Examples

      iex> authorize(user, :hide, image)
      :ok

      iex> authorize(nil, :hide, image)
      {:error, :unauthorized}

      iex> authorize(%Actor{user: moderator, ip: ip}, :revert, TagChange)
      :ok

  """
  @spec authorize(actor :: actor(), action :: atom(), subject :: any()) ::
          :ok | {:error, :unauthorized}
  def authorize(%Actor{user: user}, action, subject), do: authorize(user, action, subject)

  def authorize(actor, action, subject) do
    if Canada.Can.can?(actor, action, subject), do: :ok, else: {:error, :unauthorized}
  end

  @doc """
  FIXME: get rid of this. I am not aware of any location where we want this to succeed
  where verify_write_access would fail.

  Verifies that `actor` is not banned.

  Returns `:ok` when the actor carries no active ban, otherwise `{:error, :ban}`.
  The ban is the one looked up for the session's user, IP, and fingerprint; an
  anonymous actor with no ban passes.

  Read paths that precede a write use this function alone, checking only the ban;
  the write itself uses `verify_write_access/1` instead.
  """
  @spec verify_not_banned(actor :: Actor.t()) :: :ok | {:error, :ban}
  def verify_not_banned(%Actor{ban: nil}), do: :ok
  def verify_not_banned(%Actor{}), do: {:error, :ban}

  @doc """
  Verifies that `actor` may perform a write.

  Decides, in order:

    * `{:error, :ban}` when the actor carries an active ban;
    * `{:error, :unauthorized}` when the actor has no fingerprint;
    * `:ok` otherwise.

  The fingerprint requirement applies regardless of whether a user is signed in.
  """
  @spec verify_write_access(actor :: Actor.t()) ::
          :ok | {:error, :ban} | {:error, :unauthorized}
  def verify_write_access(%Actor{ban: ban}) when not is_nil(ban), do: {:error, :ban}
  def verify_write_access(%Actor{fingerprint: nil}), do: {:error, :unauthorized}
  def verify_write_access(%Actor{}), do: :ok
end
