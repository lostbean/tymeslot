defmodule Tymeslot.Workers.SyncLinkReconcileSweepWorkerTest do
  @moduledoc """
  The cron fan-out: which links are due, and nothing else.

  Its whole contract is that it touches no provider and reads no calendar. It
  selects rows and inserts jobs, so a target that is down cannot slow it and a
  thousand links cannot make it a long-running job. No test here sets a Mox
  expectation, which makes `verify_on_exit!` the assertion that it stayed inside
  the database.
  """
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :workers
  @moduletag :sync_links

  import Mox
  import Tymeslot.Factory
  import Tymeslot.SyncLinkTestHelpers

  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkQueries
  alias Tymeslot.Workers.SyncLinkReconcileSweepWorker
  alias Tymeslot.Workers.SyncLinkReconcileWorker

  setup :verify_on_exit!

  defp swept_link_ids do
    [worker: SyncLinkReconcileWorker]
    |> all_enqueued()
    |> MapSet.new(& &1.args["sync_link_id"])
  end

  describe "perform/1" do
    test "enqueues one job per never-reconciled link" do
      %{link: link} = linked_pair()

      assert :ok = perform_job(SyncLinkReconcileSweepWorker, %{})

      assert swept_link_ids() == MapSet.new([link.id])
    end

    test "skips a disabled link" do
      %{link: link} = linked_pair()
      {:ok, _paused} = CalendarSyncLinkQueries.update(link, %{enabled: false})

      assert :ok = perform_job(SyncLinkReconcileSweepWorker, %{})

      refute_enqueued(worker: SyncLinkReconcileWorker)
    end

    test "skips a link reconciled inside the interval" do
      %{link: link} = linked_pair()

      {:ok, _fresh} =
        CalendarSyncLinkQueries.update(link, %{last_reconciled_at: DateTime.utc_now(:microsecond)})

      assert :ok = perform_job(SyncLinkReconcileSweepWorker, %{})

      refute_enqueued(worker: SyncLinkReconcileWorker)
    end

    test "enqueues a link whose last reconcile has aged out" do
      %{link: link} = linked_pair()

      stale = DateTime.add(DateTime.utc_now(:microsecond), -2, :hour)
      {:ok, _stale} = CalendarSyncLinkQueries.update(link, %{last_reconciled_at: stale})

      assert :ok = perform_job(SyncLinkReconcileSweepWorker, %{})

      assert swept_link_ids() == MapSet.new([link.id])
    end

    test "fans out across many links, staggering batches rather than sleeping" do
      # Two batches' worth plus one, so the stagger is observable: the first 50
      # go out immediately and the rest are scheduled a second later. Sleeping
      # between batches would hold the sweep's queue slot for the duration.
      user = insert(:user)
      source = insert(:calendar_integration, user: user, provider: "google")

      links =
        for _index <- 1..51 do
          target = insert(:calendar_integration, user: user, provider: "google")

          insert(:calendar_sync_link,
            user_id: user.id,
            source_integration_id: source.id,
            target_integration_id: target.id
          )
        end

      assert :ok = perform_job(SyncLinkReconcileSweepWorker, %{})

      jobs = all_enqueued(worker: SyncLinkReconcileWorker)
      assert length(jobs) == 51
      assert swept_link_ids() == MapSet.new(links, & &1.id)

      assert Enum.any?(jobs, &(DateTime.compare(&1.scheduled_at, DateTime.utc_now()) == :gt))
    end

    test "reaches no provider" do
      # No Mox expectation is set: verify_on_exit! turns any provider call into
      # a failure. The sweep must decide what is due from rows alone.
      %{link: link} = linked_pair()

      assert :ok = perform_job(SyncLinkReconcileSweepWorker, %{})

      assert swept_link_ids() == MapSet.new([link.id])
    end

    test "returns :ok when no link is configured" do
      assert :ok = perform_job(SyncLinkReconcileSweepWorker, %{})

      refute_enqueued(worker: SyncLinkReconcileWorker)
    end
  end
end
