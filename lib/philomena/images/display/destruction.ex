defmodule Philomena.Images.Display.Destruction do
  @moduledoc """
  Presentation data for an image destruction control.

  Contains a changeset.

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
    end

    @doc false
    def changeset(destruction_form, attrs \\ %{}) do
      cast(destruction_form, attrs, [])
    end
  end

  @enforce_keys [:changeset]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          changeset: Ecto.Changeset.t(Form.t())
        }

  @doc false
  @spec render(Actor.t(), Image.t()) :: t() | nil
  def render(%Actor{} = actor, %Image{} = image) do
    if image_permitted?(actor, :destroy, image) and image.hidden_from_users and
         not image.destroyed_content do
      %__MODULE__{
        changeset: Forms.change(Form, %{})
      }
    end
  end
end
