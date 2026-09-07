defmodule Philomena.Forms do
  @moduledoc """
  Helpers for building and applying changesets for form schemas.

  Form schemas are modules that expose a `changeset/2` function. `change/1`
  builds a changeset for display, while `create/2` and `update/2` apply the
  corresponding Ecto action. `copy_errors/2` transfers validation errors to a
  separate form changeset.
  """

  @doc """
  Copies validation errors from `source_changeset` onto `target`.

  `target` may be a schema struct or an existing changeset. Error messages and
  options are preserved, which lets a persistence changeset report its errors
  through the form submitted by the caller.

  ## Examples

      iex> source = add_error(Ecto.Changeset.change(%Form{}), :anonymous, "is invalid")
      iex> copied = copy_errors(source, %Form{})
      iex> copied.errors
      [anonymous: {"is invalid", []}]

  """
  @spec copy_errors(Ecto.Changeset.t(source), target | Ecto.Changeset.t(target)) ::
          Ecto.Changeset.t(target)
        when source: struct(), target: struct()
  def copy_errors(%Ecto.Changeset{} = source_changeset, target) do
    Enum.reduce(source_changeset.errors, Ecto.Changeset.change(target), fn
      {field, {message, opts}}, target_changeset ->
        Ecto.Changeset.add_error(target_changeset, field, message, opts)
    end)
  end

  @doc """
  Builds a changeset for an optional `schema` using `attrs`.

  The schema module must provide a `changeset/2` function.

  ## Examples

      iex> changeset = change(%Form{description: "A description"})
      iex> changeset.data
      %Form{description: "A description"}

  """
  @spec change(source | nil) :: Ecto.Changeset.t(source) | nil when source: struct()
  def change(source) do
    if source do
      source.__struct__.changeset(source, %{})
    end
  end

  @doc """
  Validates `attrs` with `schema` and applies the `:create` action.

  The schema module must provide a `changeset/2` function.

  Returns `{:ok, struct}` when the form is valid, or `{:error, changeset}`
  when validation fails.

  ## Examples

      iex> {:ok, form} = create(Form, %{anonymous: true})
      iex> form.anonymous
      true

  """
  @spec create(module(), map()) :: {:ok, struct()} | {:error, Ecto.Changeset.t(struct())}
  def create(schema, attrs) do
    apply_attrs(schema, attrs, :create)
  end

  @doc """
  Validates `attrs` with `schema` and applies the `:update` action.

  The schema module must provide a `changeset/2` function.

  Returns `{:ok, struct}` when the form is valid, or `{:error, changeset}`
  when validation fails.

  ## Examples

      iex> {:ok, form} = update(Form, %{comments_locked: true})
      iex> form.comments_locked
      true

  """
  @spec update(module(), map()) :: {:ok, struct()} | {:error, Ecto.Changeset.t(struct())}
  def update(schema, attrs) do
    apply_attrs(schema, attrs, :update)
  end

  @spec apply_attrs(module(), map(), atom()) ::
          {:ok, struct()} | {:error, Ecto.Changeset.t(struct())}
  defp apply_attrs(schema, attrs, action) do
    schema
    |> struct!()
    |> schema.changeset(attrs)
    |> Ecto.Changeset.apply_action(action)
  end
end
