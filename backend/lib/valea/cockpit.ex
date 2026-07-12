defmodule Valea.Cockpit do
  @moduledoc """
  Phase-1 seeded narrative for the Valea Cockpit dashboard.

  Returns the hardcoded today narrative with workspace overview, schedule,
  prepared items, open loops, and activities while away.

  This module provides the seeded data shape that will be replaced by
  live data from the database and external integrations in later phases.
  Task 11 exposes this over RPC, Task 17 renders it in the UI.

  Task 18 adds one LIVE field to the otherwise-still-seeded payload:
  `"mail"` (`%{"review_count", "inbox_count", "configured"}`), read from
  `Valea.Mail.Store`/`Valea.Mail.Engine` — the two live pieces the Today
  page needs to generalize its inquiry card beyond the hardcoded seed
  message and phrase "N to review · M in inbox" in the summary line. Mail
  is workspace-scoped and only comes alive once `Valea.Workspace.Runtime`
  has started `Valea.Mail.Engine` (which may never happen — no workspace
  open, or a workspace mid-switch) — `Process.whereis(Valea.Mail.Engine)`
  guards this exactly the way `Valea.Audit.entries/1` guards its own
  GenServer call, so a dead/absent Engine degrades to the zero/unconfigured
  default instead of crashing this call with `:noproc`.

  Task A-T13 adds a second live field, `"triage_workflow_path"`: the
  workspace-relative path of the seeded New Inquiry Triage workflow
  (`Valea.Workflows.triage_path/0` — the first enabled mount, by the
  registry's own sort order, that has a `Workflows/New Inquiry Triage.md`),
  or `nil` when none exists. This replaces the frontend's own hardcoded
  `icm/Workflows/New Inquiry Triage.md` constant (that swap is a later
  task); unlike `mail`, this needs no GenServer/whereis guard — `Workflows`
  reads the filesystem directly and already degrades to `{:ok, []}` when no
  workspace is open.
  """

  @doc """
  Returns the seeded today narrative as a map with string keys, ready for JSON.

  Returns `{:ok, map}` with keys:
    - "workspace": workspace name
    - "date_label": formatted date and time
    - "greeting": personalized greeting
    - "summary": high-level overview of today
    - "schedule": list of scheduled items
    - "prepared_items": items prepared overnight (draft reviews, session briefs, etc.)
    - "open_loops": unresolved items
    - "while_you_were_away": background activity notifications
    - "mail": `%{"review_count", "inbox_count", "configured"}` — live, see moduledoc
    - "triage_workflow_path": seeded triage workflow's path, or nil — live, see moduledoc
  """
  def today do
    {:ok,
     %{
       "workspace" => "Mara Lindt Coaching",
       "date_label" => "Wednesday, 9 July · 8:31",
       "greeting" => "Good morning, Mara.",
       "summary" =>
         "Two sessions today, one new inquiry, one overdue invoice. I prepared three things overnight — nothing has been sent or changed without your approval.",
       "schedule" => [
         %{
           "time" => "09:30",
           "title" => "Admin hour",
           "subtitle" => "you're in it now",
           "status" => "current"
         },
         %{
           "time" => "11:00",
           "title" => "Session · Lea Brunner",
           "subtitle" => "Zoom · 75 min",
           "status" => "prep_ready"
         },
         %{
           "time" => "15:00",
           "title" => "Deep work",
           "subtitle" => "no meetings — protected",
           "status" => nil
         },
         %{
           "time" => "16:30",
           "title" => "Session · Markus Weber",
           "subtitle" => "in person · Zürich",
           "status" => "prep_at_14"
         }
       ],
       "prepared_items" => [
         %{
           "type" => "reply_drafted",
           "title" => "Priya Nair · new inquiry",
           "summary" =>
             "Good-fit inquiry — she asked about leadership coaching, which matches your core offer. Draft leads with the discovery call, not the price.",
           "used_sources" => [
             "her email",
             "Offers › Founder Coaching",
             "Tone guide",
             "Policies › No medical advice"
           ],
           "primary_action" => "Review draft",
           "secondary_action" => "Snooze"
         },
         %{
           "type" => "prep_brief",
           "title" => "Lea Brunner · 11:00 session",
           "summary" =>
             "One page from your approved notes: her homework was the pricing conversation with her first client; two open commitments from session 2.",
           "used_sources" => ["Clients › Lea", "session notes", "open commitments"],
           "primary_action" => "Open brief",
           "secondary_action" => "Snooze to 10:45"
         },
         %{
           "type" => "follow_up_drafted",
           "title" => "Julia Steiner · after Monday's session",
           "summary" =>
             "Monday's session still has no follow-up. Drafted from your session notes: the two agreed next steps and the article you promised her.",
           "used_sources" => ["Clients › Julia", "session notes", "Tone guide"],
           "primary_action" => "Review draft",
           "secondary_action" => "Skip this one"
         }
       ],
       "open_loops" => [
         %{
           "title" => "Send proposal to Priya after the discovery call",
           "source" => "from her email · yesterday"
         },
         %{
           "title" => "Give Feldmann a September workshop date",
           "source" => "from Clients › Feldmann · open 3 weeks"
         },
         %{
           "title" => "Update the workshop page with the 2027 price",
           "source" => "from Chat · yesterday"
         },
         %{
           "title" => "Reactivate 2 cold leads from May",
           "source" => "from Weekly admin review workflow"
         }
       ],
       "while_you_were_away" => [
         "Synced 9 emails from AI / Review · 7:00",
         "3 workflows ran: inquiry triage, session prep, receipt capture",
         "Moved 4 newsletters to Reading · Undo"
       ],
       "mail" => mail_summary(),
       "triage_workflow_path" => Valea.Workflows.triage_path()
     }}
  end

  # See the moduledoc: `Process.whereis/1` is the SAME guard
  # `Valea.Audit.entries/1` uses, for the same reason — no workspace open (or
  # one mid-switch) means `Valea.Mail.Engine` isn't registered, and calling
  # its `GenServer.call/2` anyway would exit `:noproc` and take this whole
  # RPC/channel call down instead of degrading gracefully.
  #
  # The whereis check does NOT cover `Valea.Mail.Store` (i.e. `Valea.Repo`),
  # though: the Repo is NOT a `Valea.Workspace.Runtime` child — the Manager
  # starts it directly under `Valea.Workspace.DynamicSupervisor` BEFORE the
  # Runtime (`manager.ex`: `start_repo` → `migrate` → `start_runtime`), and
  # `do_close/1` terminates `state.children` in that same list order, so on
  # every close/switch the Repo goes down FIRST while the Engine's name is
  # still registered. A `today/0` call landing in that window (or racing an
  # Engine crash) passes the whereis guard and then hits a dead Repo — which
  # is what `live_mail_summary/0`'s rescue/catch is for.
  defp mail_summary do
    if Process.whereis(Valea.Mail.Engine) do
      live_mail_summary()
    else
      zero_mail_summary()
    end
  end

  # `state: "inactive"` — the Engine is registered but hasn't processed its
  # `:workspace_opened` activation yet (activation is async in the Engine's
  # own mailbox; `Index.rebuild/1` only runs there). Counts read this early
  # would be whatever the previous session left in the cache, so report the
  # deterministic zero/unconfigured shape instead; activation ends with a
  # `mail_status` broadcast, and the Today page refetches this payload on
  # that push (see `+page.svelte`), so the real counts follow immediately.
  #
  # rescue/catch: degrade to the zero summary the whereis guard already
  # promises — deliberately broad, because the failure modes here are "some
  # dependency of the read is down", not a specific exception type:
  # `Store.*` raises assorted DB errors (`DBConnection.ConnectionError`,
  # `Exqlite.Error`, Ash wrappers) when the Repo is down (see the close
  # ordering note above), and `Engine.status/0` exits `:noproc` if the
  # Engine dies between the whereis check and the call.
  defp live_mail_summary do
    case Valea.Mail.Engine.status() do
      %{state: "inactive"} ->
        zero_mail_summary()

      status ->
        review_count =
          Valea.Mail.Store.list_messages() |> Enum.count(&(&1.status == "review"))

        %{
          "review_count" => review_count,
          "inbox_count" => length(Valea.Mail.Store.inbox_headers()),
          "configured" => status.configured
        }
    end
  rescue
    _ -> zero_mail_summary()
  catch
    :exit, _ -> zero_mail_summary()
  end

  defp zero_mail_summary do
    %{"review_count" => 0, "inbox_count" => 0, "configured" => false}
  end
end
