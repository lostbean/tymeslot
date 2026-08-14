defmodule TymeslotWeb.Dashboard.SyncLinksIntegrationLabelsTest do
  @moduledoc """
  Choosing a direction between two accounts of the same provider.

  The reported problem: connecting two Google accounts stores the same
  hardcoded name for both — `google_oauth_helper.ex` writes the literal
  `"Google Calendar"` and nothing downstream revisits it — so the source and
  target selects offer two identical options and picking a direction is a
  guess. Both rows already carry the account they differ in.

  Kept apart from `SyncLinksSettingsTest` because it covers what the panel
  *calls* the calendars rather than what it does with them, and because that
  module is already at its line limit.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :calendar
  @moduletag :sync_links
  @moduletag :utils

  import Phoenix.LiveViewTest
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.SyncLink
  alias Tymeslot.Security.RateLimiter

  setup :setup_dashboard_user

  setup do
    RateLimiter.clear_all()
    :ok
  end

  defp google_account(user, email) do
    insert(:calendar_integration,
      user: user,
      provider: "google",
      name: "Google Calendar",
      provider_account_email: email,
      is_active: true
    )
  end

  defp source_option_labels(html) do
    # The prompt option carries no value; only the calendars are of interest.
    html
    |> Floki.parse_document!()
    |> Floki.find(~s(select[name="sync_link[source_integration_id]"] option))
    |> Enum.reject(&(Floki.attribute(&1, "value") in [[], [""]]))
    |> Enum.map(&String.trim(Floki.text(&1)))
  end

  describe "telling two accounts of one provider apart" do
    test "qualifies each option with its account", %{conn: conn, user: user} do
      google_account(user, "organiser@example.com")
      google_account(user, "second@example.com")

      {:ok, _view, html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      assert html =~ "organiser@example.com"
      assert html =~ "second@example.com"
    end

    test "leaves no option carrying the bare provider name", %{conn: conn, user: user} do
      google_account(user, "organiser@example.com")
      google_account(user, "second@example.com")

      {:ok, _view, html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      # The failure this guards is subtler than a missing email: qualifying one
      # option and not the other still leaves an ambiguous pair. No option may
      # read as the unqualified constant.
      labels = source_option_labels(html)

      assert length(labels) == 2
      refute Enum.any?(labels, &(&1 == "Google Calendar"))
    end

    test "names both ends of a saved link by account", %{conn: conn, user: user} do
      source = google_account(user, "organiser@example.com")
      target = google_account(user, "second@example.com")

      {:ok, _link} =
        SyncLink.create_link(user.id, %{
          "source_integration_id" => source.id,
          "target_integration_id" => target.id
        })

      {:ok, _view, html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      # "Google Calendar to Google Calendar" says nothing about which direction
      # was configured.
      assert html =~ "organiser@example.com"
      assert html =~ "second@example.com"
    end

    test "leaves a single calendar's label unqualified", %{conn: conn, user: user} do
      # The qualifier earns its place only where something collides. One Google
      # account with the email appended is noise, not information.
      insert(:calendar_integration,
        user: user,
        provider: "google",
        name: "Work Google",
        provider_account_email: nil,
        provider_account_id: nil,
        is_active: true
      )

      insert(:calendar_integration,
        user: user,
        provider: "nextcloud",
        name: "My Nextcloud",
        provider_account_email: nil,
        provider_account_id: nil,
        is_active: true
      )

      {:ok, _view, html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      assert "Work Google" in source_option_labels(html)
    end
  end
end
