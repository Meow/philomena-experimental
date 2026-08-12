defmodule Philomena.Multi do
  @moduledoc """
  `m:Ecto.Multi` wrapper with locking utilities and deferred action semantics.
  """

  import Ecto.Query, only: [lock: 2]

  @enforce_keys [:multi, :on_commit]
  defstruct [:multi, on_commit: []]

  @type t :: %__MODULE__{
          multi: Ecto.Multi.t(),
          on_commit: list((Ecto.Multi.changes() -> any()))
        }

  @type name :: Ecto.Multi.name()
  @type changes :: Ecto.Multi.changes()

  @doc """
  Runs a query and stores all results in the Multi.

  The `name` must be unique within the Multi.

  The remaining arguments and options are the same as in `c:Ecto.Repo.all/2`.

  ## Example

      Multi.new()
      |> Multi.all(:all, Post)
      |> Multi.transact()

      Multi.new()
      |> Multi.all(:all, fn _changes -> Post end)
      |> Multi.transact()

  """
  @spec all(
          t(),
          Ecto.Multi.name(),
          queryable :: Ecto.Queryable.t() | (Ecto.Multi.changes() -> Ecto.Queryable.t()),
          opts :: Keyword.t()
        ) :: t()
  def all(%__MODULE__{} = multi, name, queryable_or_fun, opts \\ []) do
    update_in(multi.multi, &Ecto.Multi.all(&1, name, queryable_or_fun, opts))
  end

  @doc """
  Appends the second Multi to the first.

  All names must be unique within both structures.

  ## Example

      iex> lhs = Multi.new() |> Multi.run(:left, fn _, changes -> {:ok, changes} end)
      iex> rhs = Multi.new() |> Multi.run(:right, fn _, changes -> {:error, changes} end)
      iex> Multi.append(lhs, rhs) |> Multi.to_list |> Keyword.keys
      [:left, :right]

  """
  @spec append(t(), t()) :: t()
  def append(%__MODULE__{} = lhs, %__MODULE__{} = rhs) do
    multi = Ecto.Multi.append(lhs.multi, rhs.multi)
    on_commit = lhs.on_commit ++ rhs.on_commit

    %__MODULE__{multi: multi, on_commit: on_commit}
  end

  @doc """
  Adds a delete operation to the Multi.

  The `name` must be unique within the Multi.

  The remaining arguments and options are the same as in `c:Ecto.Repo.delete/2`.

  ## Example

      post = MyApp.Repo.get!(Post, 1)
      Multi.new()
      |> Multi.delete(:delete, post)
      |> Multi.transact()

      Multi.new()
      |> Multi.run(:post, fn repo, _changes ->
        case repo.get(Post, 1) do
          nil -> {:error, :not_found}
          post -> {:ok, post}
        end
      end)
      |> Multi.delete(:delete, fn %{post: post} ->
        # Others validations
        post
      end)
      |> Multi.transact()

  """
  @spec delete(
          t(),
          Ecto.Multi.name(),
          Ecto.Changeset.t()
          | Ecto.Schema.t()
          | (Ecto.Multi.changes() -> Ecto.Changeset.t() | Ecto.Schema.t()),
          Keyword.t()
        ) :: t
  def delete(%__MODULE__{} = multi, name, changeset_or_struct_fun, opts \\ []) do
    update_in(multi.multi, &Ecto.Multi.delete(&1, name, changeset_or_struct_fun, opts))
  end

  @doc """
  Adds a `delete_all` operation to the Multi.

  Accepts the same arguments and options as `c:Ecto.Repo.delete_all/2`.

  ## Example

      queryable = from(p in Post, where: p.id < 5)
      Multi.new()
      |> Multi.delete_all(:delete_all, queryable)
      |> Multi.transact()

      Multi.new()
      |> Multi.run(:post, fn repo, _changes ->
        case repo.get(Post, 1) do
          nil -> {:error, :not_found}
          post -> {:ok, post}
        end
      end)
      |> Multi.delete_all(:delete_all, fn %{post: post} ->
        # Others validations
        from(c in Comment, where: c.post_id == ^post.id)
      end)
      |> Multi.transact()

  """
  @spec delete_all(
          t(),
          Ecto.Multi.name(),
          Ecto.Queryable.t() | (Ecto.Multi.changes() -> Ecto.Queryable.t()),
          Keyword.t()
        ) :: t()
  def delete_all(%__MODULE__{} = multi, name, queryable_or_fun, opts \\ []) do
    update_in(multi.multi, &Ecto.Multi.delete_all(&1, name, queryable_or_fun, opts))
  end

  @doc """
  Causes the Multi to fail with the given value.

  Running the Multi in a transaction will execute
  no previous steps and return the value of the first
  error added.
  """
  @spec error(t(), Ecto.Multi.name(), error :: term()) :: t()
  def error(%__MODULE__{} = multi, name, value) do
    update_in(multi.multi, name, value)
  end

  @doc """
  Checks if an entry matching the given query exists and stores a boolean in the Multi.

  The `name` must be unique within the Multi.

  The remaining arguments and options are the same as in `c:Ecto.Repo.exists?/2`.

  ## Example

      Multi.new()
      |> Multi.exists?(:post, Post)
      |> Multi.transact()

      Multi.new()
      |> Multi.exists?(:post, fn _changes -> Post end)
      |> Multi.transact()

  """
  @spec exists?(
          t(),
          Ecto.Multi.name(),
          queryable :: Ecto.Queryable.t() | (Ecto.Multi.changes() -> Ecto.Queryable.t()),
          opts :: Keyword.t()
        ) :: t()
  def exists?(%__MODULE__{} = multi, name, queryable_or_fun, opts \\ []) do
    update_in(multi.multi, &Ecto.Multi.exists?(&1, name, queryable_or_fun, opts))
  end

  @doc """
  Adds an insert operation to the Multi.

  The `name` must be unique within the Multi.

  The remaining arguments and options are the same as in `c:Ecto.Repo.insert/2`.

  ## Example

      Multi.new()
      |> Multi.insert(:insert, %Post{title: "first"})
      |> Multi.transact()

      Multi.new()
      |> Multi.insert(:post, %Post{title: "first"})
      |> Multi.insert(:comment, fn %{post: post} ->
        Ecto.build_assoc(post, :comments)
      end)
      |> Multi.transact()

  """
  @spec insert(
          t(),
          Ecto.Multi.name(),
          Ecto.Changeset.t()
          | Ecto.Schema.t()
          | (Ecto.Multi.changes() -> Ecto.Changeset.t() | Ecto.Schema.t()),
          Keyword.t()
        ) :: t
  def insert(%__MODULE__{} = multi, name, changeset_or_struct_or_fun, opts \\ []) do
    update_in(multi.multi, &Ecto.Multi.insert(&1, name, changeset_or_struct_or_fun, opts))
  end

  @doc """
  Adds an `insert_all` operation to the Multi.

  Accepts the same arguments and options as `c:Ecto.Repo.insert_all/3`.

  ## Example

      posts = [%{title: "My first post"}, %{title: "My second post"}]
      Multi.new()
      |> Multi.insert_all(:insert_all, Post, posts)
      |> Multi.transact()

      Multi.new()
      |> Multi.run(:post, fn repo, _changes ->
        case repo.get(Post, 1) do
          nil -> {:error, :not_found}
          post -> {:ok, post}
        end
      end)
      |> Multi.insert_all(:insert_all, Comment, fn %{post: post} ->
        # Others validations

        entries
        |> Enum.map(fn comment ->
          Map.put(comment, :post_id, post.id)
        end)
      end)
      |> Multi.transact()

  """
  @spec insert_all(
          t(),
          Ecto.Multi.name(),
          term(),
          entries_or_query_or_fun ::
            [map() | Keyword.t()]
            | (Ecto.Multi.changes() -> [map() | Keyword.t()])
            | Ecto.Query.t(),
          Keyword.t()
        ) :: t
  def insert_all(
        %__MODULE__{} = multi,
        name,
        schema_or_source,
        entries_or_query_or_fun,
        opts \\ []
      ) do
    update_in(
      multi.multi,
      &Ecto.Multi.insert_all(&1, name, schema_or_source, entries_or_query_or_fun, opts)
    )
  end

  @doc """
  Inserts or updates a changeset depending on whether or not the changeset was persisted.

  The `name` must be unique within the Multi.

  The remaining arguments and options are the same as in `c:Ecto.Repo.insert_or_update/2`.

  ## Example

      changeset = Post.changeset(%Post{}, %{title: "New title"})
      Multi.new()
      |> Multi.insert_or_update(:insert_or_update, changeset)
      |> Multi.transact()

      Multi.new()
      |> Multi.run(:post, fn repo, _changes ->
        {:ok, repo.get(Post, 1) || %Post{}}
      end)
      |> Multi.insert_or_update(:update, fn %{post: post} ->
        Ecto.Changeset.change(post, title: "New title")
      end)
      |> Multi.transact()

  """
  @spec insert_or_update(
          t(),
          Ecto.Multi.name(),
          Ecto.Changeset.t() | (Ecto.Multi.changes() -> Ecto.Changeset.t()),
          Keyword.t()
        ) :: t()
  def insert_or_update(%__MODULE__{} = multi, name, changeset_or_fun, opts \\ []) do
    update_in(multi.multi, &Ecto.Multi.insert_or_update(&1, name, changeset_or_fun, opts))
  end

  @doc """
  Inspects results from a Multi.

  By default, the name is shown as a label to the inspect. Custom labels are
  supported through the `IO.inspect/2` `label` option.

  ## Options

  All options for IO.inspect/2 are supported, as well as:

    * `:only` - A field or a list of fields to inspect, will print the entire
      map by default.

  ## Examples

      Multi.new()
      |> Multi.insert(:person_a, changeset)
      |> Multi.insert(:person_b, changeset)
      |> Multi.inspect()
      |> Multi.transact()

  Prints:
      %{person_a: %Person{...}, person_b: %Person{...}}

  We can use the `:only` option to limit which fields will be printed:

      Multi.new()
      |> Multi.insert(:person_a, changeset)
      |> Multi.insert(:person_b, changeset)
      |> Multi.inspect(only: :person_a)
      |> Multi.transact()

  Prints:
      %{person_a: %Person{...}}

  """
  @spec inspect(t(), Keyword.t()) :: t()
  def inspect(%__MODULE__{} = multi, opts \\ []) do
    update_in(multi.multi, &Ecto.Multi.inspect(&1, opts))
  end

  @doc """
  Returns an empty `Multi` struct.

  ## Example

      iex> Multi.new() |> Multi.to_list()
      []

  """
  @spec new() :: t()
  def new do
    %__MODULE__{multi: Ecto.Multi.new(), on_commit: []}
  end

  @doc """
  Runs a query expecting one result and stores the result in the Multi.

  The `name` must be unique within the Multi.

  The remaining arguments and options are the same as in `c:Ecto.Repo.one/2`.

  ## Example

      Multi.new()
      |> Multi.one(:post, Post)
      |> Multi.one(:author, fn %{post: post} ->
        from(a in Author, where: a.id == ^post.author_id)
      end)
      |> Multi.transact()

  """
  @spec one(
          t(),
          Ecto.Multi.name(),
          queryable :: Ecto.Queryable.t() | (Ecto.Multi.changes() -> Ecto.Queryable.t()),
          opts :: Keyword.t()
        ) :: t()
  def one(%__MODULE__{} = multi, name, queryable_or_fun, opts \\ []) do
    update_in(multi.multi, &Ecto.Multi.one(&1, name, queryable_or_fun, opts))
  end

  @doc """
  Adds a value to the changes so far under the given name.

  The given `value` is added to the Multi before the transaction starts.
  If you would like to run arbitrary functions as part of your transaction,
  see `run/3` or `run/5`.

  ## Example

  Imagine there is an existing company schema that you retrieved from
  the database. You can insert it as a change in the Multi using `put/3`:

      Multi.new()
      |> Multi.put(:company, company)
      |> Multi.insert(:user, fn changes -> User.changeset(changes.company) end)
      |> Multi.insert(:person, fn changes -> Person.changeset(changes.user, changes.company) end)
      |> Multi.transact()

  In the example above, there isn't a significant benefit in putting
  the `company` in the Multi because you could also access the
  `company` variable directly inside the anonymous function.

  However, the benefit of `put/3` is seen when composing `Ecto.Multi`s.
  If the insert operations above were defined in another module,
  you could use `put(:company, company)` to inject changes that
  will be accessed by other functions down the chain, removing
  the need to pass both `multi` and `company` values around.
  """
  @spec put(t(), Ecto.Multi.name(), any()) :: t()
  def put(%__MODULE__{} = multi, name, value) do
    update_in(multi.multi, &Ecto.Multi.put(&1, name, value))
  end

  @doc """
  Adds a function to run as part of the Multi.

  The function should return either `{:ok, value}` or `{:error, value}`,
  and receives the repo as the first argument and the changes so far
  as the second argument.

  ## Example

      Multi.run(multi, :write, fn _repo, %{image: image} ->
        with :ok <- File.write(image.name, image.contents) do
          {:ok, nil}
        end
      end)

  """
  @spec run(t(), Ecto.Multi.name(), Ecto.Multi.run()) :: t()
  def run(%__MODULE__{} = multi, name, run) do
    update_in(multi.multi, &Ecto.Multi.run(&1, name, run))
  end

  @doc """
  Returns the list of operations stored in the Multi.

  Always use this function when you need to access the operations you
  have defined in `Multi`. Inspecting the `Multi` struct internals
  directly is discouraged.
  """
  @spec to_list(t()) :: [{Ecto.Multi.name(), term()}]
  def to_list(%__MODULE__{} = multi) do
    Ecto.Multi.to_list(multi.multi)
  end

  @doc """
  Adds an update operation to the Multi.

  The `name` must be unique within the Multi.

  The remaining arguments and options are the same as in `c:Ecto.Repo.update/2`.

  ## Example

      post = MyApp.Repo.get!(Post, 1)
      changeset = Ecto.Changeset.change(post, title: "New title")
      Multi.new()
      |> Multi.update(:update, changeset)
      |> Multi.transact()

      Multi.new()
      |> Multi.insert(:post, %Post{title: "first"})
      |> Multi.update(:fun, fn %{post: post} ->
        Ecto.Changeset.change(post, title: "New title")
      end)
      |> Multi.transact()

  """
  @spec update(
          t(),
          Ecto.Multi.name(),
          Ecto.Changeset.t() | (Ecto.Multi.changes() -> Ecto.Changeset.t()),
          Keyword.t()
        ) :: t()
  def update(%__MODULE__{} = multi, name, changeset_or_fun, opts \\ []) do
    update_in(multi.multi, &Ecto.Multi.update(&1, name, changeset_or_fun, opts))
  end

  @doc """
  Adds an `update_all` operation to the Multi.

  Accepts the same arguments and options as `c:Ecto.Repo.update_all/3`.

  ## Example

      Multi.new()
      |> Multi.update_all(:update_all, Post, set: [title: "New title"])
      |> Multi.transact()

      Multi.new()
      |> Multi.run(:post, fn repo, _changes ->
        case repo.get(Post, 1) do
          nil -> {:error, :not_found}
          post -> {:ok, post}
        end
      end)
      |> Multi.update_all(:update_all, fn %{post: post} ->
        # Others validations
        from(c in Comment, where: c.post_id == ^post.id, update: [set: [title: "New title"]])
      end, [])
      |> Multi.transact()

  """
  @spec update_all(
          t(),
          Ecto.Multi.name(),
          Ecto.Queryable.t() | (Ecto.Multi.changes() -> Ecto.Queryable.t()),
          Keyword.t(),
          Keyword.t()
        ) :: t
  def update_all(%__MODULE__{} = multi, name, queryable_or_fun, updates, opts \\ []) do
    update_in(multi.multi, &Ecto.Multi.update_all(&1, name, queryable_or_fun, updates, opts))
  end

  @doc """
  Locks a query result for update, or aborts the transaction if it was not found.
  """
  @spec lock_one(t(), Ecto.Multi.name(), Ecto.Queryable.t()) :: t()
  def lock_one(%__MODULE__{} = multi, name, queryable) do
    lock_fn =
      fn repo, _changes ->
        case repo.one(lock(queryable, "FOR UPDATE")) do
          nil -> {:error, :not_found}
          result -> {:ok, result}
        end
      end

    update_in(multi.multi, &Ecto.Multi.run(&1, name, lock_fn))
  end

  @doc """
  Run the Multi steps inside a transaction.

  See `c:Ecto.Repo.transact/2` for more information.
  """
  @spec transact(t(), Keyword.t()) :: {:ok, Ecto.Multi.changes()} | Ecto.Multi.failure()
  def transact(%__MODULE__{} = multi, opts \\ []) do
    multi.multi
    |> Philomena.Repo.transact(opts)
    |> case do
      {:ok, changes} ->
        :ok =
          multi.on_commit
          |> Enum.reverse()
          |> Enum.each(& &1.(changes))

        {:ok, changes}

      error ->
        error
    end
  end

  @doc """
  Registers a callback to occur when the Multi commits.
  """
  @spec on_commit(t(), (Ecto.Multi.changes() -> any())) :: t()
  def on_commit(%__MODULE__{} = multi, fun) when is_function(fun, 1) do
    update_in(multi.on_commit, &([fun] ++ &1))
  end
end
