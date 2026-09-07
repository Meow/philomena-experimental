defmodule Philomena.Images.Display.Description do
  @moduledoc """
  Presentation data for an image description.

  Contains a changeset, the raw description, and an `editable?` flag indicating
  whether the actor may edit the description.
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

  @enforce_keys [:changeset, :description, :editable?]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          changeset: Ecto.Changeset.t(Form.t()),
          description: String.t(),
          editable?: boolean()
        }

  @doc false
  @spec render(Actor.t(), Image.t()) :: t()
  def render(%Actor{} = actor, %Image{} = image) do
    %__MODULE__{
      changeset: Forms.change(Form, %{description: image.description}),
      description: image.description,
      editable?: image_permitted?(actor, :edit_description, image)
    }
  end
end
