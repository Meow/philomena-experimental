defmodule PhilomenaWeb.Topic.Post.ReportController do
  use PhilomenaWeb, :controller

  alias PhilomenaWeb.ReportController
  alias PhilomenaWeb.ReportView
  alias Philomena.Posts

  plug PhilomenaWeb.CaptchaPlug
  plug PhilomenaWeb.CheckCaptchaPlug when action in [:create]

  action_fallback PhilomenaWeb.FallbackController

  def new(conn, %{"forum_id" => forum_id, "topic_id" => topic_id, "post_id" => post_id}) do
    with {:ok, {topic, post, changeset}} <-
           Posts.load_post_for_report(conn.assigns.actor, forum_id, topic_id, post_id) do
      action = ~p"/forums/#{topic.forum}/topics/#{topic}/posts/#{post}/reports"

      conn
      |> put_view(ReportView)
      |> render("new.html", reportable: post, changeset: changeset, action: action)
    end
  end

  def create(
        conn,
        %{"forum_id" => forum_id, "topic_id" => topic_id, "post_id" => post_id} = params
      ) do
    with {:ok, {topic, post}} <-
           Posts.load_post_for_report_creation(conn.assigns.actor, forum_id, topic_id, post_id) do
      action = ~p"/forums/#{topic.forum}/topics/#{topic}/posts/#{post}/reports"

      ReportController.create(conn, action, "Post", post, params)
    end
  end
end
