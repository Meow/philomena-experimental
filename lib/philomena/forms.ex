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
end
