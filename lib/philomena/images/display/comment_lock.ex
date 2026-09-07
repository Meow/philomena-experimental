defmodule Philomena.Images.Display.CommentLock do
  @moduledoc """
  Presentation data for an image's comment lock control.

  Contains a changeset and whether comments are currently locked
  (`comments_locked?`).

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
      field :comments_locked, :boolean
    end

    @doc false
    def changeset(comment_lock_form, attrs \\ %{}) do
      comment_lock_form
      |> cast(attrs, [:comments_locked])
      |> validate_required([:comments_locked])
    end
  end

  @enforce_keys [:changeset, :comments_locked?]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          changeset: Ecto.Changeset.t(Form.t()),
          comments_locked?: boolean()
        }

  @doc false
  @spec render(Actor.t(), Image.t()) :: t() | nil
  def render(%Actor{} = actor, %Image{} = image) do
    if image_permitted?(actor, :lock_comments, image) do
      comments_locked? = not image.commenting_allowed

      %__MODULE__{
        changeset: Forms.change(Form, %{comments_locked: comments_locked?}),
        comments_locked?: comments_locked?
      }
    end
  end
end
