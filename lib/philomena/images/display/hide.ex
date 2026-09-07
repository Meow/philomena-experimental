defmodule Philomena.Images.Display.Hide do
  @moduledoc """
  Presentation data for an image's staff hide control.

  Contains a changeset, the current hide reason, and the hide presence.

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
      field :deletion_reason, :string
    end

    @doc false
    def changeset(hide_form, attrs \\ %{}) do
      hide_form
      |> cast(attrs, [:deletion_reason])
      |> validate_required([:deletion_reason])
    end
  end

  @enforce_keys [:changeset, :deletion_reason, :present?]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          changeset: Ecto.Changeset.t(Form.t()),
          deletion_reason: String.t(),
          present?: boolean()
        }

  @doc false
  @spec render(Actor.t(), Image.t()) :: t() | nil
  def render(%Actor{} = actor, %Image{} = image) do
    if image_permitted?(actor, :hide, image) do
      %__MODULE__{
        changeset: Forms.change(Form, %{deletion_reason: image.deletion_reason}),
        deletion_reason: image.deletion_reason,
        present?: image.hidden_from_users
      }
    end
  end
end
