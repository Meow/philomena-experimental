defmodule Philomena.Users.Uploader do
  @moduledoc """
  Upload and processing callback logic for User avatars.
  """

  alias Philomena.Multi
  alias Philomena.Users.User
  alias PhilomenaMedia.Uploader

  def analyze_upload(user, params) do
    Uploader.analyze_upload(user, "avatar", params["avatar"], &User.avatar_changeset/2)
  end

  def persist_upload(user) do
    Uploader.persist_upload(user, avatar_file_root(), "avatar")
  end

  def unpersist_old_upload(user) do
    Uploader.unpersist_old_upload(user, avatar_file_root(), "avatar")
  end

  def put_persist_upload_and_unpersist_old(multi, step) do
    Multi.on_commit(multi, fn %{^step => user} ->
      persist_upload(user)
      unpersist_old_upload(user)
    end)
  end

  def put_unpersist_old_upload(multi, step) do
    Multi.on_commit(multi, fn %{^step => user} -> unpersist_old_upload(user) end)
  end

  defp avatar_file_root do
    Application.get_env(:philomena, :avatar_file_root)
  end
end
