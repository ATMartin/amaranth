# Grading sheet — dev

Rubric: docs/qualification/milestone-v/t109-semantics.md §3. Grade each: correct / partial / wrong; claims supported: yes / no.

## dev01 [answer] staffing, person_date, cross_meeting, multipart, speaker_vs_mentioned

**Q:** Over the past seven days, what came up about who might be able to work on the Kestrel migration?

**Expected:** Across the rolling window: Wen Li cannot (on leave until January); Rosa could take the data copy from the 12th, first tentative then confirmed after her manager signed off; Tomas is booked on the billing audit through December; Omar will own the cutover runbook at no more than two days a week.

**Required points:** • Wen Li is unavailable: on leave until January (Oct 30 sync) • Rosa was suggested for the data copy work starting the 12th, pending her manager (Nov 2) • Rosa was later confirmed after her manager signed off (Nov 4) • Tomas is not available; booked on the billing audit through December (Nov 2) • Omar agreed to own the cutover runbook but only about two days a week (Nov 4)

**Forbidden:** • Tomas has room / is available for Kestrel • Wen Li is available or confirmed • Omar is full time on Kestrel

**App (partial, 4.6 s):** Rosa was identified as someone who could pick up the data copy piece of the Kestrel migration, starting the twelfth, but she still needs her manager to okay it. Tomas was noted as being unavailable due to a booking on the billing audit through December, which was pulled forward. No other individuals were mentioned as potentially able to work on the Kestrel migration.

**Notes shown:** Searched meetings from Fri, Oct 30 to Fri, Nov 6 (“past seven days”). Contextual search covers 20 of 21 meetings so far; the rest were searched by keywords.

**Cited:**
- Capacity check-in (Nov 2, 2026): Speaker 1: Morning. Let's go through the open asks, Kestrel first. | Speaker 1: Kestrel is basically moving the customer ledger off the old Oracle box.

## dev02 [answer] followup, staffing, decision_status

**Q:** Which of those are actually locked in?

**Expected:** Confirmed: Rosa (manager signed off, starting the 12th) and Omar owning the cutover runbook at up to two days a week. Wen Li and Tomas are not available; nothing else is confirmed.

**Required points:** • Rosa is confirmed after her manager signed off • Omar committed to own the cutover runbook, capped at two days a week • Wen Li and Tomas are not options

**Forbidden:** • Wen Li is confirmed • Tomas is confirmed

**App (partial, 5.8 s):** Rosa's data copy task is locked in, as her manager has signed off, allowing her to start on the twelfth. Omar is committed to owning the cutover runbook, though he can only dedicate two days a week. A dry run for the cutover is scheduled for the first week of December. The go-live date is not yet set. Access to the old schemas is to be requested by Omar, and monitoring for the new ledger can reuse existing alerts. No final decision was made on the target go-live date.

**Notes shown:** Searched meetings from Fri, Oct 30 to Fri, Nov 6 (“past seven days”). Contextual search covers 20 of 21 meetings so far; the rest were searched by keywords. Rosa isn't a named speaker here, so this covers what others said about Rosa.

**Cited:**
- Capacity check-in (Nov 2, 2026): Speaker 1: Morning. Let's go through the open asks, Kestrel first. | Speaker 1: Kestrel is basically moving the customer ledger off the old Oracle box. | Speaker 3: So on people, Rosa could pick up the data copy piece, starting the twelfth. | Speaker 2: And Tomas is out, he's booked on the billing audit through December.
- Kestrel cutover prep (Nov 4, 2026): Speaker 1: Okay, this is the first real Kestrel prep, thanks for joining. | Speaker 1: Great. So, news first. Rosa's manager signed off, so she's on it from the twelfth. | Speaker 3: Nice, that's the data copy covered. | Omar: But realistically I can do two days a week on this, not more.
- Kestrel cutover prep (Nov 4, 2026): Speaker 3: Okay, first week of December for the dry run.

## dev03 [answer] paraphrase, staffing

**Q:** Who got the go-ahead to help shift our customer accounts off the legacy database?

**Expected:** Rosa: her manager signed off and she starts on the data copy from the 12th (Kestrel is the customer-ledger move off the old Oracle box).

**Required points:** • Rosa got approval (manager signed off) • She starts on the 12th

**Forbidden:** • Tomas • Wen Li

**App (partial, 4.2 s):** Rosa got the go-ahead to help shift the customer accounts off the legacy database, as Speaker 3 stated she could pick up the data copy piece starting the twelfth, though she still needs her manager to okay it.

**Notes shown:** Contextual search covers 64 of 65 meetings so far; the rest were searched by keywords.

**Cited:**
- Capacity check-in (Nov 2, 2026): Speaker 1: Kestrel is basically moving the customer ledger off the old Oracle box. | Speaker 1: Plus the reconciliation reports that hang off it.

## dev04 [answer] changed_plan, cross_meeting, staffing, speaker_vs_mentioned

**Q:** Is Tomas still free to help on Kestrel?

**Expected:** No. On Oct 29 someone said he had plenty of room, but on Nov 2 it was reported that he is booked on the billing audit through December because the audit was pulled forward.

**Required points:** • Earlier (Oct 29) he was described as having room • As of Nov 2 he is booked on the billing audit through December • Reason: the audit got pulled forward

**Forbidden:** • Tomas is available for Kestrel now

**App (partial, 4.1 s):** No, Tomas is not free to help on Kestrel. Speaker 2 states that Tomas is booked on the billing audit through December, and that the audit was pulled forward last week, which means he is unavailable for Kestrel work.

**Notes shown:** Contextual search covers 64 of 65 meetings so far; the rest were searched by keywords. Tomas isn't a named speaker here, so this covers what others said about Tomas.

**Cited:**
- Platform weekly (Oct 29, 2026): Speaker 1: Okay, let's get going, we've got a lot today. | Speaker 2: Yeah, can we start with the incident from Tuesday? | Speaker 1: Sure. Quick version is the cache cluster filled up and evictions spiked. | Speaker 3: We bumped the memory limit and it's been stable since.
- Capacity check-in (Nov 2, 2026): Speaker 1: Morning. Let's go through the open asks, Kestrel first. | Speaker 1: Kestrel is basically moving the customer ledger off the old Oracle box. | Speaker 3: She still needs her manager to okay it though. | Speaker 3: Maybe Wen Li could help? I haven't asked her.

## dev05 [answer] negation, staffing, cross_meeting

**Q:** Who has been ruled out for Kestrel, and why?

**Expected:** Tomas (booked on the billing audit through December) and Wen Li (on leave until January). Rosa and Omar are not ruled out.

**Required points:** • Tomas: billing audit through December • Wen Li: on leave until January

**Forbidden:** • Rosa was ruled out • Omar was ruled out

**App (partial, 4.7 s):** Tomas has been ruled out for Kestrel because he is booked on the billing audit through December, which was pulled forward last week. Rosa is confirmed to take on the data copy piece starting the twelfth, but she still needs her manager's approval, which was granted. Omar is assigned to the cutover runbook and is available, though only two days a week.

**Notes shown:** Contextual search covers 64 of 65 meetings so far; the rest were searched by keywords.

**Cited:**
- Platform weekly (Oct 29, 2026): Speaker 1: Good. Next, Kestrel planning. Um, we need names before the kickoff. | Speaker 2: From what I've heard Tomas has plenty of room right now, he could take Kestrel. | Speaker 1: Rough guess is six to eight weeks for two people. | Speaker 2: That feels light if we're doing the reconciliation reports too.
- Capacity check-in (Nov 2, 2026): Speaker 1: Morning. Let's go through the open asks, Kestrel first. | Speaker 1: Kestrel is basically moving the customer ledger off the old Oracle box. | Speaker 3: Maybe Wen Li could help? I haven't asked her. | Speaker 2: I think someone said she's away, but I'm not sure.

## dev06 [abstain] unanswerable

**Q:** What budget was approved for the Kestrel migration?

**Expected:** No Kestrel budget was discussed in the searched meetings; say none was found.

**Required points:** • No approved Kestrel budget found in searched meetings

**Forbidden:** • any dollar amount for Kestrel • six to eight weeks is a budget

**App (insufficient_evidence, 3.6 s):** I couldn't find that in these meetings.

**Notes shown:** Contextual search covers 64 of 65 meetings so far; the rest were searched by keywords.

## dev07 [qualify] ambiguous, speaker_vs_mentioned, adversarial

**Q:** What did Rosa say in the capacity check-in?

**Expected:** Rosa is an attendee and was discussed, but speakers are anonymous and nothing is attributed to her; others said she could pick up the data copy from the 12th pending her manager's approval.

**Required points:** • No line is attributed to Rosa as speaker • Others said she could take the data copy from the 12th, pending her manager

**Forbidden:** • Rosa said she could pick up the data copy • Rosa said anything (as speaker)

**App (answered, 3.4 s):** Rosa was mentioned by Speaker 3 as someone who could pick up the data copy piece, starting the twelfth. Speaker 3 noted that Rosa still needs her manager to okay it.

**Notes shown:** Rosa isn't a named speaker here, so this covers what others said about Rosa.

**Cited:**
- Capacity check-in (Nov 2, 2026): Speaker 3: So on people, Rosa could pick up the data copy piece, starting the twelfth. | Speaker 3: Maybe Wen Li could help? I haven't asked her. | Speaker 2: I think someone said she's away, but I'm not sure. | Speaker 1: Let's check before we count on it.

## dev08 [clarify] ambiguous

**Q:** What is Sam supposed to be doing?

**Expected:** Two different Sams appear: Sam Patel offered to do the UI review for the cutover screens (Kestrel), and finance's Sam (Ruiz) will pull Halyard references and chase the price. Ask which Sam, or present both clearly separated.

**Required points:** • Kestrel prep: Sam to do the UI review for cutover screens • Finance sync: Sam to pull Halyard references and chase the revised price • These may be different people

**Forbidden:** • treating both as the same Sam without qualification

**App (partial, 3.6 s):** Sam is supposed to do the UI review for the cutover status page.

**Notes shown:** Contextual search covers 64 of 65 meetings so far; the rest were searched by keywords. Sam isn't a named speaker here, so this covers what others said about Sam.

**Cited:**
- Kestrel cutover prep (Nov 4, 2026): Speaker 1: Sam can do the UI review for those, he offered on Monday.

## dev09 [answer] lexical

**Q:** Who owns the cutover runbook?

**Expected:** Omar said he'll own the cutover runbook (about two days a week) and will add the dry run steps to it.

**Required points:** • Omar owns the cutover runbook • He'll add the dry run steps

**Forbidden:** • Rosa owns the runbook

**App (partial, 3.4 s):** Omar owns the cutover runbook.

**Notes shown:** Contextual search covers 64 of 65 meetings so far; the rest were searched by keywords.

**Cited:**
- Kestrel cutover prep (Nov 4, 2026): Speaker 1: Omar, can you own the cutover runbook? | Omar: Yes, I'll own the cutover runbook. | Speaker 3: Who's doing the screens for the cutover status page? | Omar: What's the rollback story?

## dev10 [abstain] unanswerable, speaker_vs_mentioned

**Q:** What did Omar say about the Pipewell contract?

**Expected:** Omar only speaks in the Kestrel prep and never mentions Pipewell; nothing found.

**Required points:** • No Omar statement about Pipewell found

**Forbidden:** • Omar supported or opposed Pipewell

**App (insufficient_evidence, 3.9 s):** I couldn't find that in these meetings.

**Notes shown:** Contextual search covers 64 of 65 meetings so far; the rest were searched by keywords.

## dev11 [abstain] unanswerable, adversarial

**Q:** Did Omar agree to cover on-call over Thanksgiving?

**Expected:** No. Omar only noted that the week of the 23rd is Thanksgiving week when scheduling the dry run; no on-call agreement exists.

**Required points:** • No Thanksgiving on-call agreement by Omar found

**Forbidden:** • Omar agreed to Thanksgiving on-call

**App (insufficient_evidence, 3.5 s):** I couldn't find that in these meetings.

**Notes shown:** Contextual search covers 64 of 65 meetings so far; the rest were searched by keywords.

## dev12 [answer] paraphrase, decision_status, changed_plan, cross_meeting

**Q:** Did we ever settle on which platform will hold our sales contacts?

**Expected:** A final choice of Pipewell was announced on Oct 27, but on Nov 3 it was put on hold: the Pipewell quote came in 40% over budget and legal reopened the choice; nothing will be signed until Halyard's revised price is compared. No new final decision yet.

**Required points:** • Oct 20: leaning Pipewell, no decision • Oct 27: Pipewell declared final • Nov 3: reopened because the quote was 40% over budget • Currently on hold; no signed decision

**Forbidden:** • Pipewell is the final, settled choice • Halyard was chosen

**App (partial, 4.1 s):** No, the decision on which platform will hold our sales contacts was not finalized. The initial selection of Pipewell was reversed due to a quote that was forty percent over budget, and the CRM choice was put on hold until further review. No final decision was made on the platform for sales contacts.

**Notes shown:** Contextual search covers 64 of 65 meetings so far; the rest were searched by keywords.

**Cited:**
- CRM selection (Oct 27, 2026): Speaker 1: Hold off on that until the contract's signed. | Speaker 2: Pipewell includes onboarding, so their team. | Speaker 1: Nice. And the admin role on our side? | Speaker 2: Probably someone from sales ops, we'll figure it out.
- Finance sync (Nov 3, 2026): Speaker 1: So the Pipewell pick is on hold, basically. | Speaker 2: Yes, on hold. Nothing gets signed until we've compared both. | Speaker 1: Okay. Reseller discounts next. | Speaker 3: Right now resellers get twelve percent standard.

## dev13 [answer] followup, decision_status

**Q:** When is that supposed to be looked at again?

**Expected:** It goes on the finance agenda for the 13th (November), after comparing Halyard's revised price.

**Required points:** • On the agenda for November 13

**Forbidden:** • October 27

**App (partial, 4.2 s):** It is supposed to be looked at again on the thirteenth.

**Notes shown:** Contextual search covers 64 of 65 meetings so far; the rest were searched by keywords.

**Cited:**
- Finance sync (Nov 3, 2026): Speaker 1: Okay, three things today. Reseller discounts, the CRM contract, and travel. | Speaker 2: Let's do the CRM first, that's the urgent one. | Speaker 2: The Pipewell quote came back forty percent over what we budgeted. | Speaker 2: So legal wants to reopen the CRM choice before anything gets signed.

## dev14 [answer] lexical

**Q:** What did the Pipewell quote come back at?

**Expected:** Forty percent over what was budgeted.

**Required points:** • 40% over budget

**Forbidden:** • under budget

**App (partial, 3.9 s):** The Pipewell quote came back forty percent over what we budgeted.

**Notes shown:** Contextual search covers 64 of 65 meetings so far; the rest were searched by keywords.

**Cited:**
- Finance sync (Nov 3, 2026): Speaker 2: The Pipewell quote came back forty percent over what we budgeted. | Speaker 1: So the Pipewell pick is on hold, basically. | Speaker 3: When do we come back to it? | Speaker 1: Okay. Reseller discounts next.

## dev15 [qualify] adversarial, decision_status

**Q:** Everyone signed off on Pipewell, so that's done, right?

**Expected:** Not quite: Pipewell was declared final on Oct 27, but on Nov 3 legal reopened it after the 40% over-budget quote and it is on hold.

**Required points:** • Correct the premise: decided Oct 27 but reopened Nov 3 • On hold pending comparison

**Forbidden:** • Yes, it's done • contract is signed

**App (partial, 4.4 s):** No, Pipewell's selection was not finalized, as the contract price was found to be forty percent over budget, leading legal to request reopening the CRM choice before any signing. The decision to go with Pipewell is on hold.

**Notes shown:** Contextual search covers 64 of 65 meetings so far; the rest were searched by keywords.

**Cited:**
- CRM selection (Oct 27, 2026): Speaker 2: Yeah, Pipewell's references were really positive. | Speaker 1: So we're going with Pipewell. That's final, I'll tell procurement today. | Speaker 1: Hold off on that until the contract's signed. | Speaker 2: I'll ask Pipewell for a formal quote.
- Finance sync (Nov 3, 2026): Speaker 2: The Pipewell quote came back forty percent over what we budgeted. | Speaker 2: So legal wants to reopen the CRM choice before anything gets signed. | Speaker 1: So the Pipewell pick is on hold, basically. | Speaker 2: Yes, on hold. Nothing gets signed until we've compared both.

## dev16 [clarify] self, ambiguous

**Q:** What did I say about the CRM vendors?

**Expected:** None of the CRM meetings has a speaker shown as Me, so 'I' cannot be resolved; ask which speaker is the user (or offer per-speaker summaries).

**Required points:** • Cannot tell which speaker is the user

**Forbidden:** • attributing any speaker's CRM statements to the user

**App (partial, 4.2 s):** Me said I'd lean toward Pipewell but didn't want to decide today. Later, Me stated that the Pipewell pick is on hold and that nothing gets signed until both vendors are compared.

**Notes shown:** Contextual search covers 64 of 65 meetings so far; the rest were searched by keywords.

**Cited:**
- Sales ops review (Oct 20, 2026): Speaker 1: Okay, main item is the CRM replacement. | Speaker 2: I'll ask both vendors for two customer references.
- Finance sync (Nov 3, 2026): Speaker 1: Okay, three things today. Reseller discounts, the CRM contract, and travel. | Speaker 2: Let's do the CRM first, that's the urgent one. | Speaker 2: So legal wants to reopen the CRM choice before anything gets signed.

## dev17 [abstain] unanswerable

**Q:** What did the Halyard sales rep promise us on their call?

**Expected:** No call with a Halyard rep is in the history; Halyard's revised price was still awaited.

**Required points:** • No Halyard rep call found

**Forbidden:** • Halyard promised a discount

**App (insufficient_evidence, 4.1 s):** I couldn't find that in these meetings.

**Notes shown:** Contextual search covers 64 of 65 meetings so far; the rest were searched by keywords.

## dev18 [clarify] ambiguous

**Q:** What did we decide about the vendor?

**Expected:** Several vendors appear (CRM vendors Pipewell/Halyard, the security testing vendor, Lumen Freight, the booking-system vendor); ask which one.

**Required points:** • Ask which vendor

**Forbidden:** • picking one vendor's decision without saying it is a guess

**App (partial, 3.9 s):** The vendor audit wrapped up, and one vendor was late with documents.

**Notes shown:** Contextual search covers 64 of 65 meetings so far; the rest were searched by keywords.

**Cited:**
- 1:1 Maria (Oct 28, 2026): Maria: Busy, but good. The vendor audit wrapped up. | Maria: Mostly. One vendor was late with documents. | Maria: I think the next thing for me is running the vendor reviews myself, end to end.

## dev19 [answer] paraphrase, decision_status, cross_meeting

**Q:** Has anyone made the final call on relocating our workspace?

**Expected:** No final decision was found. The options are renewing Wharf Street (5% higher) or moving to the Delancey building; as of Nov 5 it is still undecided and the board wants the survey results (closing Nov 20) first.

**Required points:** • No final decision found • Options: renew Wharf Street or move to Delancey • Board wants survey results first; survey closes Nov 20

**Forbidden:** • they decided to move to Delancey • they decided to renew Wharf Street

**App (partial, 4.9 s):** No final decision has been made on relocating the workspace. Speaker 1 stated in the facilities check-in meeting on Nov 5, 2026, that the board wants the survey results before anyone picks between Wharf Street and Delancey, and that nothing will be decided before December.

**Notes shown:** Contextual search covers 64 of 65 meetings so far; the rest were searched by keywords.

**Cited:**
- All-hands planning (Oct 14, 2026): Speaker 1: Okay, office space is the big one today. | Speaker 1: Right, so we either renew Wharf Street or move. | Speaker 2: We'd need to budget for the move itself too. | Speaker 1: Yeah, a short survey on commute and how often people come in.
- Facilities check-in (Nov 5, 2026): Speaker 2: Finally. When do they arrive? | Speaker 2: Okay. And the office question?

## dev20 [answer] paraphrase

**Q:** What's holding things up on choosing where we'll be based after June?

**Expected:** The board wants the staff survey results before anyone picks; the survey closes November 20, so likely nothing before December.

**Required points:** • Waiting on the survey results for the board • Survey closes November 20

**Forbidden:** • waiting on the landlord

**App (partial, 5.2 s):** The decision on where to base the office after June is being held up because the lease at Wharf Street is up in June, and while the landlord offered a renewal at five percent higher, the main alternative is the Delancey building, which is twenty minutes further for most people and has more square footage but similar rent per square foot. A final decision has not been made, and Speaker 1 stated that no decision should be made yet to allow for input from people.

**Notes shown:** Contextual search covers 64 of 65 meetings so far; the rest were searched by keywords.

**Cited:**
- All-hands planning (Oct 14, 2026): Speaker 1: Okay, office space is the big one today. | Speaker 2: The Wharf Street lease is up in June.

## dev21 [answer] lexical

**Q:** What was said about the Delancey building?

**Expected:** It has the bigger floor but is about twenty minutes further for most people; rent per square foot is about the same but there are more square feet. Still undecided versus Wharf Street.

**Required points:** • Bigger floor • Twenty minutes further for most people

**Forbidden:** • it is cheaper

**App (partial, 3.7 s):** The Delancey building has the bigger floor, but it's twenty minutes further for most people. The rent is about the same per square foot, but there are more square feet.

**Notes shown:** Contextual search covers 64 of 65 meetings so far; the rest were searched by keywords.

**Cited:**
- All-hands planning (Oct 14, 2026): Speaker 1: Okay, office space is the big one today. | Speaker 2: The main alternative is the Delancey building. | Speaker 3: The Delancey building has the bigger floor, but it's twenty minutes further for most people.

## dev22 [answer] lexical

**Q:** When is the Wharf Street lease up?

**Expected:** June; the landlord offered a renewal at five percent higher.

**Required points:** • June • Renewal offer 5% higher

**App (partial, 3.5 s):** The Wharf Street lease is up in June.

**Notes shown:** Contextual search covers 64 of 65 meetings so far; the rest were searched by keywords.

**Cited:**
- All-hands planning (Oct 14, 2026): Speaker 2: The Wharf Street lease is up in June. | Speaker 1: Right, so we either renew Wharf Street or move.

## dev23 [answer] lexical

**Q:** Were standing desks approved?

**Expected:** Yes, for the third floor, arriving mid December assuming no shipping delays.

**Required points:** • Approved for the third floor • Arriving mid December

**Forbidden:** • all floors

**App (partial, 3.6 s):** Yes, standing desks were approved for the third floor.

**Notes shown:** Contextual search covers 64 of 65 meetings so far; the rest were searched by keywords.

**Cited:**
- Facilities check-in (Nov 5, 2026): Speaker 1: Standing desks got approved for the third floor. | Speaker 1: We got four more spots in the garage. | Speaker 2: How are those assigned? | Speaker 1: First come, first served for now.

## dev24 [qualify] self, commitments, person_date, cross_meeting, ambiguous

**Q:** What follow-up actions did I promise during my calls today?

**Expected:** Today has two calls. In the Lumen Freight call a speaker is shown as Me: Me promised the tax forms by end of day Tuesday and to set up a shared channel this afternoon. In the Northwind call no speaker is identified as the user; there Speaker 1 promised the revised SOW by Monday and Speaker 2 promised to check with legal on the indemnity clause, labeled by speaker, not as the user's.

**Required points:** • Me (Lumen): tax forms by end of day Tuesday • Me (Lumen): set up a shared channel this afternoon • Northwind: user not identified; Speaker 1 revised SOW by Monday • Northwind: Speaker 2 to check legal on the indemnity clause

**Forbidden:** • the user promised the API keys • the user will draft the rate card • the user promised the revised SOW (unqualified) • someone promised to bring support to the next call

**App (answered, 4.6 s):** Me promised to send the tax forms by end of day Tuesday, set up a shared communication channel this afternoon, and draft the rate card for the regional lanes. Me also committed to sending the revised SOW by Monday with updated support hours.

**Notes shown:** Searched meetings from Fri, Nov 6 (“today”).

**Cited:**
- Lumen Freight onboarding (Nov 6, 2026): Me: Hi, thanks for joining. This is the onboarding kickoff for Lumen Freight. | Speaker 2: Glad to be here. We're excited to get started. | Me: Great. So first, paperwork. | Speaker 2: We'll need your tax forms before we can invoice.
- Lumen Freight onboarding (Nov 6, 2026): Speaker 2: That works for us. | Me: Could you draft the rate card for the regional lanes? | Speaker 2: Sure, we can do that. | Me: Thanks. Next, timelines.

## dev25 [answer] self, commitments

**Q:** What did I promise to do on this call?

**Expected:** Me promised the tax forms by end of day Tuesday and to set up a shared channel this afternoon. (The other side will send API keys and draft the rate card; those are not the user's.)

**Required points:** • Tax forms by end of day Tuesday • Shared channel this afternoon

**Forbidden:** • I'll send over the API keys (as the user's) • user will draft the rate card

**App (answered, 3.3 s):** Me promised to get the tax forms by end of day Tuesday, set up a shared channel this afternoon, and draft the rate card for the regional lanes.

**Cited:**
- Lumen Freight onboarding (Nov 6, 2026): Me: Okay, I'll get you the tax forms by end of day Tuesday. | Me: Thanks. Next, timelines. | Speaker 2: We'd like the first shipments to go out in early December. | Me: That should be fine if the integration goes smoothly.

## dev26 [qualify] self, commitments, ambiguous

**Q:** What did I commit to on this call?

**Expected:** No speaker is shown as Me, so the user can't be identified. Commitments by speaker: Speaker 1 will send the revised SOW by Monday with the new hours; Speaker 2 will check with their legal team on the indemnity clause.

**Required points:** • User not identified • Speaker 1: revised SOW by Monday • Speaker 2: check legal on indemnity clause

**Forbidden:** • the user promised the revised SOW (unqualified)

**App (answered, 5.0 s):** Speaker 2 committed to checking with their legal team on the indemnity clause and getting back to the group. Speaker 1 committed to sending the revised SOW by Monday with the new support hours. Speaker 1 also committed to aiming to sign the renewal before the holidays. Speaker 2 suggested a three-year term if the rate is better, but no final decision was made on this. Speaker 1 committed to sending the updated user count by the end of the month. Speaker 2 committed to providing the updated user count by the end of the month. Speaker 1 proposed a two-year term, which was acknowledged but not finalized. Speaker 2 expressed interest in early access to the new reporting feature, which is in beta. Speaker 3 supported the idea of including support staff in future calls. Speaker 1 mentioned that the support hours need to be until eight pm Eastern.

**Notes shown:** Amaranth can't tell which speaker is you, so commitments are listed by speaker. Rename your speaker to “Me” to fix that.

**Cited:**
- Northwind renewal call (Nov 6, 2026): Speaker 3: It now covers third-party data, which our legal team flagged. | Speaker 2: I'll check with our legal team on the indemnity clause and get back to you.
- Northwind renewal call (Nov 6, 2026): Speaker 2: I'll check with our legal team on the indemnity clause and get back to you. | Speaker 1: Thanks. Anything else in the SOW? | Speaker 3: The support hours. We need coverage until eight pm Eastern. | Speaker 1: That's doable, it might change the price a bit.

## dev27 [answer] self, commitments, person_date

**Q:** What did I say I'd take care of after yesterday's interview debrief?

**Expected:** Me will write up feedback for the candidates by Friday noon and book Ingrid's reference calls early next week.

**Required points:** • Write up candidate feedback by Friday noon • Book reference calls for Ingrid early next week

**Forbidden:** • the user will send the offer band to HR • the user will notify Felix and Leah's recruiters

**App (insufficient_evidence, 3.7 s):** I couldn't find that in these meetings.

**Notes shown:** Searched meetings from Thu, Nov 5 (“yesterday”). Contextual search covers 3 of 4 meetings so far; the rest were searched by keywords.

## dev28 [answer] commitments, cross_meeting, multipart, person_date

**Q:** What follow-ups were promised across this week's client calls?

**Expected:** This week in Clients: Brightline review (Nov 4) Speaker 1 revised storyboard by Thursday, Speaker 2 share media plan; Northwind (Nov 6) revised SOW by Monday and legal check on indemnity; Lumen Freight (Nov 6) Me tax forms by Tuesday EOD and shared channel this afternoon, Speaker 2 API keys tomorrow.

**Required points:** • Brightline: revised storyboard by Thursday • Brightline: client shares media plan • Northwind: revised SOW by Monday • Northwind: legal check on indemnity clause • Lumen: tax forms by Tuesday EOD • Lumen: shared channel this afternoon • Lumen: API keys tomorrow (other side)

**Forbidden:** • brand guidelines by Monday (Oct 30 kickoff, last week) • creative brief template (last week)

**App (answered, 5.6 s):** Speaker 2 promised to check with the legal team on the indemnity clause and get back to the group. Speaker 1 committed to sending the revised SOW by Monday with updated support hours. Me promised to provide the tax forms by end of day Tuesday and to set up a shared communication channel this afternoon. Speaker 2 committed to sending over the API keys the next day. Me also asked Speaker 2 to draft the rate card for the regional lanes.

**Notes shown:** Searched meetings from Mon, Nov 2 to Fri, Nov 6 (“this week”).

**Cited:**
- Northwind renewal call (Nov 6, 2026): Speaker 1: Same here. We sent the draft SOW last week.
- Northwind renewal call (Nov 6, 2026): Speaker 2: I'll check with our legal team on the indemnity clause and get back to you. | Speaker 1: Thanks. Anything else in the SOW? | Speaker 3: The support hours. We need coverage until eight pm Eastern. | Speaker 1: That's doable, it might change the price a bit.
- Lumen Freight onboarding (Nov 6, 2026): Speaker 2: And on our side, I'll send over the API keys tomorrow. | Me: Thanks. Next, timelines. | Speaker 2: We'd like the first shipments to go out in early December. | Me: That should be fine if the integration goes smoothly.
- Lumen Freight onboarding (Nov 6, 2026): Me: It's indexed to the weekly diesel price.

## dev29 [answer] paraphrase

**Q:** When will Brightline see the reworked scene-by-scene drawings?

**Expected:** By Thursday (Nov 5): the agency said it would send the revised storyboard after slowing down the last scene.

**Required points:** • Revised storyboard by Thursday

**Forbidden:** • by Monday

**App (partial, 3.7 s):** Brightline will see the reworked scene-by-scene drawings by Thursday.

**Notes shown:** Contextual search covers 64 of 65 meetings so far; the rest were searched by keywords.

**Cited:**
- Brightline campaign review (Nov 4, 2026): Speaker 1: Okay, we can slow down the last scene. | Speaker 2: And I'll share our media plan so you can see the flight dates. | Speaker 1: Music preferences, if you have any. | Speaker 2: Something upbeat, but not too poppy.

## dev30 [answer] paraphrase

**Q:** Which applicant is being invited back for the in-person round?

**Expected:** Ingrid; the panel agreed to bring her back for the onsite / final round.

**Required points:** • Ingrid

**Forbidden:** • Felix • Leah

**App (partial, 3.5 s):** Ingrid is being invited back for the in-person round.

**Notes shown:** Contextual search covers 64 of 65 meetings so far; the rest were searched by keywords.

**Cited:**
- Hiring panel debrief (Nov 5, 2026): Speaker 2: Let's bring Ingrid back for the onsite. | Me: Agreed, Ingrid moves to the final round. | Speaker 2: The case study took too long, people ran over. | Speaker 3: We could cut the second part.

## dev31 [abstain] unanswerable, person_date

**Q:** What were the action items from the Lumen Freight call last week?

**Expected:** There was no Lumen Freight call last week (Oct 26 to Nov 1); the only one is today, Nov 6. Say none was found in that period.

**Required points:** • No Lumen Freight call in Oct 26 to Nov 1

**Forbidden:** • listing today's Lumen items as last week's

**App (insufficient_evidence, 3.6 s):** I couldn't find that in these meetings.

**Notes shown:** Searched meetings from Mon, Oct 26 to Sun, Nov 1 (“last week”).

## dev32 [answer] lexical

**Q:** What's the problem with the Northwind indemnity clause?

**Expected:** It is broader than last year: it now covers third-party data, which their legal team flagged.

**Required points:** • Broader than last year • Now covers third-party data

**App (partial, 3.8 s):** The main problem with the Northwind indemnity clause is that it now covers third-party data, which was flagged by the legal team.

**Notes shown:** Contextual search covers 64 of 65 meetings so far; the rest were searched by keywords.

**Cited:**
- Northwind renewal call (Nov 6, 2026): Speaker 3: The main one is the indemnity clause, it's broader than last year. | Speaker 2: I'll check with our legal team on the indemnity clause and get back to you. | Speaker 1: That's doable, it might change the price a bit. | Speaker 1: I'll send the revised SOW by Monday with the new hours.

## dev33 [answer] paraphrase, person_date, speaker_vs_mentioned

**Q:** What did Maria suggest as her next growth step last week?

**Expected:** In her Oct 28 one-on-one Maria said her next step is running the vendor reviews herself end to end, leading the Q1 review cycle rather than just prepping decks.

**Required points:** • Run vendor reviews end to end • Lead the Q1 review cycle

**Forbidden:** • mentoring the new analysts (that was Nov 3) • PMP certification • taking on the forecasting model

**App (answered, 4.2 s):** Maria suggested that her next growth step is running the vendor reviews myself, end to end, like actually leading the Q1 review cycle, not just prepping the decks.

**Notes shown:** Searched meetings from Mon, Oct 26 to Sun, Nov 1 (“last week”).

**Cited:**
- 1:1 Maria (Oct 28, 2026): Speaker 1: Hey Maria, how's the week going? | Maria: Busy, but good. The vendor audit wrapped up. | Maria: Mostly. One vendor was late with documents. | Maria: Sure, I've been thinking about it.

## dev34 [answer] followup, changed_plan, person_date

**Q:** Did that change this week?

**Expected:** Yes. On Nov 3 Maria said she'd rather mentor the two new analysts instead, and the vendor reviews can wait until next year.

**Required points:** • Nov 3: prefers mentoring the two new analysts • Vendor reviews can wait until next year

**Forbidden:** • no change

**App (partial, 4.9 s):** Yes, Maria changed her suggestion this week. She stated that she had changed her mind and now intends to mentor the two new analysts instead of running the vendor reviews, which can wait until next year.

**Notes shown:** Searched meetings from Mon, Nov 2 to Fri, Nov 6 (“this week”). Contextual search covers 15 of 16 meetings so far; the rest were searched by keywords.

**Cited:**
- 1:1 Maria (Nov 3, 2026): Speaker 1: Hey, how was the weekend? | Maria: Good, quiet. Yours? | Speaker 1: Good. So, picking up from last time. | Maria: Yeah, about that. I've changed my mind a bit.

## dev35 [answer] person_date, paraphrase

**Q:** What did Maria say last week about where she wants to grow?

**Expected:** Asked on Monday Nov 9, last week is Nov 2 to 8: on Nov 3 Maria said she now wants to mentor the two new analysts instead of the vendor reviews.

**Required points:** • Mentoring the two new analysts • Vendor reviews deferred

**Forbidden:** • running the vendor reviews is her current plan

**App (partial, 3.9 s):** Maria said she wants to mentor the two new analysts instead of doing vendor reviews, and that the vendor reviews can wait until next year.

**Notes shown:** Searched meetings from Mon, Nov 2 to Sun, Nov 8 (“last week”). Contextual search covers 15 of 16 meetings so far; the rest were searched by keywords.

**Cited:**
- 1:1 Maria (Nov 3, 2026): Speaker 1: Hey, how was the weekend? | Maria: Good, quiet. Yours? | Speaker 1: Good. So, picking up from last time. | Maria: Yeah, about that. I've changed my mind a bit.

## dev36 [answer] speaker_vs_mentioned, adversarial

**Q:** Who said they want to take over the forecasting model?

**Expected:** An unnamed speaker (Speaker 2) in the Oct 29 ops standup. Maria attended that standup but the speaker is not identified as her.

**Required points:** • Speaker 2 in the Oct 29 ops standup • Not attributable to Maria

**Forbidden:** • Maria said it

**App (partial, 3.7 s):** Speaker 2 said they want to take on the forecasting model, if that's okay.

**Notes shown:** Contextual search covers 64 of 65 meetings so far; the rest were searched by keywords.

**Cited:**
- Ops standup (Oct 29, 2026): Speaker 2: My next step is probably to take on the forecasting model, if that's okay. | Speaker 3: I can show you how the current model works.

## dev37 [qualify] adversarial, speaker_vs_mentioned

**Q:** Did Maria bring up her development plans in the ops standup?

**Expected:** Maria is only an attendee; no line there is attributed to her. Her growth step came up in her Oct 28 one-on-one (vendor reviews).

**Required points:** • No attributed Maria speech in the standup • Her growth discussion was in the Oct 28 one-on-one

**Forbidden:** • Maria wants the forecasting model

**App (partial, 4.4 s):** Yes, Maria brought up her development plans in the ops standup. In the meeting on Oct 28, 2026, Maria stated, 'I think the next thing for me is running the vendor reviews myself, end to end. Like, actually leading the Q1 review cycle, not just prepping the decks.' This indicates she discussed her development plans during the meeting.

**Notes shown:** Contextual search covers 64 of 65 meetings so far; the rest were searched by keywords.

**Cited:**
- 1:1 Maria (Oct 28, 2026): Speaker 1: Hey Maria, how's the week going? | Maria: Busy, but good. The vendor audit wrapped up. | Maria: Mostly. One vendor was late with documents. | Speaker 1: Okay. So I wanted to use some time on your development.

## dev38 [answer] speaker_vs_mentioned

**Q:** Who brought up Maria getting a certification?

**Expected:** Speaker 2 in the Oct 29 platform weekly mentioned that back in the summer Maria said she wanted a PMP cert; Maria herself did not say it in these meetings.

**Required points:** • Speaker 2 in the Oct 29 platform weekly • Referred to something Maria said back in the summer

**Forbidden:** • Maria proposed a certification last week

**App (insufficient_evidence, 3.9 s):** I couldn't find that in these meetings.

**Notes shown:** Contextual search covers 64 of 65 meetings so far; the rest were searched by keywords.

## dev39 [abstain] unanswerable

**Q:** What did Maria say about relocating to the Denver office?

**Expected:** Nothing about Denver or relocating appears.

**Required points:** • No evidence found

**Forbidden:** • Maria wants to relocate

**App (insufficient_evidence, 3.7 s):** I couldn't find that in these meetings.

**Notes shown:** Contextual search covers 64 of 65 meetings so far; the rest were searched by keywords.

## dev40 [answer] dst_boundary, person_date, paraphrase

**Q:** Last week, what did the on-call folks report about our web front door's security certificates?

**Expected:** In the Sunday Nov 1 handoff (after DST ended): the TLS certs on the public gateway were rotated, the new expiry is in February with a calendar reminder, and one client that had pinned the old cert was sorted.

**Required points:** • TLS certs on the public gateway rotated • New expiry in February

**Forbidden:** • staging gateway certificate expiry warning (that was Monday Nov 2, this week)

**App (answered, 4.6 s):** The on-call folks reported that during the weekend, TLS certs were rotated on the public gateway, and one client had pinned the old cert, which was resolved. The new expiry is in February, and a reminder was set in the calendar.

**Notes shown:** Searched meetings from Mon, Oct 26 to Sun, Nov 1 (“last week”).

**Cited:**
- Weekend on-call handoff (Nov 1, 2026): Speaker 1: Morning. Clocks went back, so I almost showed up an hour early. | Speaker 2: Ha, same. Okay, handoff. | Speaker 1: Over the weekend we rotated the TLS certs on the public gateway. | Speaker 1: New expiry is in February, I put a reminder in the calendar.

## dev41 [answer] dst_boundary, person_date, paraphrase, multipart

**Q:** What got passed along to us from whoever covered the weekend shift yesterday?

**Expected:** Asked Monday Nov 2: the Nov 1 handoff covered rotated TLS certs on the public gateway (expiry February), two false queue-backlog alarms Saturday night, and that next week's pager goes to the database team.

**Required points:** • Gateway TLS certs rotated, new expiry February • Two false queue backlog alarms Saturday night • Pager goes to the database folks next week

**Forbidden:** • Mariner export timeout (that's from today's review)

**App (answered, 4.5 s):** The certificate inventory sheet needs updating and the backup job on the reporting host was slow, about double the usual time. Speaker 2 noted that the certificate inventory sheet needs updating and said they would do it. Speaker 1 mentioned the backup job was slow, and Speaker 2 suggested it might be due to end-of-month data.

**Notes shown:** Searched meetings from Sun, Nov 1 (“yesterday”).

**Cited:**
- Weekend on-call handoff (Nov 1, 2026): Speaker 2: Same threshold problem as before? | Speaker 1: Yeah, it needs tuning. I left a note on the ticket. | Speaker 2: Okay. | Speaker 1: Heads up, next week's pager goes to the database folks, not us.

## dev42 [answer] dst_boundary, person_date, changed_plan, paraphrase, cross_meeting

**Q:** What did we talk about last week regarding who carries the beeper?

**Expected:** Asked Mon Nov 2, last week is Oct 26 to Nov 1: on Oct 26 the pager rotation was changed to weekly with Thursday handoffs; on Nov 1 the handoff noted next week's pager goes to the database folks (first weekly cycle).

**Required points:** • Oct 26: rotation goes weekly, handoffs Thursdays • Nov 1: next week's pager goes to the database team

**Forbidden:** • they kept the two-week rotation (Oct 25 retro, outside the week and superseded)

**App (answered, 4.0 s):** Last week, it was decided that the pager rotation goes weekly starting next cycle, with handoffs on Thursdays. The first weekly cycle begins, so the database folks will carry the beeper next week, not the original team.

**Notes shown:** Searched meetings from Mon, Oct 26 to Sun, Nov 1 (“last week”).

**Cited:**
- Ops week start (Oct 26, 2026): Speaker 1: Morning, quick week start. | Speaker 2: Before we start, about last night's retro. | Speaker 2: So the pager rotation goes weekly starting next cycle, with handoffs on Thursdays. | Speaker 1: Thanks. What's on this week?
- Weekend on-call handoff (Nov 1, 2026): Speaker 1: Heads up, next week's pager goes to the database folks, not us. | Speaker 2: Because of the new weekly rotation? | Speaker 1: Right, first weekly cycle.

## dev43 [answer] paraphrase

**Q:** Which customer is having trouble pulling large amounts of data out of the product?

**Expected:** Mariner keeps hitting the export timeout on big reports (about two million rows); short term raise the timeout, long term async exports.

**Required points:** • Mariner • Export timeout on big reports • Raise the timeout short term; async exports long term

**Forbidden:** • Northwind

**App (partial, 3.4 s):** The Mariner account is having trouble pulling large amounts of data out of the product.

**Notes shown:** Contextual search covers 64 of 65 meetings so far; the rest were searched by keywords.

**Cited:**
- On-call review (Nov 2, 2026): Speaker 1: Staging, not production? | Speaker 3: The Mariner account keeps hitting the export timeout on big reports. | Speaker 3: They're exporting about two million rows at a time.

## dev44 [abstain] unanswerable

**Q:** Which team won the fall hackathon?

**Expected:** No hackathon appears.

**Required points:** • No evidence found

**Forbidden:** • any winner

**App (insufficient_evidence, 3.6 s):** I couldn't find that in these meetings.

**Notes shown:** Contextual search covers 64 of 65 meetings so far; the rest were searched by keywords.

## dev45 [answer] paraphrase, notes_only

**Q:** What did the travel allowance end up at for the first quarter?

**Expected:** $18k for Q1, down from $25k, per the user's notes on the Oct 22 budget review (the transcript only says the number would be settled offline).

**Required points:** • $18k for Q1 • Down from $25k

**Forbidden:** • $25k is the Q1 travel budget

**App (partial, 3.8 s):** The travel allowance ended up being over by about ten percent for the first quarter.

**Notes shown:** Contextual search covers 64 of 65 meetings so far; the rest were searched by keywords.

**Cited:**
- Budget review (Oct 22, 2026): Speaker 2: Okay. Travel? | Speaker 1: Let's settle the travel number offline, I need to check a few things.
- Finance sync (Nov 3, 2026): Speaker 1: And travel? | Speaker 2: We're over by about ten percent for the quarter.

## dev46 [answer] paraphrase

**Q:** Can the platform group bring on anyone new right now?

**Expected:** Not net new: there is a hiring freeze on the platform side until February; backfills are allowed.

**Required points:** • Freeze until February • Backfills allowed

**Forbidden:** • backfills are frozen too

**App (partial, 3.8 s):** No, the platform group cannot bring on anyone new right now. The headcount freeze on the platform side is in effect until February, and while backfills are allowed, net new hires are not.

**Notes shown:** Contextual search covers 64 of 65 meetings so far; the rest were searched by keywords.

**Cited:**
- Budget review (Oct 22, 2026): Speaker 1: We're freezing new hires on the platform side until February. | Speaker 1: Backfills are allowed, net new is not.

## dev47 [partial] paraphrase, incomplete_index, person_date

**Q:** What price breaks for partners who resell us were talked about this week?

**Expected:** From indexed evidence (Nov 3 finance sync): resellers get 12% standard and 18% is proposed above fifty seats. The Nov 5 partner pricing workshop is not yet indexed, so coverage is incomplete (it added a 22% platinum tier).

**Required points:** • 12% standard • 18% proposed above fifty seats • States that some history is not yet indexed / coverage incomplete

**Forbidden:** • claiming the answer is complete

**App (partial, 3.7 s):** The price break for partners who resell was discussed as eighteen percent for deals above fifty seats, which matches what the competition offers. Speaker 3 noted that the current standard reseller discount is twelve percent.

**Notes shown:** Searched meetings from Mon, Nov 2 to Fri, Nov 6 (“this week”). Contextual search covers 15 of 16 meetings so far; the rest were searched by keywords.

**Cited:**
- Finance sync (Nov 3, 2026): Speaker 1: Okay, three things today. Reseller discounts, the CRM contract, and travel. | Speaker 2: Let's do the CRM first, that's the urgent one. | Speaker 2: The Pipewell quote came back forty percent over what we budgeted. | Speaker 1: Ouch.

## dev48 [answer] trimmed, paraphrase

**Q:** When are we now planning to put the mobile app out?

**Expected:** December fifth (corrected transcript), moved because Apple flagged the subscription screen wording.

**Required points:** • December fifth • Because of app store review of subscription screen wording

**Forbidden:** • December fifteenth • November ninth

**App (insufficient_evidence, 4.0 s):** I couldn't find that in these meetings.

**Notes shown:** Contextual search covers 64 of 65 meetings so far; the rest were searched by keywords.

## dev49 [answer] trimmed, negation

**Q:** Are we rolling out to every region on day one?

**Expected:** No. Canada and the UK first, then the rest after two weeks.

**Required points:** • No • Canada and UK first • Rest after two weeks

**Forbidden:** • ship to all regions at once

**App (partial, 3.7 s):** No, the rollout is not to every region on day one. The plan is to start with Canada and the UK, then proceed to the rest of the regions after two weeks.

**Notes shown:** Contextual search covers 64 of 65 meetings so far; the rest were searched by keywords.

**Cited:**
- Launch go/no-go (Nov 2, 2026): Speaker 3: Okay. And the rollout plan? | Speaker 1: Marketing needs the new date today. | Speaker 3: I'll tell them after this. | Speaker 1: Support readiness?

## dev50 [abstain] unanswerable, trimmed

**Q:** What was said about the hotel block for the sales offsite?

**Expected:** That content was only in lines removed by Start from Here; nothing current mentions it.

**Required points:** • No current evidence

**Forbidden:** • Harborview • forty rooms

**App (insufficient_evidence, 3.8 s):** I couldn't find that in these meetings.

**Notes shown:** Contextual search covers 64 of 65 meetings so far; the rest were searched by keywords.

## dev51 [abstain] unanswerable, adversarial

**Q:** Is there a plan to combine the design and research teams?

**Expected:** Nothing in current history; the only mention was in a deleted meeting.

**Required points:** • No evidence found

**Forbidden:** • merging in January • cut a layer of management

**App (insufficient_evidence, 3.8 s):** I couldn't find that in these meetings.

**Notes shown:** Contextual search covers 64 of 65 meetings so far; the rest were searched by keywords.

## dev52 [answer] paraphrase, adversarial

**Q:** What did the outside security testers turn up in our file intake service?

**Expected:** Two high severity issues in the upload service, both about file type validation (e.g. a script disguised as an image gets served back), plus five medium, mostly header, issues.

**Required points:** • Two high severity issues in the upload service • File type validation

**Forbidden:** • the audit passed with no findings

**App (partial, 4.0 s):** The outside security testers found two high severity issues in the upload service, both related to file type validation. They noted that a script could be uploaded disguised as an image and served back.

**Notes shown:** Contextual search covers 64 of 65 meetings so far; the rest were searched by keywords.

**Cited:**
- Security vendor demo (Oct 27, 2026): Speaker 3: Sure. So the pen test found two high severity issues in the upload service. | Speaker 3: Both are around file type validation. | Speaker 3: Anyway, there were also five medium issues, mostly headers. | Speaker 1: Good. What's the timeline for the high ones?

## dev53 [answer] followup

**Q:** And what's the plan for fixing them?

**Expected:** Fixes are due by November 20, then the affected areas are retested; the platform team will do the fixes.

**Required points:** • Fixes due November 20 • Retest afterwards

**Forbidden:** • no fixes needed

**App (partial, 4.9 s):** The fixes for the high severity issues are due by November twentieth, followed by a retest. The platform team, with Speaker 2 assigning the work today, will handle the fixes on the team's side.

**Notes shown:** Contextual search covers 64 of 65 meetings so far; the rest were searched by keywords.

**Cited:**
- Security vendor demo (Oct 27, 2026): Speaker 1: Thanks for walking us through the report. | Speaker 3: Sure. So the pen test found two high severity issues in the upload service. | Speaker 3: Both are around file type validation. | Speaker 1: Can you give an example?

## dev54 [clarify] ambiguous

**Q:** Summarize the meeting.

**Expected:** Library scope with many meetings; ask which meeting.

**Required points:** • Ask which meeting

**Forbidden:** • summarizing an arbitrary meeting as if it were the one meant

**App (partial, 5.4 s):** The team sync meetings discuss ongoing project status, ownership assignments, and follow-up actions. Key topics include data migration being behind, the design review having open questions, the billing service being on track or at risk of slipping, the analytics being behind, and several items needing owners such as the onboarding flow, hiring plan, and mobile app. Follow-ups are assigned to individuals like Gus, Jun, Hana, and Fay for various tasks. The status page is noted as on track or needing another pass, and the roadmap is generally on track with some discussion about delays. No final decisions are made beyond assigning follow-ups and noting current status.

**Notes shown:** Contextual search covers 64 of 65 meetings so far; the rest were searched by keywords.

**Cited:**
- Team sync 3 (Oct 3, 2026): Speaker 3: Ben will follow up on the hiring plan next week. | Speaker 2: Gus said the team rituals is on track. | Speaker 1: Jun said the hiring plan needs an owner. | Speaker 2: Ana said the documentation needs another pass.
- Team sync 16 (Oct 14, 2026): Speaker 2: Jun will follow up on the hiring plan next week.
- Team sync 18 (Oct 16, 2026): Speaker 2: Chloe will follow up on the team rituals next week.
- Team sync 29 (Oct 26, 2026): Speaker 3: Jun will follow up on the team rituals next week.

## dev55 [clarify] ambiguous, speaker_vs_mentioned

**Q:** What did Speaker 2 say about the budget?

**Expected:** 'Speaker 2' is a per-meeting label, not one person; ask which meeting (or answer per meeting, clearly labeled).

**Required points:** • Speaker labels are per meeting

**Forbidden:** • merging different meetings' Speaker 2 into one person

**App (partial, 5.1 s):** Speaker 2 said the budget might slip a little, the budget is a bit behind, and the budget came up again. They also noted that the budget was discussed briefly and that Dev will follow up on the budget next week. In the budget review, Speaker 2 said the budget was discussed and that the final review is mid-November, with Speaker 1 noting that the second draft will be ready by then.

**Notes shown:** Contextual search covers 64 of 65 meetings so far; the rest were searched by keywords.

**Cited:**
- Team sync 7 (Oct 6, 2026): Speaker 3: Eli said the search feature looks fine for now. | Speaker 1: I think that makes sense. | Speaker 2: Ana will follow up on the mobile app next week. | Speaker 3: Hana said the release notes needs another pass.
- Team sync 17 (Oct 15, 2026): Speaker 2: The budget was discussed briefly and the support queue should wrap up soon. | Speaker 1: The support queue came up again and the budget was discussed briefly. | Speaker 2: Dev will follow up on the budget next week. | Speaker 3: Chloe will follow up on the budget next week.
- Budget review (Oct 22, 2026): Speaker 2: Fine. Marketing? | Speaker 1: No, but the events budget moved to them, so it evens out. | Speaker 2: Sure. | Speaker 1: Good. Office costs?

