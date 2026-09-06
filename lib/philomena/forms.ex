defmodule Philomena.Forms do
  import Ecto.Changeset

  @spec copy_errors(Ecto.Changeset.t(source), target | Ecto.Changeset.t(target)) ::
          Ecto.Changeset.t(target)
        when source: struct(), target: struct()
  def copy_errors(%Ecto.Changeset{} = source_changeset, target_schema) do
    Enum.reduce(source_changeset.errors, change(target_schema), fn
      {field, {message, opts}}, target_changeset ->
        add_error(target_changeset, field, message, opts)
    end)
  end

  @spec create(module(), map()) :: {:ok, struct()} | {:error, Ecto.Changeset.t(struct())}
  def create(schema, attrs) do
    apply_attrs(schema, attrs, :create)
  end

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
    |> apply_action(action)
  end
end
