defmodule Philomena.Loader do
  @moduledoc """
  Shared helpers for turning an id into a loaded record.

  Context functions repeatedly parse an id, load the record, and authorize the
  actor against it. These helpers capture that shape so it lives in one place.

  An id that no `integer` column could hold is `{:error, :not_found}` (via
  `Philomena.IntegerId.parse/1`).
  """

  import Ecto.Query, only: [preload: 2]
  import Philomena.Authorization, only: [authorize: 3]

  alias Philomena.Repo
  alias Philomena.IntegerId
  alias Philomena.Authorization

  @typedoc "Type of acceptable actor inputs."
  @type actor :: Authorization.actor()

  @typedoc "Type of acceptable integer ID inputs."
  @type integer_id :: IntegerId.integer_id()

  @doc """
  Loads the `queryable` record named by `id`, applying `preloads`, and authorizes
  `actor` for `action` on it.

  The record is authorized before its existence is checked, so a well-formed id
  that names no row is authorized as `nil`: no ordinary rule permits `nil`, so it
  is `{:error, :unauthorized}`, while an actor whose grant covers `nil` instead
  gets `{:error, :not_found}`. An id that no `integer` column could hold is
  `{:error, :not_found}`.

  Returns `{:ok, record}`, `{:error, :unauthorized}`, or `{:error, :not_found}`.

  ## Examples

      iex> fetch_and_authorize(Channel, actor, :edit, "1")
      {:ok, %Channel{}}

      iex> fetch_and_authorize(Channel, actor, :edit, "not-a-number")
      {:error, :not_found}

  """
  @spec fetch_and_authorize(
          queryable :: Ecto.Queryable.t(),
          actor :: actor(),
          action :: atom(),
          id :: integer_id(),
          preloads :: list()
        ) ::
          {:ok, struct()} | {:error, :unauthorized | :not_found}
  def fetch_and_authorize(queryable, actor, action, id, preloads \\ []) do
    case IntegerId.parse(id) do
      {:ok, id} ->
        record =
          queryable
          |> preload(^preloads)
          |> Repo.get(id)

        with :ok <- authorize(actor, action, record),
             %{__struct__: _} <- record do
          {:ok, record}
        else
          {:error, :unauthorized} -> {:error, :unauthorized}
          nil -> {:error, :not_found}
        end

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Loads the `queryable` record named by `id`, applying `preloads`, with no
  authorization.

  A missing row, or an id that no `integer` column could hold, is
  `{:error, :not_found}`.

  Returns `{:ok, record}` or `{:error, :not_found}`.

  ## Examples

      iex> fetch(SubnetBan, "1")
      {:ok, %SubnetBan{}}

      iex> fetch(SubnetBan, "999999999")
      {:error, :not_found}

  """
  @spec fetch(
          queryable :: Ecto.Queryable.t(),
          id :: integer_id(),
          preloads :: list()
        ) ::
          {:ok, struct()} | {:error, :not_found}
  def fetch(queryable, id, preloads \\ []) do
    case IntegerId.parse(id) do
      {:ok, id} ->
        queryable
        |> preload(^preloads)
        |> Repo.get(id)
        |> case do
          nil -> {:error, :not_found}
          record -> {:ok, record}
        end

      :error ->
        {:error, :not_found}
    end
  end
end
