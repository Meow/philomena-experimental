defmodule Philomena.RateLimiterTest do
  # async: false because these counters live in Valkey, NOT Postgres: the Ecto
  # SQL sandbox does not roll them back. Every test uses a fresh user id / IP
  # and clears its own keys in an on_exit callback so nothing leaks into a
  # later test or a later `mix test` run.
  use Philomena.DataCase, async: false

  alias Philomena.Attribution.Actor
  alias Philomena.RateLimiter
  alias Philomena.Users.User

  # Lightweight, DB-free actors. The limiter only reads `user.id` (for the
  # scope key) plus `user.role` and `user.bypass_rate_limits` (for the
  # exemptions), and touches Valkey via Redix - it never hits Postgres - so a
  # bare struct with a unique id is enough and keeps the counters isolated per
  # test. The struct defaults (`role: "user"`, `bypass_rate_limits: false`)
  # make the plain actors subject to the limits.
  defp user_actor(user_attrs \\ []) do
    user = struct!(%User{id: System.unique_integer([:positive])}, user_attrs)
    %Actor{ip: unique_ip(), fingerprint: "d015c342859dde3", user: user}
  end

  defp anonymous_actor do
    %Actor{ip: unique_ip(), fingerprint: "d015c342859dde3", user: nil}
  end

  defp unique_ip do
    n = System.unique_integer([:positive])
    %Postgrex.INET{address: {203, 0, rem(div(n, 254), 254) + 1, rem(n, 254) + 1}, netmask: 32}
  end

  # Register cleanup of the counter keys an actor could have touched for the
  # given operations.
  defp track(%Actor{} = actor, operations) do
    on_exit(fn ->
      for op <- operations do
        Redix.command!(:redix, ["DEL", "rl:#{op}:u:#{actor.user && actor.user.id}"])
        Redix.command!(:redix, ["DEL", "rl:#{op}:i:#{actor.ip}"])
      end
    end)
  end

  defp raw_count(key), do: Redix.command!(:redix, ["GET", key])

  describe "the inclusive check boundary" do
    test "a fresh identity passes, and keeps passing until the counter exceeds the limit" do
      actor = anonymous_actor()
      track(actor, [:post_create])

      assert RateLimiter.check_rate_limit(actor, :post_create) == :ok
      assert RateLimiter.record_action(actor, :post_create, 60) == :ok

      # Counter at 1: still on the limit, so a second write is permitted.
      assert RateLimiter.check_rate_limit(actor, :post_create) == :ok
      assert RateLimiter.record_action(actor, :post_create, 60) == :ok

      # Counter at 2: past the limit, refused.
      assert RateLimiter.check_rate_limit(actor, :post_create) ==
               {:error, :rate_limited}
    end
  end

  describe "scoping" do
    test "a signed-in actor is scoped by user id, not IP" do
      actor = user_actor()
      track(actor, [:post_create])

      RateLimiter.record_action(actor, :post_create, 60)
      RateLimiter.record_action(actor, :post_create, 60)

      assert raw_count("rl:post_create:u:#{actor.user.id}") == "2"
      assert raw_count("rl:post_create:i:#{actor.ip}") == nil
      assert RateLimiter.check_rate_limit(actor, :post_create) == {:error, :rate_limited}

      # A different user on the same IP is unaffected.
      other = %Actor{actor | user: %User{id: System.unique_integer([:positive])}}
      track(other, [:post_create])
      assert RateLimiter.check_rate_limit(other, :post_create) == :ok
    end

    test "an anonymous actor is scoped by IP" do
      actor = anonymous_actor()
      track(actor, [:post_create])

      RateLimiter.record_action(actor, :post_create, 60)
      RateLimiter.record_action(actor, :post_create, 60)

      assert raw_count("rl:post_create:i:#{actor.ip}") == "2"
      assert RateLimiter.check_rate_limit(actor, :post_create) == {:error, :rate_limited}

      # A different anonymous IP is unaffected.
      assert RateLimiter.check_rate_limit(anonymous_actor(), :post_create) == :ok
    end

    test "operations count independently for the same identity" do
      actor = user_actor()
      track(actor, [:post_create, :topic_create])

      RateLimiter.record_action(actor, :post_create, 60)
      RateLimiter.record_action(actor, :post_create, 60)

      assert RateLimiter.check_rate_limit(actor, :post_create) == {:error, :rate_limited}
      assert RateLimiter.check_rate_limit(actor, :topic_create) == :ok
    end
  end

  describe "exemptions" do
    for role <- ~w(admin moderator assistant) do
      test "a #{role} is never limited and records no counter" do
        actor = user_actor(role: unquote(role))
        track(actor, [:post_create])

        RateLimiter.record_action(actor, :post_create, 60)
        RateLimiter.record_action(actor, :post_create, 60)
        RateLimiter.record_action(actor, :post_create, 60)

        assert raw_count("rl:post_create:u:#{actor.user.id}") == nil
        assert RateLimiter.check_rate_limit(actor, :post_create) == :ok
      end
    end

    test "a bypass_rate_limits user is never limited and records no counter" do
      actor = user_actor(bypass_rate_limits: true)
      track(actor, [:post_create])

      RateLimiter.record_action(actor, :post_create, 60)
      RateLimiter.record_action(actor, :post_create, 60)
      RateLimiter.record_action(actor, :post_create, 60)

      assert raw_count("rl:post_create:u:#{actor.user.id}") == nil
      assert RateLimiter.check_rate_limit(actor, :post_create) == :ok
    end

    test "a verified regular user is still limited" do
      actor = user_actor(verified: true)
      track(actor, [:post_create])

      RateLimiter.record_action(actor, :post_create, 60)
      RateLimiter.record_action(actor, :post_create, 60)

      assert RateLimiter.check_rate_limit(actor, :post_create) == {:error, :rate_limited}
    end
  end

  describe "expiry" do
    test "recording sets a TTL on the counter" do
      actor = user_actor()
      track(actor, [:post_create])

      RateLimiter.record_action(actor, :post_create, 60)

      ttl = Redix.command!(:redix, ["TTL", "rl:post_create:u:#{actor.user.id}"])
      assert ttl > 0 and ttl <= 60
    end
  end
end
