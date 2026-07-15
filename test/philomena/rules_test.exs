defmodule Philomena.RulesTest do
  @moduledoc """
  Context-level tests for the controller-facing `Philomena.Rules` functions.

  These pin the edit-gated index visibility (staff see hidden and internal rules,
  everyone else only the visible ones), the show loader's distinct
  `{:error, :rule_hidden}` shape for a hidden rule a viewer may not edit, the
  position parsing, and the admin-only create/edit/update authorization matrix.
  """

  use Philomena.DataCase, async: true

  import Philomena.AttributionFixtures, only: [actor: 0, actor: 1]
  import Philomena.RulesFixtures
  import Philomena.UsersFixtures

  alias Philomena.Rules
  alias Philomena.Rules.Rule

  describe "list_rules_for/1" do
    test "an admin sees hidden and internal rules alongside visible ones" do
      visible = rule_fixture()
      hidden = rule_fixture(%{hidden: true})
      internal = rule_fixture(%{internal: true})

      ids = Enum.map(Rules.list_rules_for(actor(admin_user_fixture())), & &1.id)
      assert visible.id in ids
      assert hidden.id in ids
      assert internal.id in ids
    end

    test "a regular user sees only the visible rules" do
      visible = rule_fixture()
      hidden = rule_fixture(%{hidden: true})
      internal = rule_fixture(%{internal: true})

      ids = Enum.map(Rules.list_rules_for(actor(confirmed_user_fixture())), & &1.id)
      assert visible.id in ids
      refute hidden.id in ids
      refute internal.id in ids
    end

    test "an anonymous viewer sees only the visible rules" do
      visible = rule_fixture()
      hidden = rule_fixture(%{hidden: true})

      ids = Enum.map(Rules.list_rules_for(actor()), & &1.id)
      assert visible.id in ids
      refute hidden.id in ids
    end
  end

  describe "load_rule_for_show/2" do
    test "loads a visible rule by position for an anonymous viewer" do
      rule = rule_fixture()

      assert {:ok, loaded} = Rules.load_rule_for_show(actor(), to_string(rule.position))
      assert loaded.id == rule.id
    end

    test "a hidden rule is rule_hidden for a viewer who may not edit it" do
      rule = rule_fixture(%{hidden: true})

      assert Rules.load_rule_for_show(actor(confirmed_user_fixture()), to_string(rule.position)) ==
               {:error, :rule_hidden}
    end

    test "an internal rule is rule_hidden for a viewer who may not edit it" do
      rule = rule_fixture(%{internal: true})

      assert Rules.load_rule_for_show(actor(), to_string(rule.position)) == {:error, :rule_hidden}
    end

    test "an admin may show a hidden rule" do
      rule = rule_fixture(%{hidden: true})

      assert {:ok, loaded} =
               Rules.load_rule_for_show(actor(admin_user_fixture()), to_string(rule.position))

      assert loaded.id == rule.id
    end

    test "a non-integer position is not-found" do
      assert Rules.load_rule_for_show(actor(), "not-a-number") == {:error, :not_found}
    end

    test "an unknown well-formed position is unauthorized for a user, not-found for an admin" do
      assert Rules.load_rule_for_show(actor(confirmed_user_fixture()), "2147483647") ==
               {:error, :unauthorized}

      assert Rules.load_rule_for_show(actor(admin_user_fixture()), "2147483647") ==
               {:error, :not_found}
    end
  end

  describe "load_new_rule/1" do
    test "an admin gets a blank changeset" do
      assert {:ok, %Ecto.Changeset{data: %Rule{}}} =
               Rules.load_new_rule(actor(admin_user_fixture()))
    end

    test "a regular user is unauthorized" do
      assert Rules.load_new_rule(actor(confirmed_user_fixture())) == {:error, :unauthorized}
    end

    test "an anonymous viewer is unauthorized" do
      assert Rules.load_new_rule(actor()) == {:error, :unauthorized}
    end
  end

  describe "create_rule/2" do
    test "an admin creates a rule and its initial version" do
      unique = System.unique_integer([:positive])

      assert {:ok, [%Rule{} = rule, _version]} =
               Rules.create_rule(actor(admin_user_fixture()), %{
                 name: "New Rule ##{unique}",
                 position: unique
               })

      assert Rules.find_rule(rule.id)
    end

    test "invalid attrs are a rejected changeset" do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Rules.create_rule(actor(admin_user_fixture()), %{name: ""})

      refute changeset.valid?
    end

    test "a regular user is unauthorized" do
      assert Rules.create_rule(actor(confirmed_user_fixture()), %{name: "x", position: 1}) ==
               {:error, :unauthorized}
    end
  end

  describe "load_rule_for_edit/2" do
    test "an admin loads a rule and a changeset" do
      rule = rule_fixture()

      assert {:ok, {%Rule{} = loaded, %Ecto.Changeset{}}} =
               Rules.load_rule_for_edit(actor(admin_user_fixture()), to_string(rule.position))

      assert loaded.id == rule.id
    end

    test "a regular user is unauthorized" do
      rule = rule_fixture()

      assert Rules.load_rule_for_edit(actor(confirmed_user_fixture()), to_string(rule.position)) ==
               {:error, :unauthorized}
    end

    test "an unknown well-formed position is unauthorized for a user, not-found for an admin" do
      assert Rules.load_rule_for_edit(actor(confirmed_user_fixture()), "2147483647") ==
               {:error, :unauthorized}

      assert Rules.load_rule_for_edit(actor(admin_user_fixture()), "2147483647") ==
               {:error, :not_found}
    end
  end

  describe "update_rule/3" do
    test "an admin updates a rule and stores a new version" do
      rule = rule_fixture()

      assert {:ok, [%Rule{} = updated, _version]} =
               Rules.update_rule(actor(admin_user_fixture()), to_string(rule.position), %{
                 title: "Updated Title"
               })

      assert updated.title == "Updated Title"
      assert Rules.find_rule(rule.id).title == "Updated Title"
    end

    test "an invalid update carries the unchanged rule for re-rendering" do
      rule = rule_fixture()

      assert {:error, {%Rule{} = carried, %Ecto.Changeset{} = changeset}} =
               Rules.update_rule(actor(admin_user_fixture()), to_string(rule.position), %{
                 name: ""
               })

      assert carried.id == rule.id
      refute changeset.valid?
    end

    test "a regular user is unauthorized" do
      rule = rule_fixture()

      assert Rules.update_rule(actor(confirmed_user_fixture()), to_string(rule.position), %{
               title: "Hijacked"
             }) == {:error, :unauthorized}
    end

    test "a non-integer position is not-found" do
      assert Rules.update_rule(actor(admin_user_fixture()), "not-a-number", %{title: "x"}) ==
               {:error, :not_found}
    end
  end
end
