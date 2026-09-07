defmodule Philomena.Images.Display.Description do
  @moduledoc """
  Presentation data for an image description edit control.

  Contains a changeset and the raw description.

  Omitted when the control is unavailable to the actor.
  """

  import Philomena.Images.Display.Authorization

  alias Philomena.Attribution.Actor
  alias Philomena.Images.Image
  alias Philomena.Forms

  defmodule Form do
    use Ecto.Schema
    import Ecto.Changeset

    @type t :: %__MODULE__{}

    embedded_schema do
      field :description
    end

    @doc false
    def changeset(description_form, attrs \\ %{}) do
      cast(description_form, attrs, [:description])
    end
  end

  @enforce_keys [:changeset, :description]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          changeset: Ecto.Changeset.t(Form.t()),
          description: String.t()
        }

  @doc false
  @spec render(Actor.t(), Image.t()) :: t() | nil
  def render(%Actor{} = actor, %Image{} = image) do
    if image_permitted?(actor, :edit_description, image) do
      %__MODULE__{
        changeset: Forms.change(Form, %{description: image.description}),
        description: image.description
      }
    end
  end
end
