defmodule Philomena.ContextActionRenamesTest do
  use ExUnit.Case, async: true

  alias Philomena.ContextActionRenames

  test "parses matrix rows and retains arity-specific targets" do
    plan = """
    ### `Philomena.Example`

    | Current | Target |
    | --- | --- |
    | `search/1,3` | `query/1,3` |
    | `search/2` | `create/2` |
    """

    assert [
             %{module: Philomena.Example, old: :search, new: :query, arity: 1},
             %{module: Philomena.Example, old: :search, new: :query, arity: 3},
             %{module: Philomena.Example, old: :search, new: :create, arity: 2}
           ] = ContextActionRenames.parse_plan(plan)
  end

  test "renames public definitions and aliased calls by their arity" do
    source = """
    defmodule Philomena.Example do
      def search(value), do: value
      def search(one, two), do: {one, two}
      defp private_search(value), do: value
    end

    defmodule Caller do
      alias Philomena.Example, as: ExampleContext

      def run(value) do
        {ExampleContext.search(value), ExampleContext.search(value, value), :search}
      end
    end
    """

    mappings = [
      %{module: Philomena.Example, old: :search, new: :query, arity: 1},
      %{module: Philomena.Example, old: :search, new: :create, arity: 2}
    ]

    rewritten = ContextActionRenames.rewrite_string(source, mappings, comments: false)

    assert rewritten =~ "def query(value)"
    assert rewritten =~ "def create(one, two)"
    assert rewritten =~ "ExampleContext.query(value)"
    assert rewritten =~ "ExampleContext.create(value, value)"
    assert rewritten =~ ":search"
    refute rewritten =~ "private_query"
  end

  test "does not rename private functions or unrelated atoms" do
    source = """
    defmodule Philomena.Example do
      defp search(value), do: value
      def run(value), do: {search(value), :search, %{search: value}}
    end
    """

    mappings = [%{module: Philomena.Example, old: :search, new: :query, arity: 1}]

    assert ContextActionRenames.rewrite_string(source, mappings, comments: false) == source
  end

  test "comments can be rewritten without rewriting code" do
    source = """
    defmodule Philomena.Example do
      # search/1 is the public operation; :search is an event atom.
      def search(value), do: value
    end
    """

    mappings = [%{module: Philomena.Example, old: :search, new: :query, arity: 1}]

    assert ContextActionRenames.rewrite_string(source, mappings, comments_only: true) =~
             "# query/1 is the public operation; :search is an event atom."

    assert ContextActionRenames.rewrite_string(source, mappings, comments: false) =~
             "# search/1 is the public operation"
  end

  test "rewriting is idempotent when a target is also a source name" do
    source = """
    defmodule Philomena.Example do
      def unhide_image(image), do: image
      def delete_image_hide(image), do: image
    end
    """

    mappings = [
      %{module: Philomena.Example, old: :unhide_image, new: :delete_image_hide, arity: 1},
      %{
        module: Philomena.Example,
        old: :delete_image_hide,
        new: :delete_image_user_hide,
        arity: 1
      }
    ]

    rewritten = ContextActionRenames.rewrite_string(source, mappings, comments: false)

    assert ContextActionRenames.rewrite_string(rewritten, mappings, comments: false) == rewritten
  end
end
