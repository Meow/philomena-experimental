defmodule Philomena.FormHelpersTest do
  use ExUnit.Case, async: true

  import Ecto.Changeset

  alias Philomena.FormHelpers

  defmodule Form do
    use Ecto.Schema

    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field :first, :string
      field :second, :string
    end

    def changeset(form, attrs) do
      cast(form, attrs, [:first, :second])
    end
  end

  describe "copy_errors/2" do
    test "copies the source changeset action" do
      source =
        %Form{}
        |> change()
        |> add_error(:first, "is invalid")
        |> Map.replace!(:action, :update)

      assert %Ecto.Changeset{action: :update, errors: [first: {"is invalid", []}]} =
               FormHelpers.copy_errors(source, %Form{})
    end
  end

  describe "update/2" do
    test "applies attrs to the populated projection and returns only its changes" do
      form = %Form{first: "kept", second: "old"}

      assert {:ok, updated, %{second: "new"}} = FormHelpers.update(form, %{second: "new"})
      assert updated == %Form{first: "kept", second: "new"}
    end
  end
end
