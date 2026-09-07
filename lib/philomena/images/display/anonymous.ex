defmodule Philomena.Images.Display.Anonymous do
  @moduledoc """
  Presentation data for an image's anonymity control.

  Contains a changeset and the `anonymous?` value.

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
      field :anonymous, :boolean
    end

    @doc false
    def changeset(anonymous_form, attrs \\ %{}) do
      anonymous_form
      |> cast(attrs, [:anonymous])
      |> validate_required(:anonymous)
    end
  end

  @enforce_keys [:changeset, :anonymous?]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          changeset: Ecto.Changeset.t(Form.t()),
          anonymous?: boolean()
        }

  @doc false
  @spec render(Actor.t(), Image.t()) :: t() | nil
  def render(%Actor{} = actor, %Image{} = image) do
    if image_permitted?(actor, :update_anonymous, image) do
      %__MODULE__{
        changeset: Forms.change(Form, %{anonymous: image.anonymous}),
        anonymous?: image.anonymous
      }
    end
  end
end
