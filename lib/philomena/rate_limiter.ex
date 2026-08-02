defmodule Philomena.RateLimiter do
  @moduledoc """
  Per-identity rate limiting for controller-facing write operations.

  Contexts guard a rate-limited write by calling `check_rate_limit/2` before
  performing it and `record_action/3` after it succeeds. Counters live in
  Valkey under a per-operation key scoped to the acting identity - the actor's
  user when signed in, otherwise its IP - and expire `window` seconds after
  the last recorded action.

  The check boundary is inclusive: an operation is refused only once its
  counter exceeds the limit of 1, so with recording done once per successful
  write, two writes may land inside a single window and the third is refused.
  Staff (admins, moderators, assistants) and users with `bypass_rate_limits`
  set are never limited and record no counters; see `considered_for_limit?/1`.
  """

  alias Philomena.Attribution.Actor
  alias Philomena.Users.User

  @key_prefix "rl:"
  @limit 1

  @doc """
  Determine whether `actor` may perform `operation` right now.

  Returns `:ok` when the actor's counter for `operation` does not exceed the
  limit (or the actor is exempt), otherwise `{:error, :rate_limited}`.
  Should be used in tandem with `record_action/3`.

  ## Examples

      iex> check_rate_limit(actor, :post_create)
      :ok

      iex> check_rate_limit(actor_over_limit, :post_create)
      {:error, :rate_limited}

  """
  @spec check_rate_limit(Actor.t(), atom()) :: :ok | {:error, :rate_limited}
  def check_rate_limit(%Actor{} = actor, operation) do
    if considered_for_limit?(actor.user) do
      amt =
        String.to_integer(
          Redix.command!(redix_connection(), ["GET", key(actor, operation)]) || "0"
        )

      if amt <= @limit, do: :ok, else: {:error, :rate_limited}
    else
      :ok
    end
  end

  @doc """
  Record a successful, rate-limited `operation` by `actor`.

  Increments the actor's counter for `operation` and (re)starts its expiry
  `window`, in seconds. Exempt actors record nothing. Always returns `:ok`.
  Should be used in tandem with `check_rate_limit/2`.

  ## Examples

      iex> record_action(actor, :post_create, 15)
      :ok

  """
  @spec record_action(Actor.t(), atom(), pos_integer()) :: :ok
  def record_action(%Actor{} = actor, operation, window) do
    if considered_for_limit?(actor.user) do
      Redix.pipeline!(redix_connection(), [
        ["INCR", key(actor, operation)],
        ["EXPIRE", key(actor, operation), window]
      ])
    end

    :ok
  end

  # Resets all rate limits. Visible for testing.
  @doc false
  @spec reset_limits_globally!() :: :ok
  def reset_limits_globally! do
    case Redix.command!(redix_connection(), ["KEYS", "#{@key_prefix}*"]) do
      [] ->
        :ok

      keys ->
        Redix.command!(redix_connection(), ["DEL" | keys])
    end

    :ok
  end

  # Staff and rate-limit-bypassing users are never limited; everyone else,
  # anonymous or signed in, is.
  defp considered_for_limit?(nil), do: true

  defp considered_for_limit?(%User{role: role}) when role in ~w(admin moderator assistant),
    do: false

  defp considered_for_limit?(%User{bypass_rate_limits: true}), do: false
  defp considered_for_limit?(%User{}), do: true

  defp key(%Actor{} = actor, operation), do: "#{@key_prefix}#{operation}:#{scope(actor)}"

  defp scope(%Actor{user: nil, ip: ip}), do: "i:#{ip}"
  defp scope(%Actor{user: user}), do: "u:#{user.id}"

  defp redix_connection, do: :redix
end
