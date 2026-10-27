# Ask anything eval (answer-v1)

| Metric | Result |
|---|---|
| Questions | 20 (18 answerable, 2 unanswerable) |
| Citation validity (every citation names a passage whose evidence resolves) | 20/20 (100%) |
| Correct (answerable: answered citing an expected line; unanswerable: refused) | 19/20 (95%) |
| Answerable answered with an expected line cited | 17/18 (94%) |
| Answerable refused | 1/18 (6%) |
| Retrieval found an expected line (top 12) | 18/18 (100%) |
| … within the passages that fit the prompt budget | 18/18 (100%) |
| First answer text | median 2.25 s · p90 2.58 s · max 2.63 s |
| Full answer | median 2.89 s · p90 3.78 s · max 3.83 s |
| Injection suite | 15/15 (100%) passed |

| id | kind | ok | first | total | answer | cited |
|---|---|---|---|---|---|---|
| q01 | single | ✓ | 0.65 | 0.99 | They decided to call the section 'facility'. | notes; notes; 00:27 |
| q02 | single | ✓ | 0.71 | 0.95 | They agreed to meet every other week. | notes |
| q03 | single | ✓ | 2.31 | 3.09 | Speaker 2 said the company tracks client-validated outcomes to ensure that their work aligns with explicit client goals and to measure value that clients have actually realized, preventing situations where work is done without clear purpose or attribution. | 12:39; notes; 13:33; 11:57 |
| q04 | single | ✓ | 2.45 | 2.96 | Leesa and Chris are expected to stay on the contract until the end of the year. | notes; 12:34; notes |
| q05 | single | ✓ | 2.06 | 2.95 | ETC is a team in Chennai, India, that has been contracted by the company to offshore part of the workload. Emily is nervous about working with them because she is concerned about the time difference, potential language barriers, and differences in working styles. | 18:00; notes; notes; 19:10; 20:05 |
| q06 | single | ✓ | 1.86 | 2.39 | Gary read the news of the AI-discovered website vulnerability proactively before Speaker 1 even came online and had already put in the fix. | 06:09 |
| q07 | single | ✓ | 2.24 | 3.05 | Bob is looking for new hires who can take Figma designs, add a little opinion, and build websites using existing templates, ideally someone who is a design-web dev switch hitter and cheaper than current rates. He wants them to start potentially within another month. | 13:16; 12:55 |
| q08 | unanswerable | ✓ | 2.23 | 2.52 | I couldn't find that in these meetings. |  |
| q09 | single | ✓ | 1.38 | 1.75 | Speaker 5 offered to reach out to Infinite Red about referring React Native work. | notes; 08:27 |
| q10 | single | ✗ | 1.90 | 2.14 | I couldn't find that in these meetings. |  |
| q11 | single | ✓ | 2.32 | 3.56 | Speaker 2 wants the design to say exactly how things should be built to avoid leaving the tech team in a state of uncertainty, as current practices lead to assumptions that cause frustration, disillusionment, and potential departures from the company. This approach ensures that functionality is clearly defined and that the tech team is not left to guess or make assumptions about how the design should work. | 03:41; 02:23; 11:29; 13:52; 09:54 |
| q12 | unanswerable | ✓ | 1.91 | 2.21 | I couldn't find that in these meetings. |  |
| q13 | single | ✓ | 2.23 | 2.68 | The team settled on using GPT Five Point Four and Pi as the agent harness. | 09:31; 28:59 |
| q14 | single | ✓ | 2.36 | 3.78 | His original plan to port mruby to Prism was partially realized, as he rewrote MRBC to use Prism. However, the effort was undermined by the fact that someone else had already completed the port, and he was unable to get his version accepted into the documentation. Additionally, he noted that while he added mruby to the list of Prism VMs in the documentation, it was rejected as 'silly' by others. | 03:06; 32:18 |
| q15 | single | ✓ | 2.27 | 2.89 | His spreadsheet VM has five instructions per opcode compared to mruby's 119 opcodes. | 12:01; notes; notes; 08:38 |
| q16 | single | ✓ | 2.63 | 3.83 | Alex shared that the entire internal team related to the work at A sixteen Z was let go, though they are sticking around for a month. He noted that they were informed today and that the primary stakeholder is doing follow-up. He mentioned that this has been a tumultuous project and that he will be sending emails on the matter. | 12:32 |
| q17 | single | ✓ | 2.58 | 3.14 | Speaker 2 said that the engagement partner cluster is by far the largest single piece of the non-billable overhead. | 18:05 |
| q18 | single | ✓ | 2.31 | 2.87 | Speaker 6 suggested adding a hundred dollars per agent administrative fee to the invoice. | 43:22; 42:10; 28:47; notes |
| q19 | single | ✓ | 2.39 | 3.55 | Speaker 3 mentioned that Peter Drucker categorized people into three buckets: builders, sellers, or measurers. According to Speaker 3, Cloudflare's layoffs were primarily in the measurement category, as AI has made measurement activities easier. Speaker 3 noted that this was a theory and expressed uncertainty about whether they fully agree with it. | 53:28 |
| q20 | single | ✓ | 2.25 | 2.62 | Speaker 8 compared the overhead fee to restaurant health care fees. | 45:11 |
