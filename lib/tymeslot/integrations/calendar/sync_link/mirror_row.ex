defmodule Tymeslot.Integrations.Calendar.SyncLink.MirrorRow do
  @moduledoc """
  Moves the mapping row along after a provider write has already landed, under
  the one rule that makes it safe to do so: none of it may fail the write.

  Split out of `SyncLink.Engine` for the same reason `SyncLink.MirrorColour`
  was, and it is the mirror image of that split. The engine's entire return
  contract is that a failure propagates — `{:error, reason}` reaches the worker,
  Oban retries, the write is attempted again. Every function here breaks that
  contract deliberately, and the break is the point: by the time any of them
  runs, the placeholder on the organiser's calendar is *already correct*. The
  row is Tymeslot's private note about a write the provider has accepted, and
  turning a failed note into a failed write would re-send a placeholder that
  needs nothing, burning provider quota to fix a bookkeeping entry.

  Keeping these inline in the engine made that read as an oversight — a `case`
  that quietly drops its error looks like a missing branch until you know why
  it is missing. Gathered here, the rule is stated once and every function in
  the module is visibly an instance of it.

  ## What a stale row costs, and why that is the cheaper failure

  A row that falls behind is a state the system already handles.
  `SyncLinkReconcileWorker` sweeps the mapping rows and re-derives the write
  from them, so a row left saying `active` when it should say `failed`, or one
  still naming an id the provider has superseded, is corrected on the next
  pass. That is a bounded window measured in minutes.

  The alternative is unbounded. Propagating the error retries the whole mirror,
  and the retry re-runs the provider write — which succeeds again, because it
  succeeded the first time — and then attempts the same row update, which fails
  again for whatever reason it failed before (a constraint, a connection, a row
  deleted underneath). Five attempts later Oban gives up having written the
  placeholder five times. Every failure here is therefore logged and swallowed,
  which is what leaves the sweep as the single mechanism that reconciles rows.

  ## Why the deletes are the exception

  `drop/1` is the one function here that *does* surface its error, and the
  asymmetry is deliberate. Everything else adjusts a row that will keep
  describing a placeholder either way. Dropping the row is the last step of
  withdrawing one, and the row holds the `target_uid` — the only thing naming
  the placeholder on the provider. A drop that fails and reports success
  strands nothing, but it does end the operation claiming a withdrawal that the
  caller cannot verify. Teardown and the sync path both need to know, because
  both are destructive and both leave the row in `pending_delete` for the sweep
  when they cannot finish.

  ## The etag baseline

  `baseline_after_write/0` lives here rather than in `ConflictLog` because it
  decides the value of one column on one row write, which is this module's
  subject, not the classification of a divergence, which is that one's. It is
  `nil`, and the reasoning for that is long enough to be worth stating where
  the column is set — see the function.
  """

  require Logger

  alias Tymeslot.Integrations.Calendar.CalendarSyncMirrorQueries
  alias Tymeslot.Integrations.Calendar.CalendarSyncMirrorSchema

  @doc """
  Applies `attrs` to the mapping row, answering the row either way.

  The updated struct on success, the row *as it was* on failure — never an
  error tuple, so a caller can pipe this straight through without deciding what
  a bookkeeping failure means. It means nothing to the caller; see the
  moduledoc. Answering the unchanged row rather than `nil` keeps a caller that
  reads a field off the result working on the stale value instead of crashing,
  which matches what the row on disk now says.
  """
  @spec mark(CalendarSyncMirrorSchema.t(), map()) :: CalendarSyncMirrorSchema.t()
  def mark(%CalendarSyncMirrorSchema{} = mirror, attrs) do
    case CalendarSyncMirrorQueries.update(mirror, attrs) do
      {:ok, updated} ->
        updated

      {:error, changeset} ->
        Logger.warning("Failed to update mirror mapping state",
          sync_link_id: mirror.sync_link_id,
          source_uid: mirror.source_uid,
          reason: inspect(changeset.errors)
        )

        mirror
    end
  end

  @doc """
  Drops the mapping row once its placeholder is confirmed gone from the
  provider.

  Surfaces its error, unlike the rest of this module — see the moduledoc on why
  the withdrawal path is the exception.
  """
  @spec drop(CalendarSyncMirrorSchema.t()) :: :ok | {:error, term()}
  def drop(%CalendarSyncMirrorSchema{} = mirror) do
    case CalendarSyncMirrorQueries.delete(mirror) do
      {:ok, _deleted} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Parks the row in `pending_delete` and hands back the provider failure that
  put it there.

  The two halves are one step: the state is what the reconcile sweep looks for,
  and the error is what tells the caller the placeholder is still standing. A
  caller that got only the state would report a withdrawal that did not happen.
  """
  @spec mark_pending_delete(CalendarSyncMirrorSchema.t(), term()) :: {:error, term()}
  def mark_pending_delete(%CalendarSyncMirrorSchema{} = mirror, reason) do
    mark(mirror, %{state: "pending_delete"})
    {:error, reason}
  end

  @doc """
  The etag to stamp on a row for a placeholder just written.

  Cleared, not read back from the cache, and the difference is a bug's worth.

  The baseline exists to answer "has anybody touched the placeholder since we
  wrote it?", so it has to describe the placeholder *as written*. The only copy
  of the new etag lives on the provider: our cache still holds whatever the
  target's last inbound sync fetched, which is the state from *before* this
  write. Storing that reads the engine's own change back as a stranger's the
  moment the target syncs — the placeholder's `provider_updated_at` is when the
  provider applied our write, necessarily later than the baseline we stamped,
  so the `changed_after_write?` guard sees a later change and lets it through
  as a hand edit.

  `nil` says "no baseline" and `ConflictLog`'s `mirror_edited?/2` requires two
  etags to compare, so an edit is simply not reported until the next write
  establishes a real baseline from a re-synced cache. Under-reporting for one
  cycle is the right trade against a spurious row per write per series: a
  conflict log is read when someone is trying to find out why a calendar looks
  wrong, and it is worth nothing if most of what it holds is the engine
  reporting itself.

  Fetching the written etag from the provider would be exact and costs a
  request per mirror write; that is the trade to revisit if under-reporting
  turns out to matter.
  """
  @spec baseline_after_write() :: nil
  def baseline_after_write, do: nil
end
