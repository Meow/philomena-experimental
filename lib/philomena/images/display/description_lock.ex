defmodule Philomena.Images.Display.DescriptionLock do
  @moduledoc """
  Presentation data for an image's description lock control.

  Contains a changeset and whether the description is currently locked
  (`description_locked?`).

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
      field :description_locked, :boolean
    end

    @doc false
    def changeset(description_lock_form, attrs \\ %{}) do
      description_lock_form
      |> cast(attrs, [:description_locked])
      |> validate_required([:description_locked])
    end
  end

  @enforce_keys [:changeset, :description_locked?]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          changeset: Ecto.Changeset.t(Form.t()),
          description_locked?: boolean()
        }

  @doc false
  @spec render(Actor.t(), Image.t()) :: t() | nil
  def render(%Actor{} = actor, %Image{} = image) do
    if image_permitted?(actor, :lock_description, image) do
      description_locked? = not image.description_editing_allowed

      %__MODULE__{
        changeset: Forms.change(Form, %{description_locked: description_locked?}),
        description_locked?: description_locked?
      }
    end
  end
end
