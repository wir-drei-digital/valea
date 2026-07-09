defmodule Valea.Cockpit do
  @moduledoc """
  Phase-1 seeded narrative for the Valea Cockpit dashboard.

  Returns the hardcoded today narrative with workspace overview, schedule,
  prepared items, open loops, and activities while away.

  This module provides the seeded data shape that will be replaced by
  live data from the database and external integrations in later phases.
  Task 11 exposes this over RPC, Task 17 renders it in the UI.
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
       ]
     }}
  end
end
