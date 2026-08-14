defmodule TymeslotWeb.Components.Dashboard.Integrations.Calendar.SyncLinkMatrix do
  @moduledoc """
  The link grid: every ordered pair of the organiser's calendars as one table
  of checkboxes, saved in a single submit.

  Extracted from `SyncLinksSettingsComponent` rather than written inline
  because the grid is the largest single piece of markup that panel renders and
  keeping it there pushed the module past the line budget the analyser
  enforces. The split is along a real seam: this module knows how to *draw* a
  matrix and nothing about how one is saved — the form's `phx-submit` targets
  the parent, which owns the rate limit, the parse and the write.

  ## The two ways a cell can be unavailable

  They are deliberately drawn differently, because they mean different things.

  A cell on the **diagonal** carries no control at all. A calendar mirroring
  onto itself is refused by the `calendar_sync_links_no_self_link` check
  constraint, so it is not an option that happens to be switched off — it is
  not an option. A disabled checkbox there would imply something the organiser
  might unlock.

  A cell in a **read-only column** renders as a disabled checkbox with a title
  explaining why. An ICS subscription can be a source but never a target
  (`Capability.supports?/2`, feature `:mirror_target`), and that asymmetry is
  worth showing rather than hiding: the organiser can see the calendar is
  known, is in the grid, and simply cannot receive.

  ## Why each checkbox carries a hidden partner

  An unchecked checkbox submits nothing at all, which the handler cannot tell
  apart from a cell that was never rendered. Without the paired hidden
  `"false"`, clearing a cell would be inexpressible and the grid could only
  ever add links. The hidden input is omitted for blocked cells, which have no
  state to submit.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Integrations.Calendar.DisplayHelpers
  alias Tymeslot.Integrations.Calendar.SyncLink.Capability

  attr :integrations, :list, required: true
  attr :links, :list, required: true
  attr :error, :string, default: nil
  attr :target, :any, required: true

  @spec sync_link_matrix(map()) :: Phoenix.LiveView.Rendered.t()
  def sync_link_matrix(assigns) do
    assigns =
      assigns
      |> assign(:calendars, grid_calendars(assigns.integrations))
      |> assign(:linked_pairs, linked_pairs(assigns.links))

    ~H"""
    <%!-- Two calendars is the smallest grid with a single off-diagonal cell.
          Below that it would render one row, one column and nothing to tick,
          which reads as broken rather than as empty. --%>
    <section :if={length(@calendars) >= 2} class="space-y-4">
      <div>
        <h2 class="text-token-lg font-bold text-tymeslot-900">
          {dgettext("dashboard_integrations", "Link grid")}
        </h2>
        <p class="text-token-sm text-tymeslot-600">
          {dgettext(
            "dashboard_integrations",
            "Tick a cell to mirror events from the calendar in that row onto the calendar in that column."
          )}
        </p>
      </div>

      <p :if={@error} class="text-token-sm font-semibold text-red-700">
        {@error}
      </p>

      <.form
        for={%{}}
        id="sync-link-matrix-form"
        phx-submit="save_sync_link_matrix"
        phx-target={@target}
        class="space-y-4"
      >
        <div class="overflow-x-auto">
          <table class="w-full border-collapse text-token-sm">
            <thead>
              <tr>
                <th class="p-2 text-left font-semibold text-tymeslot-500">
                  <span class="sr-only">
                    {dgettext("dashboard_integrations", "Mirror from")}
                  </span>
                </th>
                <th
                  :for={target <- @calendars}
                  scope="col"
                  class="p-2 text-left align-bottom font-semibold text-tymeslot-700"
                >
                  <span class="block max-w-[10rem] truncate">
                    {DisplayHelpers.integration_label(target)}
                  </span>
                </th>
              </tr>
            </thead>
            <tbody>
              <tr :for={source <- @calendars} class="border-t border-tymeslot-100">
                <th scope="row" class="p-2 text-left font-semibold text-tymeslot-700">
                  <span class="block max-w-[10rem] truncate">
                    {DisplayHelpers.integration_label(source)}
                  </span>
                </th>
                <td :for={target <- @calendars} class="p-2 text-center">
                  <span :if={source.id == target.id} class="text-tymeslot-300" aria-hidden="true">
                    ·
                  </span>
                  <input
                    :if={source.id != target.id and not blocked?(target)}
                    type="hidden"
                    name={"matrix[#{cell_dom_id(source, target)}]"}
                    value="false"
                  />
                  <input
                    :if={source.id != target.id}
                    type="checkbox"
                    id={cell_dom_id(source, target)}
                    name={"matrix[#{cell_dom_id(source, target)}]"}
                    value="true"
                    checked={MapSet.member?(@linked_pairs, {source.id, target.id})}
                    disabled={blocked?(target)}
                    title={
                      blocked?(target) &&
                        dgettext(
                          "dashboard_integrations",
                          "This calendar is read-only and cannot receive mirrored events."
                        )
                    }
                    class="h-4 w-4 rounded-token-sm border-tymeslot-300 text-tymeslot-600 disabled:cursor-not-allowed disabled:opacity-40"
                  />
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <div class="flex items-center justify-between gap-3">
          <p class="text-token-xs text-tymeslot-500">
            {dgettext(
              "dashboard_integrations",
              "A greyed cell belongs to a read-only calendar, which can send but never receive."
            )}
          </p>
          <button
            type="submit"
            class="rounded-token-md bg-tymeslot-900 px-4 py-2 text-token-sm font-semibold text-white hover:bg-tymeslot-800"
          >
            {dgettext("dashboard_integrations", "Save grid")}
          </button>
        </div>
      </.form>
    </section>
    """
  end

  @doc """
  The DOM id and form key for one cell.
  """
  @spec cell_dom_id(map(), map()) :: String.t()
  def cell_dom_id(source, target), do: "sync-cell-#{source.id}-#{target.id}"

  @doc """
  Reads a submitted grid back into `{source_id, target_id}` pairs.

  Lives here rather than in the panel that handles the submit because it is the
  inverse of `cell_dom_id/2` above: the two encode and decode one format, and
  splitting them across modules is how they drift.

  Ticked cells are those whose value survived the browser overwriting the
  hidden partner. Only ids drawn from `calendars` are returned, so a cell
  naming a calendar the grid never offered is dropped here as well as being
  refused by the ownership check on the write path — the parser is a filter,
  not the authorisation.
  """
  @spec parse_submission(map(), [map()]) :: [{integer(), integer()}]
  def parse_submission(params, calendars) do
    offered = MapSet.new(calendars, & &1.id)

    params
    |> Enum.filter(fn {_cell_id, value} -> value in ["true", true, "on"] end)
    |> Enum.flat_map(fn {cell_id, _value} -> parse_cell_id(cell_id) end)
    |> Enum.filter(fn {source_id, target_id} ->
      source_id != target_id and MapSet.member?(offered, source_id) and
        MapSet.member?(offered, target_id)
    end)
  end

  defp parse_cell_id("sync-cell-" <> rest) do
    case String.split(rest, "-") do
      [source, target] ->
        with {source_id, ""} <- Integer.parse(source),
             {target_id, ""} <- Integer.parse(target) do
          [{source_id, target_id}]
        else
          _unparseable -> []
        end

      _malformed ->
        []
    end
  end

  defp parse_cell_id(_other), do: []

  # Every active calendar is a row. Sources are unrestricted — reading a feed
  # is the one thing every provider can do — so the rows need no filtering and
  # the asymmetry lives entirely in the columns. Sorted by the label the grid
  # actually prints, so the headers read in the order the eye scans them.
  defp grid_calendars(integrations) do
    integrations
    |> Enum.filter(& &1.is_active)
    |> Enum.sort_by(&{String.downcase(DisplayHelpers.integration_label(&1)), &1.id})
  end

  # Keyed by the ordered pair so a cell is a set membership test rather than a
  # scan of every link per cell — a 5×5 grid asks this twenty times.
  defp linked_pairs(links) do
    MapSet.new(links, &{&1.source_integration_id, &1.target_integration_id})
  end

  defp blocked?(target), do: not Capability.supports?(target.provider, :mirror_target)
end
