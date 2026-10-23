# Design review transcript (2026-10-23)

Source: /Users/alex/Movies/Clips/clip-2026-10-23T18-22-31-539Z-q4fonr/clip.mp4 (14 min 19 s). Transcribed with Whisper large-v3-turbo; timestamps are mm:ss into the recording.

[00:01] All right, let's do a quick design review on Amaranth and compare it to Granola, which we're
[00:07] pulling some feature inspiration from. Right now, I like that we have notes. I like that the notes
[00:14] have attribution. I don't love the way these are broken up. It's really tough to read. I'm not sure
[00:20] if this should be something like footnotes or like highlighted words or sections that maybe link back.
[00:25] I also see a lot of the attribution is not necessarily exact or maybe draws a little too
[00:31] broadly. So maybe for now, that's something we could like toggle or hide and then I could turn
[00:38] it on if I want to link to where something came from. Topics we don't really need. Open questions
[00:46] and decisions are not bad to have. But one thing I'm curious about is how this templating works,
[00:54] because it would be nice to write my own template and be able to say, hey, here's the subsections I
[00:58] want. Infer from those subsections what we want the notes to do. I also recognize that may slow notes
[01:04] down. So just a consideration. Your notes and private scratchpad. Let's figure out a way to
[01:11] hide or make those visually optional. It's just a lot of extra noise on the screen and not something
[01:15] I'm going to use right now. I may use them later. I like where your head's at. So don't necessarily
[01:22] delete the feature, but let's make more of this hideable. So when I look at my notes, I can see
[01:27] very quickly what was this meeting about. Here's a quick overview. Here's the things I need to act on.
[01:31] Let's move forward. Just simplify that section. The transcript is awesome. I really like how granular
[01:40] the transcript is. It's really easy to skim through and find things. It's really easy to link back to
[01:44] discussions. It might be nice to explore a different way of displaying this more like a
[01:51] conversational style transcript like you might see in a text message window. I'll pull an example up
[01:56] in Granola if I can to show they use kind of the bubbles on each side. But since we have a lot of
[02:01] meetings with multiple speakers, I recognize that could pose a UI challenge. So having the speaker
[02:06] mentions here is good. It might be helpful to pull the speaker name out to the side and actually have
[02:13] more of a three columnar view instead of two. The reason for that being, then I can read the
[02:18] conversation as like a transcript of notes, but I can see where attribution is. And additionally,
[02:24] that would make it easier to have these sections where like, for example, speaker one is every one of
[02:29] these lines. And it would be nice to just say speaker one, and then have the text. And then when we change
[02:34] speakers, we add the extra speaker there. Later on, that'll make it easier to do things like pull in
[02:39] avatars from meeting platforms where we can get access to them and just generally make this easier
[02:45] to read and clean up. I also don't need the audio was not recorded to be as visible. In this particular
[02:54] transcript, it's not a big deal. But if I look at a longer transcript, there are a lot of these little
[03:01] weird orange pop ups that are just sort of tough to see. So let's find a way to maybe have like a,
[03:07] I don't know if we want to call it like a debug mode. But let's have some sort of toggle on this page,
[03:12] similar to the notes page where we can go from quick review mode into detail mode, and give me
[03:18] something that I can basically press a toggle or a button that will then display all of things like the
[03:22] speech wasn't transcribed, or there's overlap in speakers, things I may need to know. But if I just want to by
[03:28] default skim through the transcript, I want to be able to do that with a really simple just skim
[03:34] through. So lighter, lighter weight view. And recording notes here are great. Keep those for
[03:39] now, leave them just like they are. I think that's awesome. And we don't need to make any changes to
[03:42] this. So that that one, any changes to the recording view for now is out of scope. Maybe later on,
[03:48] we'll work the event login a little differently. Let's talk about the left panel here. Having the
[03:54] meeting history available is great. One little UI quirk that I noticed is I can change the names of
[04:02] meetings. But I don't really know that that's a text box without clicking into it to try. And I
[04:08] don't know how many other places there may be in the application that they're edible, editable fields
[04:13] that are not clearly editable. So what I would like to do instead is rather than being able to change
[04:19] this up here in the main pane, I'd like rename to be a context menu option on the meeting itself.
[04:25] So when I right click on the meeting, I shouldn't just have delete, I should also have rename.
[04:29] And that should let me manage the title or any other fields we want to be able to change
[04:35] over here on the meeting card. That way, what's up here in the top will be static.
[04:40] And if I want to make that change, I make the change over here. And then it's reflected elsewhere
[04:44] in the UI. So that would be kind of what updates the database for us. I also don't necessarily need
[04:51] these audio saved and processed notes. I recognize that things may be processing, but let's think about a
[04:57] simpler way to display that. What I have in my mind is something like when something is processing,
[05:03] maybe there's just a little spinner here, or there's a little like warning symbol, something
[05:07] very lightweight that I can mouse over to get a tooltip that says audio processing. But once the
[05:13] meeting is fully processed and complete, if we display anything, which you may not need to,
[05:17] we display something like just a check. And again, there could be a tooltip associated with that check.
[05:22] What that will result in is the meeting list should be a lot lighter weight should just be the title,
[05:27] the time, the duration of the meeting. I do like the way that's set up right now. But we don't need
[05:32] this extra context unless I have somehow expanded it gone into a debug mode or really want that.
[05:37] I just want a really lightweight indicator. For recording settings themselves, I am a little bit
[05:45] of mixed mind here, we can already collapse a sidebar, which is great. I want I want there to be a
[05:49] sidebar, I want to be able to manage it. But it's pretty heavy right now to come over to this recorder
[05:54] form and hit record. And there's a lot of extra context. And just it's kind of messy. It might be
[06:01] nice to just have some defaults that are in the settings for the application rather than me manually
[06:07] tweaking them for each recording. But have those defaults in the settings and then have a record
[06:13] button that just lets me go ahead and kick off a new meeting. I will later on want to automate this
[06:20] and provide some extra functionality. But for now, I'll be manually clicking record and stop.
[06:24] So having something like a record button here that kicks off a new meeting focuses on the transcript.
[06:29] And then when I'm done, I hit stop, it stops the recording, it commits the transcript. And then once
[06:35] the transcript is fully completed, moves over to notes and starts generating those would be nice.
[06:39] That means that we can drop this whole form in favor of that record note, record button somewhere
[06:47] on the header here, just something really lightweight. And again, we'll want to move those
[06:51] into a settings dialog or something that we can expand. So even if there's something like this,
[06:57] where there's a dual button that I can click once and it will record, or I can hit a drop down arrow
[07:02] and change settings, that would be fine. But what I really want to get to is a place where this sidebar
[07:07] is just a list of historic meetings. And the recording interfaces are either intuitive defaults
[07:13] or are stored elsewhere in the UI. Those are the big things right now other other functionality,
[07:20] other features are great, really like the model management being right here and having lots of
[07:25] information about it. That's very helpful. Yeah, we're in not terrible shape. Let's take a look at
[07:34] granola together. Where did I put that? Here it is. All right. So we're pulling a lot of inspiration
[07:44] from the UI in granola. I do not want to copy this exactly. But since I'm used to navigating this UI,
[07:50] let me point out some things that I really like. These are things that we can work towards and think
[07:54] about. You'll notice in granola, the text is a lot smaller, we get a lot more use of our screen
[08:00] real estate. I like that. Could be a setting, you know, if there's accessibility considerations,
[08:05] we might want to blow that up. It's not an issue for me right now, thankfully. So I would like to
[08:09] lean into this much lighter weight style UI with smaller text and lots of really informative small
[08:15] graphics. We can use emoji for that as a stand in or later on, we can even generate some custom
[08:20] SVGs of our own. I don't need to worry about spaces. And I don't need to worry about things like
[08:25] account management. Right now, Amaranth is a local app. You open it up, play, not really worried about
[08:31] profiles yet. So we don't have to worry about that kind of thing. And because we don't have a cloud
[08:35] component, I don't really need like invitations. So the sharing feature that's already in Amaranth
[08:40] works great. Don't need to pull that. One big feature that I do really like is search. I recognize
[08:47] that is going to require a big lift. That will be its own milestone. That is not a simple task.
[08:52] But I would like to start thinking about where a search interface would live in the Amaranth UI
[08:57] so that I can look back through transcripts or notes or speaker names and find information.
[09:03] That's a pretty key feature that we'll need to build towards. So start thinking about in our UI
[09:09] considerations where that should go. I also really like the simplicity of the sidebar here. Again,
[09:17] we have some really simple icons down here at the bottom. We don't have to worry about plans with
[09:21] Amaranth since it's local, but this is where I would expect to see something like a meeting history
[09:26] or list currently in the sidebar in Amaranth. So once we have some of that layer weight UI,
[09:31] maybe we could pull meetings over here, get the recording out. That would be similar to the way
[09:35] new note works inside Granola. And just as this is working, something like a tooltip with a keyboard
[09:42] shortcut would be fantastic. That'd make it a lot easier to navigate. If you'll notice when I hit new note,
[09:47] this is in record mode right now. It does not give me the live transcript by default. It actually hides
[09:53] the transcript down here. I don't love that. I would rather the transcript be front and center
[09:58] because if I'm in the meeting, I don't need to look at a blank notes pane. I want to see the transcript
[10:03] so I can reference it quickly. So rather than hiding the transcript, do not use the modal style this way.
[10:09] The reason I'm showing you the transcript is you can see kind of the discussion bubble approach here,
[10:13] and that would be a nice visual in Amaranth. Just make that the transcript panel as the default while
[10:19] the meeting is recording. Take me to notes if I open it up after the meeting is done, or once the
[10:24] meeting completes, maybe we transition over there. One other thing that Granola does that I don't like,
[10:30] but I want to think about where the data would go, is things like this people and calendar setup.
[10:35] I would eventually like to be able to link an Amaranth recording to a calendar event and let that
[10:41] automatically populate the name of the meeting. You can see here the way this works is you actually
[10:46] select a calendar event, but the scope is limited and that also requires some account integrations.
[10:51] Again, things to think about in the UI for future features, but not something we need to implement yet.
[10:57] Creating some placeholders that we could start playing with and thinking about would be
[11:00] really nice. So that may be something worthwhile. We also show the people in the meeting. And again,
[11:06] right now, this requires, this is actually pulling from Google Calendar. This would require a calendar
[11:10] integration. We don't have that feature yet. We should think about speccing out a milestone for it.
[11:15] But just thinking about being able to say during the transcription, because we're doing diarization
[11:21] in parallel, we should be able to say like five different speakers or four speakers or one speaker.
[11:26] That's a little bit of a gut check for whoever's monitoring during the meeting that they can see
[11:31] that all of that information is coming in and we're not missing anybody in the conversation.
[11:35] Plus, I really like what Amaranth is doing with selecting the speaker and being able to update
[11:39] their name manually. So we'll keep that feature in place. Granola also has a concept of folders,
[11:45] meaning we can organize where meetings are stored. I would like to add that feature to Amaranth. I
[11:52] would like to be able to add meetings to folders. To be very, very clear, I want this to be a folder
[11:59] or subdirectory style tree hierarchy, not tags. We do not need to implement tags. I'm not interested in
[12:05] tags. I don't need to tag anything. But for organizational purposes, I would like to be
[12:09] able to say these are meetings for a particular client in this directory or meetings for a
[12:14] particular project in this directory. The directories don't need to be nested yet. It can be single
[12:20] layer directories. But adding that both in the meeting management and then thinking about how we
[12:25] display those in the sidebar would be a good thing to consider. It would be nice to manage them
[12:30] directly from the sidebar. An example that you might be able to draw from is something like a
[12:34] browser sidebar where I can create a folder and then drag tabs into it. I'd like to do the same
[12:39] thing in Amaranth where I can create a folder and then drag meetings into it. And that will help me
[12:43] organize. Granola has the same problem Amaranth does right now of hiding editable fields. So like
[12:52] without that cursor, I don't know what's editable. But at least we have the cursor. So if there are
[12:57] editable fields inside Amaranth that we can't easily make more visible, let's make sure that
[13:03] when they are focused, we get some sort of contrast color cursor added. Last thing I want to consider,
[13:10] again, this is a bigger milestone, but something worth noting. Amaranth currently operates in dark
[13:16] mode. I would like it to have a light mode option. I don't think there is one. I'm going to go double
[13:27] light mode option. There should be a toggle for that somewhere easily found on the screen. And we can pull
[13:32] just like we've pulled sort of default dark mode coloring, we can pull default, reasonable contrast
[13:36] light mode coloring from pretty much any example Mac OS app in the world. I'm not super picky about the
[13:43] exact colors. I trust you to decide those. But I would like there to be a light mode option. And that should
[13:49] be its own task, its own milestone, however, we want to organize that. But I recognize that will require a lot of
[13:54] changes to the code base, but should not require a lot of changes to the UI other than adding a toggle somewhere.
[14:00] Again, thinking about this as a little bit less skeuomorphic, lighter weight, smaller icons, that kind of thing.
[14:06] Maybe that's something like a sun moon emoji toggle. We'll just keep it really light for now. We don't have to generate
[14:11] any special SVGs yet. Thanks so much. Let me know if you have questions.
