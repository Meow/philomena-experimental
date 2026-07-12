defmodule Philomena.ModNotesTest do
  @moduledoc """
  Context-level tests for the controller-facing `Philomena.ModNotes` functions:
  the admin index (`load_mod_note_index/4`), the new/create form and insert
  (`new_mod_note/2`, `create_mod_note/2`), and the edit/update/delete actions on
  a possibly-nil load.

  These pin the staff authorization matrix (assistants and moderators may index,
  create, and touch their own notes; a moderator may not touch another
  moderator's note; an admin may touch any), the moderator attribution on
  create, the notable-filter branch of the index, and the unauthorized/not-found
  split on an unknown id.
  """

  use Philomena.DataCase, async: true

  import Philomena.ModNotesFixtures
  import Philomena.UsersFixtures

  alias Philomena.ModNotes
  alias Philomena.ModNotes.ModNote

  @pagination [page: 1, page_size: 25]

  # Note params in the shape the admin form posts. notable_id is a plain integer
  # (the relation is polymorphic, with no foreign key), so any id works.
  defp note_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      "notable_type" => "User",
      "notable_id" => confirmed_user_fixture().id,
      "body" => "Watching this one"
    })
  end

  describe "load_mod_note_index/4" do
    test "an anonymous viewer is unauthorized" do
      assert ModNotes.load_mod_note_index(nil, %{}, & &1, @pagination) ==
               {:error, :unauthorized}
    end

    test "a regular user is unauthorized" do
      assert ModNotes.load_mod_note_index(confirmed_user_fixture(), %{}, & &1, @pagination) ==
               {:error, :unauthorized}
    end

    test "an assistant, a moderator, and an admin are all authorized" do
      for actor <- [assistant_user_fixture(), moderator_user_fixture(), admin_user_fixture()] do
        assert {:ok, page} = ModNotes.load_mod_note_index(actor, %{}, & &1, @pagination)
        assert %Scrivener.Page{} = page
      end
    end

    test "the default view lists all notes newest first as {note, rendered} tuples" do
      moderator = moderator_user_fixture()
      note = mod_note_fixture(moderator)

      assert {:ok, page} = ModNotes.load_mod_note_index(moderator, %{}, & &1, @pagination)

      # The identity renderer pairs each note with itself.
      assert note.id in Enum.map(page.entries, fn {loaded, _rendered} -> loaded.id end)
    end

    test "the notable filter restricts to the matching notable" do
      moderator = moderator_user_fixture()
      wanted = mod_note_fixture(moderator, %{"notable_type" => "Report", "notable_id" => 12_345})
      other = mod_note_fixture(moderator, %{"notable_type" => "Report", "notable_id" => 67_890})

      assert {:ok, page} =
               ModNotes.load_mod_note_index(
                 moderator,
                 %{"notable_type" => "Report", "notable_id" => "12345"},
                 & &1,
                 @pagination
               )

      ids = Enum.map(page.entries, fn {loaded, _rendered} -> loaded.id end)
      assert wanted.id in ids
      refute other.id in ids
    end
  end

  describe "new_mod_note/2" do
    test "a moderator gets a changeset seeded from the params" do
      assert {:ok, changeset} =
               ModNotes.new_mod_note(moderator_user_fixture(), %{
                 "notable_type" => "Report",
                 "notable_id" => "7"
               })

      assert changeset.data.notable_type == "Report"
      assert changeset.data.notable_id == "7"
    end

    test "an assistant is authorized" do
      assert {:ok, _changeset} = ModNotes.new_mod_note(assistant_user_fixture(), %{})
    end

    test "a regular user is unauthorized" do
      assert ModNotes.new_mod_note(confirmed_user_fixture(), %{}) == {:error, :unauthorized}
    end

    test "an anonymous actor is unauthorized" do
      assert ModNotes.new_mod_note(nil, %{}) == {:error, :unauthorized}
    end
  end

  describe "create_mod_note/2" do
    test "a moderator creates a note attributed to themselves" do
      moderator = moderator_user_fixture()

      assert {:ok, %ModNote{} = note} = ModNotes.create_mod_note(moderator, note_attrs())
      assert note.moderator_id == moderator.id
      assert note.body == "Watching this one"
    end

    test "an assistant creates a note" do
      assistant = assistant_user_fixture()

      assert {:ok, %ModNote{} = note} = ModNotes.create_mod_note(assistant, note_attrs())
      assert note.moderator_id == assistant.id
    end

    test "a regular user is unauthorized" do
      assert ModNotes.create_mod_note(confirmed_user_fixture(), note_attrs()) ==
               {:error, :unauthorized}
    end

    test "an anonymous actor is unauthorized" do
      assert ModNotes.create_mod_note(nil, note_attrs()) == {:error, :unauthorized}
    end

    test "a blank body is a rejected changeset" do
      assert {:error, %Ecto.Changeset{} = changeset} =
               ModNotes.create_mod_note(moderator_user_fixture(), note_attrs(%{"body" => ""}))

      assert %{body: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "load_mod_note_for_edit/2" do
    test "a moderator loads their own note with a changeset" do
      moderator = moderator_user_fixture()
      note = mod_note_fixture(moderator)

      assert {:ok, {loaded, %Ecto.Changeset{}}} =
               ModNotes.load_mod_note_for_edit(moderator, to_string(note.id))

      assert loaded.id == note.id
    end

    test "a moderator may not edit another moderator's note" do
      note = mod_note_fixture(moderator_user_fixture())

      assert ModNotes.load_mod_note_for_edit(moderator_user_fixture(), to_string(note.id)) ==
               {:error, :unauthorized}
    end

    test "an admin may edit any note" do
      note = mod_note_fixture(moderator_user_fixture())

      assert {:ok, {loaded, %Ecto.Changeset{}}} =
               ModNotes.load_mod_note_for_edit(admin_user_fixture(), to_string(note.id))

      assert loaded.id == note.id
    end

    test "a regular user is unauthorized" do
      note = mod_note_fixture(moderator_user_fixture())

      assert ModNotes.load_mod_note_for_edit(confirmed_user_fixture(), to_string(note.id)) ==
               {:error, :unauthorized}
    end

    test "an unknown well-formed id is unauthorized for a moderator, not-found for an admin" do
      assert ModNotes.load_mod_note_for_edit(moderator_user_fixture(), "2147483647") ==
               {:error, :unauthorized}

      assert ModNotes.load_mod_note_for_edit(admin_user_fixture(), "2147483647") ==
               {:error, :not_found}
    end

    test "a non-integer id is not-found" do
      assert ModNotes.load_mod_note_for_edit(admin_user_fixture(), "not-a-number") ==
               {:error, :not_found}
    end
  end

  describe "update_mod_note/3" do
    test "a moderator updates their own note" do
      moderator = moderator_user_fixture()
      note = mod_note_fixture(moderator)

      assert {:ok, %ModNote{} = updated} =
               ModNotes.update_mod_note(moderator, to_string(note.id), %{"body" => "Edited body"})

      assert updated.body == "Edited body"
    end

    test "an admin updates any note" do
      note = mod_note_fixture(moderator_user_fixture())

      assert {:ok, %ModNote{body: "Edited by admin"}} =
               ModNotes.update_mod_note(admin_user_fixture(), to_string(note.id), %{
                 "body" => "Edited by admin"
               })
    end

    test "an invalid update is a rejected changeset" do
      moderator = moderator_user_fixture()
      note = mod_note_fixture(moderator)

      assert {:error, %Ecto.Changeset{} = changeset} =
               ModNotes.update_mod_note(moderator, to_string(note.id), %{"body" => ""})

      assert %{body: ["can't be blank"]} = errors_on(changeset)
    end

    test "a moderator may not update another moderator's note" do
      note = mod_note_fixture(moderator_user_fixture())

      assert ModNotes.update_mod_note(moderator_user_fixture(), to_string(note.id), %{
               "body" => "Edited body"
             }) == {:error, :unauthorized}
    end

    test "a regular user is unauthorized" do
      note = mod_note_fixture(moderator_user_fixture())

      assert ModNotes.update_mod_note(confirmed_user_fixture(), to_string(note.id), %{
               "body" => "Edited body"
             }) == {:error, :unauthorized}
    end

    test "an unknown well-formed id is unauthorized for a moderator, not-found for an admin" do
      assert ModNotes.update_mod_note(moderator_user_fixture(), "2147483647", %{"body" => "x"}) ==
               {:error, :unauthorized}

      assert ModNotes.update_mod_note(admin_user_fixture(), "2147483647", %{"body" => "x"}) ==
               {:error, :not_found}
    end

    test "a non-integer id is not-found" do
      assert ModNotes.update_mod_note(admin_user_fixture(), "not-a-number", %{"body" => "x"}) ==
               {:error, :not_found}
    end
  end

  describe "delete_mod_note/2" do
    test "a moderator deletes their own note" do
      moderator = moderator_user_fixture()
      note = mod_note_fixture(moderator)

      assert {:ok, %ModNote{}} = ModNotes.delete_mod_note(moderator, to_string(note.id))
      refute Repo.get(ModNote, note.id)
    end

    test "an admin deletes any note" do
      note = mod_note_fixture(moderator_user_fixture())

      assert {:ok, %ModNote{}} =
               ModNotes.delete_mod_note(admin_user_fixture(), to_string(note.id))

      refute Repo.get(ModNote, note.id)
    end

    test "a moderator may not delete another moderator's note" do
      note = mod_note_fixture(moderator_user_fixture())

      assert ModNotes.delete_mod_note(moderator_user_fixture(), to_string(note.id)) ==
               {:error, :unauthorized}

      assert Repo.get(ModNote, note.id)
    end

    test "a regular user is unauthorized" do
      note = mod_note_fixture(moderator_user_fixture())

      assert ModNotes.delete_mod_note(confirmed_user_fixture(), to_string(note.id)) ==
               {:error, :unauthorized}
    end

    test "an unknown well-formed id is unauthorized for a moderator, not-found for an admin" do
      assert ModNotes.delete_mod_note(moderator_user_fixture(), "2147483647") ==
               {:error, :unauthorized}

      assert ModNotes.delete_mod_note(admin_user_fixture(), "2147483647") == {:error, :not_found}
    end

    test "a non-integer id is not-found" do
      assert ModNotes.delete_mod_note(admin_user_fixture(), "not-a-number") ==
               {:error, :not_found}
    end
  end
end
