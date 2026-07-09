defmodule Valea.CockpitTest do
  use ExUnit.Case, async: true

  test "today returns the seeded narrative" do
    {:ok, today} = Valea.Cockpit.today()

    # Basic structure
    assert today["greeting"] == "Good morning, Mara."
    assert today["workspace"] == "Mara Lindt Coaching"
    assert String.starts_with?(today["date_label"], "Wednesday, 9 July")
    assert String.contains?(today["summary"], "Two sessions today")

    # Schedule
    assert length(today["schedule"]) == 4
    schedule = today["schedule"]
    assert Enum.at(schedule, 0)["time"] == "09:30"
    assert Enum.at(schedule, 0)["status"] == "current"
    assert Enum.at(schedule, 1)["time"] == "11:00"
    assert Enum.at(schedule, 1)["status"] == "prep_ready"
    assert Enum.at(schedule, 2)["time"] == "15:00"
    assert Enum.at(schedule, 2)["status"] == nil
    assert Enum.at(schedule, 3)["time"] == "16:30"
    assert Enum.at(schedule, 3)["status"] == "prep_at_14"

    # Prepared items
    assert length(today["prepared_items"]) == 3
    [priya, lea, julia] = today["prepared_items"]

    # Priya Nair - reply_drafted
    assert priya["type"] == "reply_drafted"
    assert priya["title"] == "Priya Nair · new inquiry"

    assert priya["summary"] ==
             "Good-fit inquiry — she asked about leadership coaching, which matches your core offer. Draft leads with the discovery call, not the price."

    assert priya["used_sources"] == [
             "her email",
             "Offers › Founder Coaching",
             "Tone guide",
             "Policies › No medical advice"
           ]

    assert priya["primary_action"] == "Review draft"
    assert priya["secondary_action"] == "Snooze"

    # Lea Brunner - prep_brief
    assert lea["type"] == "prep_brief"
    assert lea["title"] == "Lea Brunner · 11:00 session"

    assert lea["summary"] ==
             "One page from your approved notes: her homework was the pricing conversation with her first client; two open commitments from session 2."

    assert lea["used_sources"] == ["Clients › Lea", "session notes", "open commitments"]
    assert lea["primary_action"] == "Open brief"
    assert lea["secondary_action"] == "Snooze to 10:45"

    # Julia Steiner - follow_up_drafted
    assert julia["type"] == "follow_up_drafted"
    assert julia["title"] == "Julia Steiner · after Monday's session"

    assert julia["summary"] ==
             "Monday's session still has no follow-up. Drafted from your session notes: the two agreed next steps and the article you promised her."

    assert julia["used_sources"] == ["Clients › Julia", "session notes", "Tone guide"]
    assert julia["primary_action"] == "Review draft"
    assert julia["secondary_action"] == "Skip this one"

    # Open loops
    assert length(today["open_loops"]) == 4
    open_loops = today["open_loops"]

    assert Enum.at(open_loops, 0)["title"] == "Send proposal to Priya after the discovery call"
    assert Enum.at(open_loops, 0)["source"] == "from her email · yesterday"

    assert Enum.at(open_loops, 1)["title"] == "Give Feldmann a September workshop date"
    assert Enum.at(open_loops, 1)["source"] == "from Clients › Feldmann · open 3 weeks"

    assert Enum.at(open_loops, 2)["title"] == "Update the workshop page with the 2027 price"
    assert Enum.at(open_loops, 2)["source"] == "from Chat · yesterday"

    assert Enum.at(open_loops, 3)["title"] == "Reactivate 2 cold leads from May"
    assert Enum.at(open_loops, 3)["source"] == "from Weekly admin review workflow"

    # While you were away
    assert length(today["while_you_were_away"]) == 3
    away = today["while_you_were_away"]
    assert Enum.at(away, 0) == "Synced 9 emails from AI / Review · 7:00"
    assert Enum.at(away, 1) == "3 workflows ran: inquiry triage, session prep, receipt capture"
    assert Enum.at(away, 2) == "Moved 4 newsletters to Reading · Undo"
  end
end
